import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runInNewContext } from 'node:vm';
import sharp from 'sharp';
import { createHttpServer } from '../src/http.mjs';
import { writePwaWorker } from '../../tool/pwa-assets.mjs';
import { versionWebAssetPaths } from '../../tool/web-asset-paths.mjs';

const source = name => new URL('../../web/' + name, import.meta.url);
async function temporary(t) {
  const directory = await mkdtemp(join(tmpdir(), 'theater-pwa-'));
  t.after(() => rm(directory, {recursive: true, force: true}));
  return directory;
}

test('install manifest and brand icons have a stable identity and valid platform sizes', async () => {
  const manifest = JSON.parse(await readFile(source('manifest.json'), 'utf8'));
  assert.equal(manifest.id, '/');
  assert.equal(manifest.start_url, '/');
  assert.equal(manifest.scope, '/');
  assert.equal(manifest.display, 'standalone');
  assert.equal(manifest.prefer_related_applications, false);
  for (const size of [192, 512]) for (const purpose of ['any', 'maskable']) {
    const icon = manifest.icons.find(icon => icon.sizes === `${size}x${size}` && (icon.purpose ?? 'any') === purpose);
    assert(icon, `Missing ${size}px ${purpose} icon`);
    const metadata = await sharp(await readFile(source(icon.src))).metadata();
    assert.equal(metadata.width, size); assert.equal(metadata.height, size);
    assert.equal(metadata.format, 'png');
  }
  const index = await readFile(source('index.html'), 'utf8');
  assert(index.includes('name="apple-mobile-web-app-capable" content="yes"'));
  assert(index.includes('name="theme-color"'));
});

test('public build cache changes with asset contents and remains stable when finalized twice', async t => {
  const directory = await temporary(t);
  for (const dir of ['assets', 'canvaskit']) await mkdir(join(directory, dir));
  const fixtures = {
    'index.html': '<meta name="theater-pwa-version" content="development">',
    'privacy.html': 'privacy', 'manifest.json': '{"icons":[]}',
    'main.1234.dart.js': 'main', 'pwa.1234.js': 'install',
    'assets/FontManifest.json': 'fonts', 'assets/font.ttf': 'font version one',
    'canvaskit/canvaskit.wasm': 'renderer', 'canvaskit/skwasm.wasm': 'unused renderer',
    'firebase-web-config.js': 'client config',
    'firebase-messaging-sw.js': "importScripts('https://www.gstatic.com/firebasejs/12.18.0/firebase-app-compat.js')",
  };
  for (const [path, bytes] of Object.entries(fixtures)) await writeFile(join(directory, path), bytes);
  const root = pathToFileURL(directory + '/');
  const entries = {main: 'main.1234.dart.js', pwa: 'pwa.1234.js'};
  const first = await writePwaWorker(root, entries);
  assert.deepEqual(await writePwaWorker(root, entries), first);
  const worker = await readFile(join(directory, first.worker), 'utf8');
  assert(worker.includes('/assets/font.ttf'));
  assert(worker.includes('/canvaskit/canvaskit.wasm'));
  assert(!worker.includes('/canvaskit/skwasm.wasm'));
  assert(!worker.includes('/firebase-web-config.js'));
  assert(worker.includes('https://www.gstatic.com/firebasejs/12.18.0/firebase-auth.js'));
  await writeFile(join(directory, 'assets/font.ttf'), 'font version two');
  assert.notEqual((await writePwaWorker(root, entries)).version, first.version);
  const paths = await versionWebAssetPaths(root);
  await writePwaWorker(root,entries,paths);
  const versionedWorker=await readFile(join(directory,first.worker),'utf8');
  assert(versionedWorker.includes('/'+paths.assetBase+'assets/font.ttf'));
  assert(versionedWorker.includes('/'+paths.canvasKitBaseUrl+'canvaskit.wasm'));
  assert(!versionedWorker.includes('"/assets/font.ttf"'));
});

test('asset URLs change with font contents while renderer URLs and prior files remain stable', async t => {
  const directory = await temporary(t);
  await mkdir(join(directory,'assets/fonts'),{recursive:true});
  await mkdir(join(directory,'canvaskit'));
  await writeFile(join(directory,'assets/fonts/icons.otf'),'old font');
  await writeFile(join(directory,'canvaskit/canvaskit.wasm'),'renderer');
  const root=pathToFileURL(directory+'/');
  const old=await versionWebAssetPaths(root);
  assert.deepEqual(await versionWebAssetPaths(root),old);
  await writeFile(join(directory,'assets/fonts/icons.otf'),'new font');
  const next=await versionWebAssetPaths(root);
  assert.notEqual(next.assetBase,old.assetBase);
  assert.equal(next.canvasKitBaseUrl,old.canvasKitBaseUrl);
  assert.equal(await readFile(join(directory,old.assetBase,'assets/fonts/icons.otf'),'utf8'),'old font');
  assert.equal(await readFile(join(directory,next.assetBase,'assets/fonts/icons.otf'),'utf8'),'new font');
});

