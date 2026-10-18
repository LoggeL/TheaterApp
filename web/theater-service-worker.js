// tool/version-web.mjs replaces this config with the exact public build assets.
const BUILD = {version: 'development', assets: []};
const PREFIX = 'theater-app-shell-';
const CACHE = PREFIX + BUILD.version;
// Each renderer list holds the Dart entrypoint and engine files of one way the Flutter loader can start.
const renderers = BUILD.renderers || {};
const href = path => new URL(path, self.location.origin).href;
const assets = new Set([...BUILD.assets, ...Object.values(renderers).flat()].map(href));

// The renderer flutter.js will choose here: Wasm with skwasm in Chromium with WasmGC, else CanvasKit.
function startupRenderer() {
  const nav = self.navigator || {};
  const chromium = 'userAgentData' in nav || /(?:Chrome|Chromium|Edg)\//.test(nav.userAgent || '');
  let wasmGC = false;
  try { wasmGC = WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 95, 1, 120, 0])); } catch {}
  return (chromium && wasmGC && renderers.skwasm) || (chromium && renderers.chromium) || renderers.canvaskit || [];
}

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    if (!BUILD.assets.length) throw new Error('The PWA build has not been finalized.');
    const cache = await caches.open(CACHE);
    try {
      // Only the renderer this browser starts with; another one is kept once it is loaded.
      await cache.addAll([...BUILD.assets, ...startupRenderer()].map(path => new Request(href(path), {cache: 'reload', credentials: 'omit'})));
    } catch (error) {
      await caches.delete(CACHE);
      throw error;
    }
    await self.skipWaiting();
  })());
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(key => key.startsWith(PREFIX) && key !== CACHE).map(key => caches.delete(key)));
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  // Authentication, API responses and private media always use the network.
  if (request.method !== 'GET' || request.headers.has('Authorization') ||
      (url.origin === self.location.origin && url.pathname.startsWith('/api/'))) return;
  if (request.mode === 'navigate' && url.origin === self.location.origin) {
    event.respondWith((async () => {
      try { return await fetch(request); }
      catch {
        const cache = await caches.open(CACHE);
        return await cache.match(url.pathname) || await cache.match('/index.html');
      }
    })());
  } else {
    url.search = '';
    url.hash = '';
    if (!assets.has(url.href)) return;
    event.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const cached = await cache.match(url.href);
      if (cached) return cached;
      const response = await fetch(request);
      // Build files are content-addressed, so a late copy is still the right one.
      if (response.ok && response.type === 'basic') event.waitUntil(cache.put(url.href, response.clone()).catch(() => {}));
      return response;
    })());
  }
});
