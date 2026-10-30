// tool/version-web.mjs replaces this config with the exact public build assets.
const BUILD = {version: 'development', assets: []};
const PREFIX = 'theater-app-shell-';
const CACHE = PREFIX + BUILD.version;
// Each renderer list holds the Dart entrypoint and engine files of one way the Flutter loader can start.
const renderers = BUILD.renderers || {};
const href = path => new URL(path, self.location.origin).href;
const assets = new Set([...BUILD.assets, ...Object.values(renderers).flat()].map(href));
// Files without a content hash in their name (index.html, manifests …); all others never change under their name.
const fresh = new Set((BUILD.fresh || []).map(href));
// A slow server answer gives way to the cached app shell of this version; the network answer still completes.
const NAVIGATION_TIMEOUT_MS = 3000;
// Wardrobe pictures and music are private but content-addressed (`?v=<hash>`, `immutable`). This cache
// is kept per account and outside PREFIX, so a new app version keeps it; logging out removes it.
const SKINS = 'theater-skins-v1-';
const SKIN_PATH = /^\/api\/mobile\/v1\/games\/runner\/skins\/[^/]+\/?$/;
const LOGOUT_PATH = /^\/api\/mobile\/v1\/auth\/logout\/?$/;
const MAX_SKINS = 600;

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
      // Content-addressed files an older version already holds are copied instead of downloaded again.
      const previous = (await caches.keys()).filter(key => key.startsWith(PREFIX) && key !== CACHE);
      const missing = await Promise.all([...BUILD.assets, ...startupRenderer()].map(async path => {
        const url = href(path);
        if (!fresh.has(url)) for (const name of previous) {
          const copy = await (await caches.open(name)).match(url);
          if (copy) { await cache.put(url, copy); return null; }
        }
        // Only the unhashed files must bypass the HTTP cache; a hashed name always holds the same bytes.
        return new Request(url, {cache: fresh.has(url) ? 'reload' : 'default', credentials: 'omit'});
      }));
      // Only the renderer this browser starts with; another one is kept once it is loaded.
      await cache.addAll(missing.filter(Boolean));
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
    // The page request starts while the worker boots instead of after it. The setting belongs to the
    // registration, not to this worker: a rollback to a worker without preload handling must disable it
    // in its activate (`self.registration.navigationPreload?.disable()`), or every navigation loads twice.
    try { await self.registration?.navigationPreload?.enable(); } catch {}
    await self.clients.claim();
  })());
});

// The account (`sub`) of a Firebase ID token, only to separate the caches of accounts sharing a browser.
// The server verifies every token; nothing here is trusted for access.
function tokenSubject(authorization) {
  const payload = /^Bearer [^.\s]+\.([^.\s]+)\.[^.\s]+$/.exec(authorization || '')?.[1];
  if (!payload) return null;
  try {
    const base64 = payload.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(payload.length / 4) * 4, '=');
    const sub = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(base64), c => c.charCodeAt(0)))).sub;
    return typeof sub === 'string' && sub ? sub : null;
  } catch { return null; }
}
const skinCacheNames = new Map();
async function skinCacheName(sub) {
  if (!skinCacheNames.has(sub)) {
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(sub)));
    skinCacheNames.set(sub, SKINS + [...digest].map(byte => byte.toString(16).padStart(2, '0')).join(''));
  }
  return skinCacheNames.get(sub);
}
// A hit must not repeat the server timing of the original request: the app reads `Server-Timing` as server time.
function storedSkin(response) {
  const headers = new Headers(response.headers);
  headers.delete('Server-Timing');
  return new Response(response.body, {status: response.status, statusText: response.statusText, headers});
}
async function skinResponse(event, request, url, sub) {
  // Without headers: another token of the same account finds the same entry despite `Vary: Authorization`.
  const key = new Request(url.href);
  let cache;
  try {
    cache = await caches.open(await skinCacheName(sub));
    const cached = await cache.match(key, {ignoreVary: true});
    if (cached) return cached;
  } catch {
    // Broken or full browser storage must not cost the picture; the server still delivers it.
    return fetch(request);
  }
  const response = await fetch(request);
  if (response.status === 200 && response.type === 'basic' && /\bimmutable\b/.test(response.headers.get('Cache-Control') || '')) {
    event.waitUntil((async () => {
      await cache.put(key, storedSkin(response.clone()));
      // Oldest first; an unbounded wardrobe history must not fill the browser's storage.
      const keys = await cache.keys();
      await Promise.all(keys.slice(0, Math.max(0, keys.length - MAX_SKINS)).map(old => cache.delete(old)));
    })().catch(() => {}));
  }
  return response;
}
async function removeSkinCaches() {
  const keys = await caches.keys();
  await Promise.all(keys.filter(key => key.startsWith(SKINS)).map(key => caches.delete(key)));
}

async function cachedPage(url) {
  const cache = await caches.open(CACHE);
  return await cache.match(url.pathname) || await cache.match('/index.html');
}
function navigation(event, request, url) {
  const network = (async () => (await event.preloadResponse) || fetch(request))();
  // A late server answer completes in the background (and warms the HTTP connection).
  event.waitUntil(network.then(() => {}, () => {}));
  return (async () => {
    let timer;
    const late = new Promise(resolve => { timer = setTimeout(resolve, NAVIGATION_TIMEOUT_MS, null); });
    try {
      const response = await Promise.race([network, late]);
      if (response) return response;
      // The fallback stays in this version's cache, so index.html and its assets belong together.
      return await cachedPage(url) || await network;
    } catch {
      return await cachedPage(url);
    } finally { clearTimeout(timer); }
  })();
}

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  const sameOrigin = url.origin === self.location.origin;
  if (sameOrigin && request.method === 'GET' && SKIN_PATH.test(url.pathname) && url.searchParams.get('v') &&
      !request.headers.has('Range')) {
    const sub = tokenSubject(request.headers.get('Authorization'));
    if (sub) { event.respondWith(skinResponse(event, request, url, sub)); return; }
  }
  // Works for every app version and offline as well; the request itself still goes to the server.
  if (sameOrigin && request.method === 'POST' && LOGOUT_PATH.test(url.pathname)) {
    event.waitUntil(removeSkinCaches().catch(() => {}));
    return;
  }
  // Authentication, other API responses and private media always use the network.
  if (request.method !== 'GET' || request.headers.has('Authorization') ||
      (sameOrigin && url.pathname.startsWith('/api/'))) return;
  if (request.mode === 'navigate' && sameOrigin) {
    event.respondWith(navigation(event, request, url));
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