function workerRuntime({networkFails = false, installFails = false} = {}) {
  const handlers = {}, stores = new Map([['unrelated-private-cache', new Map()], ['theater-app-shell-old', new Map()]]);
  const removed = [], additions = [];
  let skipped = false, claimed = false;
  const cache = async name => {
    if (!stores.has(name)) stores.set(name, new Map());
    return {
      addAll: async requests => { additions.push(...requests); if (installFails) throw new Error('Unavailable asset'); stores.get(name).set('/index.html', new Response('offline app')); },
      match: async key => stores.get(name).get(key) ?? (key.endsWith('/main.js') ? new Response('cached main') : undefined),
    };
  };
  const context = {
    URL, Request, Response,
    self: {location: {origin: 'https://theater.example'}, addEventListener: (name, handler) => { handlers[name] = handler; }, skipWaiting: async () => { skipped = true; }, clients: {claim: async () => { claimed = true; }}},
    caches: {open: cache, keys: async () => [...stores.keys()], delete: async key => { removed.push(key); return stores.delete(key); }},
    fetch: async () => { if (networkFails) throw new Error('Offline'); return new Response('current network app'); },
  };
  return {handlers, context, removed, additions, stores, skipped: () => skipped, claimed: () => claimed};
}
async function loadWorker(options) {
  const runtime = workerRuntime(options);
  let script = await readFile(source('theater-service-worker.js'), 'utf8');
  script = script.replace("{version: 'development', assets: []}", JSON.stringify({version: 'new', assets: ['/index.html', '/main.js']}));
  runInNewContext(script, runtime.context);
  return runtime;
}
async function lifecycle(runtime, type) {
  let operation;
  runtime.handlers[type]({waitUntil: promise => { operation = promise; }});
  return operation;
}
function request(runtime, path, extra = {}) {
  let response;
  runtime.handlers.fetch({request: {url: 'https://theater.example' + path, method: 'GET', mode: 'cors', headers: new Headers(), ...extra}, respondWith: promise => { response = promise; }});
  return response;
}

test('worker completes public precache and only removes its own old app caches', async () => {
  const runtime = await loadWorker();
  await lifecycle(runtime, 'install'); await lifecycle(runtime, 'activate');
  assert(runtime.skipped()); assert(runtime.claimed());
  assert.deepEqual(runtime.removed, ['theater-app-shell-old']);
  assert(runtime.stores.has('unrelated-private-cache'));
  assert(runtime.additions.every(request => request.credentials === 'omit'));
});
test('incomplete precache is rejected while the previous working version stays intact', async () => {
  const runtime = await loadWorker({installFails: true});
  await assert.rejects(lifecycle(runtime, 'install'), /Unavailable asset/);
  assert(!runtime.skipped());
  assert(runtime.stores.has('theater-app-shell-old'));
  assert(!runtime.stores.has('theater-app-shell-new'));
});
test('API, authorized media and mutations bypass the worker; online navigation uses the server', async () => {
  const runtime = await loadWorker();
  assert.equal(request(runtime, '/api/mobile/v1/snapshot'), undefined);
  assert.equal(request(runtime, '/main.js', {headers: new Headers({Authorization: 'Bearer synthetic-test'})}), undefined);
  assert.equal(request(runtime, '/main.js', {method: 'POST'}), undefined);
  assert.equal(request(runtime, '/missing.js'), undefined);
  assert.equal(await (await request(runtime, '/main.js')).text(), 'cached main');
  assert.equal(await (await request(runtime, '/', {mode: 'navigate'})).text(), 'current network app');
});
test('offline navigation restores the cached app shell including a deep link', async () => {
  const runtime = await loadWorker({networkFails: true});
  await lifecycle(runtime, 'install');
  assert.equal(await (await request(runtime, '/events/123', {mode: 'navigate'})).text(), 'offline app');
});

test('web server serves the manifest and worker correctly, and missing assets are real 404s', async t => {
  const directory = await temporary(t);
  for (const [name, value] of [['index.html', 'app'], ['manifest.json', '{"name":"Theater-App"}'], ['theater-service-worker.js', 'self.addEventListener("fetch",()=>{})']]) await writeFile(join(directory, name), value);
  const server = createHttpServer({theater: {}, verifyToken: async () => ({}), webDir: directory});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const manifest = await fetch(base + '/manifest.json');
  assert.match(manifest.headers.get('content-type'), /^application\/manifest\+json/);
  assert.match(manifest.headers.get('cache-control'), /no-store/);
  const worker = await fetch(base + '/theater-service-worker.js', {method: 'HEAD'});
  assert.equal(worker.status, 200);
  assert.equal(worker.headers.get('service-worker-allowed'), '/');
  assert.match(worker.headers.get('content-type'), /javascript/);
  assert.equal(await worker.text(), '');
  for (const path of ['/missing.js', '/icons/missing.png', '/canvaskit/missing.wasm', '/assets/missing', '/web-assets/old/assets/missing', '/web-renderer/old/missing', '/api/unknown']) assert.equal((await fetch(base + path)).status, 404);
  assert.equal(await (await fetch(base + '/events/123')).text(), 'app');
});

test('installation prompt is consumed once and installed windows do not offer it again', async () => {
  const events = {}, listeners = {}, display = {matches: false, addEventListener: (name, handler) => { listeners[name] = handler; }};
  const window = {isSecureContext: false, matchMedia: () => display, addEventListener: (name, handler) => { events[name] = handler; }};
  runInNewContext(await readFile(source('pwa.js'), 'utf8'), {window, navigator: {userAgent: 'Chrome', platform: 'Linux', maxTouchPoints: 0}});
  let prompted = 0, prevented = false;
  events.beforeinstallprompt({preventDefault: () => { prevented = true; }, prompt: async () => { prompted++; }, userChoice: Promise.resolve({outcome: 'accepted'})});
  assert(prevented); assert(window.theaterPwa.canPrompt);
  assert.equal(await window.theaterPwa.install(), true);
  assert.equal(await window.theaterPwa.install(), false);
  assert.equal(prompted, 1); assert(window.theaterPwa.installed);
  events.appinstalled(); assert(!window.theaterPwa.canPrompt);
});
