import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
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

const ORIGIN = 'https://theater.example';
const cacheKey = key => typeof key === 'string' ? new URL(key, ORIGIN).href : key.url;
const basic = (body, init) => Object.defineProperty(new Response(body, init), 'type', {value: 'basic'});
function workerRuntime({networkFails = false, installFails = false, userAgent = '', network = null, seed = {}, timeoutMs = null} = {}) {
  const handlers = {}, stores = new Map([['unrelated-private-cache', new Map()], ['theater-app-shell-old', new Map()]]);
  for (const [name, entries] of Object.entries(seed)) {
    stores.set(name, new Map(Object.entries(entries).map(([key, body]) => [cacheKey(key), new Response(body)])));
  }
  const removed = [], additions = [], fetched = [];
  let skipped = false, claimed = false, preload = false;
  const cache = async name => {
    if (!stores.has(name)) stores.set(name, new Map());
    const store = () => stores.get(name);
    return {
      addAll: async requests => { additions.push(...requests); if (installFails) throw new Error('Unavailable asset'); store().set(cacheKey('/index.html'), new Response('offline app')); },
      match: async key => store()?.get(cacheKey(key))?.clone(),
      // Like the Cache API, a new entry for an existing key moves to the end of keys().
      put: async (key, response) => { store().delete(cacheKey(key)); store().set(cacheKey(key), response.clone()); },
      keys: async () => [...store().keys()].map(url => new Request(url)),
      delete: async key => store().delete(cacheKey(key)),
    };
  };
  const context = {
    URL, Request, Response, Headers, WebAssembly, TextEncoder, TextDecoder, atob, crypto,
    setTimeout: (callback, ms, ...args) => setTimeout(callback, timeoutMs ?? ms, ...args), clearTimeout,
    self: {location: {origin: ORIGIN}, navigator: {userAgent}, addEventListener: (name, handler) => { handlers[name] = handler; }, skipWaiting: async () => { skipped = true; }, clients: {claim: async () => { claimed = true; }},
      registration: {navigationPreload: {enable: async () => { preload = true; }}}},
    caches: {open: cache, keys: async () => [...stores.keys()], delete: async key => { removed.push(key); return stores.delete(key); }},
    fetch: async request => {
      fetched.push(request);
      if (network) return network(request);
      if (networkFails) throw new Error('Offline');
      return basic('current network app');
    },
  };
  return {handlers, context, removed, additions, fetched, stores, skipped: () => skipped, claimed: () => claimed, preload: () => preload};
}
async function loadWorker(options = {}) {
  const runtime = workerRuntime(options);
  let script = await readFile(source('theater-service-worker.js'), 'utf8');
  script = script.replace("{version: 'development', assets: []}", JSON.stringify(options.build ?? {version: 'new', assets: ['/index.html', '/main.js'], fresh: ['/index.html']}));
  runInNewContext(script, runtime.context);
  return runtime;
}
async function lifecycle(runtime, type) {
  let operation;
  runtime.handlers[type]({waitUntil: promise => { operation = promise; }});
  return operation;
}
// Returns the response promise (undefined when the worker leaves the request to the browser);
// `waits` collects what the worker keeps running in the background.
function request(runtime, path, extra = {}, waits = []) {
  let response;
  const {preloadResponse, ...fields} = extra;
  runtime.handlers.fetch({request: {url: ORIGIN + path, method: 'GET', mode: 'cors', headers: new Headers(), ...fields}, preloadResponse, respondWith: promise => { response = promise; }, waitUntil: promise => { waits.push(promise); }});
  return response;
}

