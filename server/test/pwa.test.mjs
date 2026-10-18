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
  for (const dir of ['assets/assets/auth', 'assets/assets/games/stage_runner', 'canvaskit']) await mkdir(join(directory, dir), {recursive: true});
  const fixtures = {
    'index.html': '<meta name="theater-pwa-version" content="development">',
    'privacy.html': 'privacy', 'manifest.json': '{"icons":[]}',
    'main.1234.dart.js': 'main', 'pwa.1234.js': 'install',
    'assets/FontManifest.json': 'fonts', 'assets/font.ttf': 'font version one',
    'assets/assets/auth/no_bots.webp': 'picture',
    'assets/assets/games/stage_runner/music.mp3': 'tune',
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
  // The first screen's picture is small and works offline.
  assert(worker.includes('/assets/assets/auth/no_bots.webp'));
  assert(worker.includes('/canvaskit/canvaskit.wasm'));
  assert(!worker.includes('/canvaskit/skwasm.wasm'));
  assert(!worker.includes('/firebase-web-config.js'));
  // The game's pictures and sounds load on demand only.
  assert(!worker.includes('games/stage_runner'));
  assert(worker.includes('https://www.gstatic.com/firebasejs/12.18.0/firebase-auth.js'));
  await writeFile(join(directory, 'assets/font.ttf'), 'font version two');
  assert.notEqual((await writePwaWorker(root, entries)).version, first.version);
  const paths = await versionWebAssetPaths(root);
  await writePwaWorker(root,entries,paths);
  const versionedWorker=await readFile(join(directory,first.worker),'utf8');
  assert(versionedWorker.includes('/'+paths.assetBase+'assets/font.ttf'));
  assert(versionedWorker.includes('/'+paths.canvasKitBaseUrl+'canvaskit.wasm'));
  assert(!versionedWorker.includes('"/assets/font.ttf"'));
  assert(!versionedWorker.includes('games/stage_runner'));
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

function workerRuntime({networkFails = false, installFails = false, userAgent = ''} = {}) {
  const handlers = {}, stores = new Map([['unrelated-private-cache', new Map()], ['theater-app-shell-old', new Map()]]);
  const removed = [], additions = [];
  let skipped = false, claimed = false;
  const cache = async name => {
    if (!stores.has(name)) stores.set(name, new Map());
    return {
      addAll: async requests => { additions.push(...requests); if (installFails) throw new Error('Unavailable asset'); stores.get(name).set('/index.html', new Response('offline app')); },
      match: async key => stores.get(name).get(key) ?? (key.endsWith('/main.js') ? new Response('cached main') : undefined),
      put: async (key, response) => { stores.get(name).set(key, response); },
    };
  };
  const context = {
    URL, Request, Response, WebAssembly,
    self: {location: {origin: 'https://theater.example'}, navigator: {userAgent}, addEventListener: (name, handler) => { handlers[name] = handler; }, skipWaiting: async () => { skipped = true; }, clients: {claim: async () => { claimed = true; }}},
    caches: {open: cache, keys: async () => [...stores.keys()], delete: async key => { removed.push(key); return stores.delete(key); }},
    fetch: async () => { if (networkFails) throw new Error('Offline'); return Object.defineProperty(new Response('current network app'), 'type', {value: 'basic'}); },
  };
  return {handlers, context, removed, additions, stores, skipped: () => skipped, claimed: () => claimed};
}
async function loadWorker(options = {}) {
  const runtime = workerRuntime(options);
  let script = await readFile(source('theater-service-worker.js'), 'utf8');
  script = script.replace("{version: 'development', assets: []}", JSON.stringify(options.build ?? {version: 'new', assets: ['/index.html', '/main.js']}));
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
  runtime.handlers.fetch({request: {url: 'https://theater.example' + path, method: 'GET', mode: 'cors', headers: new Headers(), ...extra}, respondWith: promise => { response = promise; }, waitUntil: () => {}});
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
test('worker precaches the renderer the Flutter loader starts with and keeps another one once loaded', async () => {
  const build = {version: 'new', assets: ['/index.html'], renderers: {
    canvaskit: ['/main.1.dart.js', '/r/canvaskit.js', '/r/canvaskit.wasm'],
    chromium: ['/main.1.dart.js', '/r/chromium/canvaskit.js', '/r/chromium/canvaskit.wasm'],
    skwasm: ['/main.1.dart.mjs', '/main.1.dart.wasm', '/r/skwasm.js', '/r/skwasm.wasm'],
  }};
  const precached = async userAgent => {
    const runtime = await loadWorker({build, userAgent});
    await lifecycle(runtime, 'install');
    return runtime.additions.map(request => new URL(request.url).pathname);
  };
  const chrome = await precached('Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36');
  assert.deepEqual(chrome, ['/index.html', ...build.renderers.skwasm]);
  const safari = await precached('Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1');
  assert.deepEqual(safari, ['/index.html', ...build.renderers.canvaskit]);
  // Chrome on iOS is WebKit as well.
  assert.deepEqual(await precached('Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0 Mobile/15E148 Safari/604.1'), safari);
  const runtime = await loadWorker({build, userAgent: 'Safari'});
  await lifecycle(runtime, 'install');
  assert.equal(await (await request(runtime, '/main.1.dart.wasm')).text(), 'current network app');
  await new Promise(resolve => setTimeout(resolve));
  assert(runtime.stores.get('theater-app-shell-new').has('https://theater.example/main.1.dart.wasm'));
  assert.equal(request(runtime, '/r/skwasm_heavy.wasm'), undefined);
});
test('offline navigation restores the cached app shell including a deep link', async () => {
  const runtime = await loadWorker({networkFails: true});
  await lifecycle(runtime, 'install');
  assert.equal(await (await request(runtime, '/events/123', {mode: 'navigate'})).text(), 'offline app');
});

test('web server serves the manifest and worker correctly, and missing assets are real 404s', async t => {
  const directory = await temporary(t);
  for (const [name, value] of [['index.html', 'app'], ['manifest.json', '{"name":"Theater-App"}'], ['theater-service-worker.js', 'self.addEventListener("fetch",()=>{})']]) await writeFile(join(directory, name), value);
  await mkdir(join(directory, 'assets/games'), {recursive: true});
  for (const name of ['atlas.webp', 'music.mp3']) await writeFile(join(directory, 'assets/games', name), 'bytes');
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
  // The game's pictures and sounds come with their media types.
  assert.equal((await fetch(base + '/assets/games/atlas.webp')).headers.get('content-type'), 'image/webp');
  assert.equal((await fetch(base + '/assets/games/music.mp3')).headers.get('content-type'), 'audio/mpeg');
  for (const path of ['/missing.js', '/icons/missing.png', '/canvaskit/missing.wasm', '/assets/missing', '/web-assets/old/assets/missing', '/web-renderer/old/missing', '/api/unknown']) assert.equal((await fetch(base + path)).status, 404);
  assert.equal(await (await fetch(base + '/events/123')).text(), 'app');
});

test('content-addressed web files are cached for a year; entry points and unhashed files are not cached', async t => {
  const directory = await temporary(t);
  const h = '0123456789abcdef';
  const files = {
    immutable: [`main.${h}.dart.js`, `main.${h}.dart.mjs`, `main.${h}.dart.wasm`, `web-renderer/${h}/skwasm.wasm`, `flutter_bootstrap.${h}.js`, `pwa.${h}.js`, `favicon.${h}.png`, `icons/Icon-maskable-192.${h}.png`, `web-renderer/${h}/canvaskit.wasm`, `web-renderer/${h}/canvaskit.js`, `web-assets/${h}/assets/FontManifest.json`, `web-assets/${h}/assets/fonts/Roboto.ttf`],
    noStore: ['index.html', 'main.dart.js', 'main.dart.mjs', 'flutter_bootstrap.js', 'flutter.js', 'pwa.js', 'manifest.json', `manifest.${h}.json`, 'theater-service-worker.js', 'firebase-messaging-sw.js', 'firebase-web-config.js', 'release-assets.json', 'version.json', 'assets/FontManifest.json', 'canvaskit/canvaskit.js', `main.${h.slice(0, 8)}.dart.js`, `other.${h}.js`],
    hour: ['favicon.png', 'icons/Icon-192.png', 'assets/fonts/Roboto.ttf', 'canvaskit/canvaskit.wasm'],
  };
  for (const name of Object.values(files).flat()) {
    await mkdir(join(directory, name, '..'), {recursive: true});
    await writeFile(join(directory, name), name);
  }
  const server = createHttpServer({theater: {}, verifyToken: async () => ({}), webDir: directory});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/`;
  const cacheControl = async name => { const response = await fetch(base + name); assert.equal(response.status, 200, name); await response.arrayBuffer(); return response.headers.get('cache-control'); };
  for (const name of files.immutable) assert.equal(await cacheControl(name), 'public, max-age=31536000, immutable', name);
  for (const name of files.noStore) assert.match(await cacheControl(name), /no-store/, name);
  for (const name of files.hour) assert.equal(await cacheControl(name), 'public, max-age=3600', name);
  // Module imports and streaming Wasm compilation need their exact types.
  assert.equal((await fetch(base + `main.${h}.dart.mjs`)).headers.get('content-type'), 'text/javascript');
  assert.equal((await fetch(base + `main.${h}.dart.wasm`)).headers.get('content-type'), 'application/wasm');
  // A missing hashed file is a 404, and the app fallback for deep links is never cached.
  assert.equal((await fetch(base + `main.${'f'.repeat(16)}.dart.js`)).status, 404);
  assert.equal((await fetch(base + `web-assets/${'f'.repeat(16)}/assets/missing.ttf`)).status, 404);
  assert.match((await fetch(base + 'events/123')).headers.get('cache-control'), /no-store/);
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
