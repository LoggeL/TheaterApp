// tool/version-web.mjs replaces this config with the exact public build assets.
const BUILD = {version: 'development', assets: []};
const PREFIX = 'theater-app-shell-';
const CACHE = PREFIX + BUILD.version;
const assets = new Set(BUILD.assets.map(path => new URL(path, self.location.origin).href));

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    if (!BUILD.assets.length) throw new Error('The PWA build has not been finalized.');
    const cache = await caches.open(CACHE);
    try {
      await cache.addAll(BUILD.assets.map(path => new Request(new URL(path, self.location.origin), {cache: 'reload', credentials: 'omit'})));
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
      const cached = await (await caches.open(CACHE)).match(url.href);
      return cached || fetch(request);
    })());
  }
});