test('worker completes public precache and only removes its own old app caches', async () => {
  const runtime = await loadWorker();
  await lifecycle(runtime, 'install'); await lifecycle(runtime, 'activate');
  assert(runtime.skipped()); assert(runtime.claimed()); assert(runtime.preload());
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
test('install copies unchanged hashed files from the previous version and reloads only unhashed ones', async () => {
  const h = '0123456789abcdef';
  const build = {version: 'new', assets: ['/index.html', '/manifest.json', `/web-assets/${h}/assets/font.ttf`, `/web-assets/${'f'.repeat(16)}/assets/logo.png`], fresh: ['/index.html', '/manifest.json'],
    renderers: {canvaskit: [`/main.${h}.dart.js`, `/web-renderer/${h}/canvaskit.js`, `/web-renderer/${h}/canvaskit.wasm`]}};
  const runtime = await loadWorker({build, userAgent: 'Safari', seed: {'theater-app-shell-old': {
    '/index.html': 'old app', '/manifest.json': 'old manifest', [`/web-assets/${h}/assets/font.ttf`]: 'font',
    [`/main.${h}.dart.js`]: 'main', [`/web-renderer/${h}/canvaskit.js`]: 'engine', [`/web-renderer/${h}/canvaskit.wasm`]: 'wasm',
  }}});
  await lifecycle(runtime, 'install');
  // Only the unhashed entry points and the one new file are downloaded.
  assert.deepEqual(runtime.additions.map(request => [new URL(request.url).pathname, request.cache]),
    [['/index.html', 'reload'], ['/manifest.json', 'reload'], [`/web-assets/${'f'.repeat(16)}/assets/logo.png`, 'default']]);
  assert.equal(runtime.fetched.length, 0);
  const current = runtime.stores.get('theater-app-shell-new');
  for (const path of [`/main.${h}.dart.js`, `/web-renderer/${h}/canvaskit.wasm`, `/web-assets/${h}/assets/font.ttf`]) assert(current.has(ORIGIN + path), path);
  assert.equal(await current.get(ORIGIN + `/web-renderer/${h}/canvaskit.wasm`).clone().text(), 'wasm');
  assert.equal(await current.get(ORIGIN + '/index.html').clone().text(), 'offline app');
});
test('API, authorized media and mutations bypass the worker; online navigation uses the server', async () => {
  const runtime = await loadWorker({seed: {'theater-app-shell-new': {'/main.js': 'cached main'}}});
  assert.equal(request(runtime, '/api/mobile/v1/snapshot'), undefined);
  assert.equal(request(runtime, '/main.js', {headers: new Headers({Authorization: 'Bearer synthetic-test'})}), undefined);
  assert.equal(request(runtime, '/main.js', {method: 'POST'}), undefined);
  assert.equal(request(runtime, '/missing.js'), undefined);
  assert.equal(await (await request(runtime, '/main.js')).text(), 'cached main');
  assert.equal(await (await request(runtime, '/', {mode: 'navigate'})).text(), 'current network app');
  // Other private API files, even with a version, stay with the network.
  assert.equal(request(runtime, '/api/mobile/v1/media/abc/?v=1', {headers: new Headers({Authorization: `Bearer ${jwt('member')}`})}), undefined);
});
test('worker precaches the renderer the Flutter loader starts with and keeps another one once loaded', async () => {
  const build = {version: 'new', assets: ['/index.html'], fresh: ['/index.html'], renderers: {
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
test('a slow navigation falls back to this version\'s cached app shell and the preload answer is used', async () => {
  let answer;
  const pending = new Promise(resolve => { answer = resolve; });
  const runtime = await loadWorker({network: () => pending, timeoutMs: 0});
  await lifecycle(runtime, 'install');
  const waits = [];
  assert.equal(await (await request(runtime, '/events/123', {mode: 'navigate'}, waits)).text(), 'offline app');
  // The server answer still completes in the background.
  assert.equal(waits.length, 1);
  answer(basic('late app'));
  await Promise.all(waits);
  const preloaded = await loadWorker({network: () => { throw new Error('No second request'); }});
  await lifecycle(preloaded, 'install');
  assert.equal(await (await request(preloaded, '/', {mode: 'navigate', preloadResponse: Promise.resolve(basic('preloaded app'))})).text(), 'preloaded app');
  assert.equal(preloaded.fetched.length, 0);
});

test('a server error on navigation gives way to the cached app shell, the error page stays the last resort', async () => {
  const status = code => () => basic('server says ' + code, {status: code});
  const runtime = await loadWorker({network: status(502)});
  await lifecycle(runtime, 'install');
  assert.equal(await (await request(runtime, '/events/123', {mode: 'navigate'})).text(), 'offline app');
  // Without a cached shell the answer itself is all there is, also from the preload.
  const uncached = await loadWorker({network: status(503)});
  const error = await request(uncached, '/', {mode: 'navigate'});
  assert.equal(error.status, 503);
  assert.equal(await error.text(), 'server says 503');
  const preloaded = await loadWorker({network: () => { throw new Error('No second request'); }});
  await lifecycle(preloaded, 'install');
  assert.equal(await (await request(preloaded, '/', {mode: 'navigate', preloadResponse: Promise.resolve(basic('bad gateway', {status: 502}))})).text(), 'offline app');
  // Only 5xx: the server's other answers still count.
  const missing = await loadWorker({network: status(404)});
  await lifecycle(missing, 'install');
  assert.equal((await request(missing, '/privacy', {mode: 'navigate'})).status, 404);
});

const jwt = (sub, extra = {}) => ['eyJhbGciOiJSUzI1NiJ9', Buffer.from(JSON.stringify({sub, ...extra})).toString('base64url'), 'c2lnbmF0dXJl'].join('.');
const skinName = sub => 'theater-skins-v1-' + createHash('sha256').update(sub).digest('hex');
function skinNetwork(cacheControl = 'private, max-age=31536000, immutable') {
  let served = 0;
  const network = request => {
    served++;
    return basic(`picture ${served} for ${new URL(request.url).pathname}`, {headers: {'Content-Type': 'image/webp', 'Cache-Control': cacheControl, Vary: 'Authorization, Origin', 'Server-Timing': 'auth;dur=2, app;dur=3'}});
  };
  return {network, served: () => served};
}
const skin = (runtime, file, token, extra = {}) => {
  const waits = [];
  const response = request(runtime, `/api/mobile/v1/games/runner/skins/${file}/?v=abc123`, {headers: new Headers({Authorization: `Bearer ${token}`, ...extra}), mode: 'cors'}, waits);
  return {response, settled: async () => { await response; await Promise.all(waits); }};
};

test('wardrobe pictures come from a per-account cache, also with a renewed token', async () => {
  const net = skinNetwork();
  const runtime = await loadWorker({network: net.network});
  const first = skin(runtime, 'character-anna.webp', jwt('member-a', {iat: 1}));
  const fromServer = await first.response;
  assert.equal(await fromServer.text(), 'picture 1 for /api/mobile/v1/games/runner/skins/character-anna.webp/');
  assert.equal(fromServer.headers.get('Server-Timing'), 'auth;dur=2, app;dur=3');
  await first.settled();
  const renewed = skin(runtime, 'character-anna.webp', jwt('member-a', {iat: 2}));
  const cached = await renewed.response;
  assert.equal(await cached.text(), 'picture 1 for /api/mobile/v1/games/runner/skins/character-anna.webp/');
  assert.equal(cached.headers.get('Content-Type'), 'image/webp');
  assert.equal(cached.headers.get('Cache-Control'), 'private, max-age=31536000, immutable');
  // A hit did not reach the server, so it carries no server timing.
  assert.equal(cached.headers.get('Server-Timing'), null);
  assert.equal(net.served(), 1);
  // The cache is separated per account and outlives a new app version.
  assert.deepEqual([...runtime.stores.get(skinName('member-a')).keys()], [ORIGIN + '/api/mobile/v1/games/runner/skins/character-anna.webp/?v=abc123']);
  const other = skin(runtime, 'character-anna.webp', jwt('member-b'));
  assert.equal(await (await other.response).text(), 'picture 2 for /api/mobile/v1/games/runner/skins/character-anna.webp/');
  await other.settled();
  assert.equal(net.served(), 2);
  await lifecycle(runtime, 'install'); await lifecycle(runtime, 'activate');
  assert(runtime.stores.has(skinName('member-a')) && runtime.stores.has(skinName('member-b')));
});
test('wardrobe pictures without a stable version, ranges and unreadable tokens are not cached', async () => {
  const net = skinNetwork('private, no-cache');
  const runtime = await loadWorker({network: net.network});
  for (let i = 0; i < 2; i++) await skin(runtime, 'character-anna.webp', jwt('member-a')).settled();
  assert.equal(net.served(), 2);
  assert.equal(runtime.stores.get(skinName('member-a')).size, 0);
  // Partial requests and requests without a version or a readable account go straight to the browser.
  assert.equal(skin(runtime, 'music.m4a', jwt('member-a'), {Range: 'bytes=0-'}).response, undefined);
  assert.equal(request(runtime, '/api/mobile/v1/games/runner/skins/character-anna.webp/', {headers: new Headers({Authorization: `Bearer ${jwt('member-a')}`})}), undefined);
  assert.equal(skin(runtime, 'character-anna.webp', 'not-a-jwt').response, undefined);
  assert.equal(skin(runtime, 'character-anna.webp', jwt('')).response, undefined);
  assert.equal(request(runtime, '/api/mobile/v1/games/runner/skins/character-anna.webp/?v=abc123'), undefined);
  assert.equal(request(runtime, '/api/mobile/v1/games/runner/skins/character-anna.webp/?v=abc123', {method: 'POST', headers: new Headers({Authorization: `Bearer ${jwt('member-a')}`})}), undefined);
});
test('wardrobe pictures still come from the server when the browser storage fails', async () => {
  for (const broken of ['open', 'match']) {
    const net = skinNetwork();
    const runtime = await loadWorker({network: net.network});
    const open = runtime.context.caches.open;
    runtime.context.caches.open = broken === 'open' ? async () => { throw new Error('UnknownError'); }
      : async name => ({...await open(name), match: async () => { throw new Error('UnknownError'); }});
    const attempt = skin(runtime, 'character-anna.webp', jwt('member-a'));
    assert.equal(await (await attempt.response).text(), 'picture 1 for /api/mobile/v1/games/runner/skins/character-anna.webp/', broken);
    await attempt.settled();
    assert.equal(net.served(), 1);
  }
});
test('the per-account picture cache keeps only the newest 600 entries', async () => {
  const net = skinNetwork();
  const runtime = await loadWorker({network: net.network});
  for (let i = 0; i < 602; i++) await skin(runtime, `item-${i}.webp`, jwt('member-a')).settled();
  const keys = [...runtime.stores.get(skinName('member-a')).keys()];
  assert.equal(keys.length, 600);
  assert(keys[0].includes('/item-2.webp/'));
  assert(keys.at(-1).includes('/item-601.webp/'));
});
test('logging out removes every account\'s picture cache while the request still reaches the server', async () => {
  const net = skinNetwork();
  const runtime = await loadWorker({network: net.network});
  await skin(runtime, 'character-anna.webp', jwt('member-a')).settled();
  await skin(runtime, 'character-anna.webp', jwt('member-b')).settled();
  const waits = [];
  assert.equal(request(runtime, '/api/mobile/v1/auth/logout/', {method: 'POST', headers: new Headers({Authorization: `Bearer ${jwt('member-a')}`})}, waits), undefined);
  await Promise.all(waits);
  assert(![...runtime.stores.keys()].some(name => name.startsWith('theater-skins-v1-')));
  assert(runtime.stores.has('unrelated-private-cache') && runtime.stores.has('theater-app-shell-old'));
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

function pageRuntime({secure = true, readyState = 'loading', idle = true} = {}) {
  const listeners = {}, timers = [], registrations = [];
  let splash = true;
  const window = {
    isSecureContext: secure,
    matchMedia: () => ({matches: false, addEventListener: () => {}}),
    addEventListener: (name, handler) => { (listeners[name] ??= []).push(handler); },
    setTimeout: (callback, ms) => { timers.push({callback, ms}); },
    ...(idle ? {requestIdleCallback: callback => callback()} : {}),
    document: {readyState, querySelector: () => ({content: 'abc123'}), getElementById: id => id === 'theater-splash' && splash ? {remove: () => { splash = false; }} : null},
  };
  const navigator = {userAgent: 'Chrome', platform: 'Linux', maxTouchPoints: 0, serviceWorker: {register: async (url, options) => { registrations.push({url, options}); return {update: async () => {}}; }}};
  const fire = name => { for (const handler of listeners[name] ?? []) handler(); };
  return {window, navigator, timers, registrations, fire, splash: () => splash};
}

test('the service worker registers after the first frame, or 10 s after load without one', async () => {
  const script = await readFile(source('pwa.js'), 'utf8');
  const page = pageRuntime();
  runInNewContext(script, {window: page.window, navigator: page.navigator});
  // Nothing competes with the app's own start.
  assert.equal(page.registrations.length, 0);
  page.fire('load');
  assert.deepEqual(page.timers.map(timer => timer.ms), [10000]);
  assert.equal(page.registrations.length, 0);
  assert(page.splash());
  page.fire('flutter-first-frame');
  assert.equal(page.registrations.length, 1);
  assert(!page.splash());
  assert.equal(page.registrations[0].url, 'theater-service-worker.js?v=abc123');
  assert.equal(JSON.stringify(page.registrations[0].options), '{"scope":"./","updateViaCache":"none"}');
  page.timers[0].callback();
  assert.equal(page.registrations.length, 1);

  const stuck = pageRuntime({readyState: 'complete', idle: false});
  runInNewContext(script, {window: stuck.window, navigator: stuck.navigator});
  assert.deepEqual(stuck.timers.map(timer => timer.ms), [10000]);
  stuck.timers[0].callback();
  assert.equal(stuck.registrations.length, 1);

  // Without a secure context there is no worker, but the start screen still goes away.
  const insecure = pageRuntime({secure: false});
  runInNewContext(script, {window: insecure.window, navigator: insecure.navigator});
  insecure.fire('load'); insecure.fire('flutter-first-frame');
  assert.equal(insecure.timers.length + insecure.registrations.length, 0);
  assert(!insecure.splash());
});

test('the page removes the per-account picture caches itself on logout', async () => {
  const script = await readFile(source('pwa.js'), 'utf8');
  const page = pageRuntime();
  const names = new Set(['theater-skins-v1-aaa', 'theater-skins-v1-bbb', 'theater-app-shell-new', 'unrelated-private-cache']);
  page.window.caches = {keys: async () => [...names], delete: async name => names.delete(name)};
  runInNewContext(script, {window: page.window, navigator: page.navigator});
  await page.window.theaterPwa.clearPrivateCaches();
  assert.deepEqual([...names], ['theater-app-shell-new', 'unrelated-private-cache']);
  // Without the Cache API (old browsers, insecure origins) there is nothing to do.
  delete page.window.caches;
  await page.window.theaterPwa.clearPrivateCaches();
});

const run = promisify(execFile);
async function webBuild(t, index) {
  const directory = await temporary(t);
  for (const dir of ['icons', 'assets/fonts', 'assets/assets/games/stage_runner', 'canvaskit']) await mkdir(join(directory, dir), {recursive: true});
  const fixtures = {
    'index.html': index ?? await readFile(source('index.html'), 'utf8'),
    'pwa.js': await readFile(source('pwa.js'), 'utf8'),
    'main.dart.js': 'main __image_picker_web-file-input',
    'flutter_bootstrap.js': "_flutter.loader.load({config: {assetBase: './', canvasKitBaseUrl: 'canvaskit/'}, mainJsPath: 'main.dart.js'});",
    'privacy.html': 'privacy', 'favicon.png': 'favicon', 'icons/apple-touch-icon.png': 'touch', 'icons/Icon-192.png': 'icon',
    'manifest.json': JSON.stringify({icons: [{src: 'icons/Icon-192.png', sizes: '192x192'}]}),
    'assets/FontManifest.json': '[]', 'assets/fonts/Roboto-Regular.ttf': 'font',
    'assets/assets/games/stage_runner/atlas.webp': 'game',
    'canvaskit/canvaskit.js': 'engine', 'canvaskit/canvaskit.wasm': 'renderer',
    'firebase-messaging-sw.js': "importScripts('https://www.gstatic.com/firebasejs/12.18.0/firebase-app-compat.js')",
  };
  for (const [path, bytes] of Object.entries(fixtures)) await writeFile(join(directory, path), bytes);
  await run(process.execPath, [new URL('../../tool/version-web.mjs', import.meta.url).pathname, directory]);
  return directory;
}

test('the built page keeps its scripts away from Rocket Loader and shows a start screen without external files', async t => {
  const directory = await webBuild(t);
  const index = await readFile(join(directory, 'index.html'), 'utf8');
  const scripts = [...index.matchAll(/<script\b[^>]*>/g)].map(([tag]) => tag);
  assert.equal(scripts.length, 2);
  assert(scripts.every(tag => tag.includes('data-cfasync="false"')), scripts.join('\n'));
  assert.match(scripts[0], /src="pwa\.[a-f0-9]{16}\.js"/);
  assert.match(scripts[1], /src="flutter_bootstrap\.[a-f0-9]{16}\.js" async/);
  const splash = index.slice(index.indexOf('<div id="theater-splash"'), index.indexOf('</div>\n  </div>'));
  assert(splash.includes('<svg'));
  assert(!/\b(?:src|href)=/.test(splash));
  assert.match(index, /prefers-color-scheme: dark/);
  // A forgotten attribute fails the build instead of slowing every start.
  await assert.rejects(webBuild(t, '<meta name="theater-pwa-version" content="development"><script src="pwa.js"></script><script data-cfasync="false" src="flutter_bootstrap.js" async></script>'), /data-cfasync/);
});

test('the worker reloads exactly the files the server does not serve as immutable', async t => {
  const directory = await webBuild(t);
  const worker = await readFile(join(directory, 'theater-service-worker.js'), 'utf8');
  const build = JSON.parse(worker.match(/^const BUILD = (\{.*\});$/m)[1]);
  assert.deepEqual(build.fresh.map(path => path.replace(/[a-f0-9]{16}/, '<hash>')).sort(), ['/index.html', '/manifest.<hash>.json', '/manifest.json', '/privacy.html']);
  const server = createHttpServer({theater: {}, verifyToken: async () => ({}), webDir: directory});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const local = [...build.assets, ...Object.values(build.renderers).flat()].filter(path => path.startsWith('/'));
  assert(local.length >= 10);
  for (const path of local) {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`);
    assert.equal(response.status, 200, path);
    await response.arrayBuffer();
    assert.equal(/immutable/.test(response.headers.get('cache-control')), !build.fresh.includes(path), path);
  }
});

test('the app bundles every listed font face and no unused ones', async () => {
  const pubspec = await readFile(new URL('../../pubspec.yaml', import.meta.url), 'utf8');
  const listed = [...pubspec.matchAll(/- asset: (assets\/fonts\/roboto\/[\w-]+\.ttf)/g)].map(match => match[1].split('/').pop()).sort();
  const files = (await readdir(new URL('../../assets/fonts/roboto/', import.meta.url))).filter(name => name.endsWith('.ttf')).sort();
  assert.deepEqual(files, listed);
  // Light (w300) is used once; Medium-, Bold- and Black-Italic and Thin are not.
  assert.deepEqual(listed, ['Roboto-Black.ttf', 'Roboto-Bold.ttf', 'Roboto-Italic.ttf', 'Roboto-Light.ttf', 'Roboto-Medium.ttf', 'Roboto-Regular.ttf']);
});
