// tool/version-web.mjs replaces this config with the exact public build assets.
const BUILD = {version: 'development', assets: []};
const PREFIX = 'theater-app-shell-';
const CACHE = PREFIX + BUILD.version;
const ORIGIN = self.location.origin;
const ORIGIN_PREFIX = ORIGIN + '/';
const API_PREFIX = ORIGIN + '/api/';
const SKIN_PREFIX = ORIGIN + '/api/mobile/v1/games/runner/skins/';
const LOGOUT_PREFIX = ORIGIN + '/api/mobile/v1/auth/logout';
// Each renderer list holds the Dart entrypoint and engine files of one way the Flutter loader can start.
const renderers = BUILD.renderers || {};
const href = path => new URL(path, ORIGIN).href;
const assets = new Set([...BUILD.assets, ...Object.values(renderers).flat()].map(href));
// Files without a content hash in their name (index.html, manifests …); all others never change under their name.
const fresh = new Set((BUILD.fresh || []).map(href));
// A slow server answer or a 5xx (a restart, an outage) gives way to the cached app shell of this version;
// the network answer still completes.
const NAVIGATION_TIMEOUT_MS = 2000;
// Wardrobe pictures and music are private but content-addressed (`?v=<hash>`, `immutable`). This cache
// is kept per account and outside PREFIX, so a new app version keeps it; logging out removes it.
const SKINS = 'theater-skins-v1-';
const SKIN_PATH = /^\/api\/mobile\/v1\/games\/runner\/skins\/[^/]+\/?$/;
const LOGOUT_PATH = /^\/api\/mobile\/v1\/auth\/logout\/?$/;
const MAX_SKINS = 600;
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

let appCachePromise = null;
function appCache() {
  if (!appCachePromise) {
    appCachePromise = caches.open(CACHE).catch(error => {
      appCachePromise = null;
      throw error;
    });
  }
  return appCachePromise;
}

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
    const cache = await appCache();
    try {
      // Content-addressed files an older version already holds are copied instead of downloaded again.
      const previousNames = (await caches.keys()).filter(key => key.startsWith(PREFIX) && key !== CACHE);
      const previousCaches = await Promise.all(previousNames.map(name => caches.open(name)));
      const missing = await Promise.all([...BUILD.assets, ...startupRenderer()].map(async path => {
        const url = href(path);
        if (!fresh.has(url)) for (const oldCache of previousCaches) {
          const copy = await oldCache.match(url);
          if (copy) { await cache.put(url, copy); return null; }
        }
        // Only the unhashed files must bypass the HTTP cache; a hashed name always holds the same bytes.
        return new Request(url, {cache: fresh.has(url) ? 'reload' : 'default', credentials: 'omit'});
      }));
      // Only the renderer this browser starts with; another one is kept once it is loaded.
      await cache.addAll(missing.filter(Boolean));
    } catch (error) {
      appCachePromise = null;
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
let lastAuthHeader = null;
let lastAuthSub = null;
function tokenSubject(authorization) {
  if (!authorization) return null;
  if (authorization === lastAuthHeader) return lastAuthSub;
  const payload = /^Bearer [^.\s]+\.([^.\s]+)\.[^.\s]+$/.exec(authorization)?.[1];
  if (!payload) return null;
  try {
    const base64 = payload.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(payload.length / 4) * 4, '=');
    const sub = JSON.parse(textDecoder.decode(Uint8Array.from(atob(base64), c => c.charCodeAt(0)))).sub;
    const valid = typeof sub === 'string' && sub ? sub : null;
    lastAuthHeader = authorization;
    lastAuthSub = valid;
    return valid;
  } catch { return null; }
}
const skinCacheNames = new Map();
const skinCaches = new Map();
const skinCounts = new Map();
async function skinCacheName(sub) {
  if (!skinCacheNames.has(sub)) {
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', textEncoder.encode(sub)));
    skinCacheNames.set(sub, SKINS + [...digest].map(byte => byte.toString(16).padStart(2, '0')).join(''));
  }
  return skinCacheNames.get(sub);
}
function openSkinCache(name) {
  let pending = skinCaches.get(name);
  if (!pending) {
    pending = caches.open(name).catch(error => {
      skinCaches.delete(name);
      throw error;
    });
    skinCaches.set(name, pending);
  }
  return pending;
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
  let cacheName, cache;
  try {
    cacheName = await skinCacheName(sub);
    cache = await openSkinCache(cacheName);
    const cached = await cache.match(key, {ignoreVary: true});
    if (cached) return cached;
  } catch {
    if (cacheName) skinCaches.delete(cacheName);
    // Broken or full browser storage must not cost the picture; the server still delivers it.
    return fetch(request);
  }
  const response = await fetch(request);
  if (response.status === 200 && response.type === 'basic' && /\bimmutable\b/.test(response.headers.get('Cache-Control') || '')) {
    event.waitUntil((async () => {
      await cache.put(key, storedSkin(response.clone()));
      // Oldest first; an unbounded wardrobe history must not fill the browser's storage.
      // Track count in memory so we only scan cache.keys() on cold start or once over MAX_SKINS.
      let count = skinCounts.get(cacheName);
      if (count == null) {
        const keys = await cache.keys();
        count = keys.length;
        if (count > MAX_SKINS) {
          await Promise.all(keys.slice(0, count - MAX_SKINS).map(old => cache.delete(old)));
          count = MAX_SKINS;
        }
      } else {
        count++;
        if (count > MAX_SKINS) {
          const keys = await cache.keys();
          if (keys.length > MAX_SKINS) {
            await Promise.all(keys.slice(0, keys.length - MAX_SKINS).map(old => cache.delete(old)));
            count = MAX_SKINS;
          } else {
            count = keys.length;
          }
        }
      }
      skinCounts.set(cacheName, count);
    })().catch(() => {}));
  }
  return response;
}
async function removeSkinCaches() {
  lastAuthHeader = null;
  lastAuthSub = null;
  skinCaches.clear();
  skinCounts.clear();
  const keys = await caches.keys();
  await Promise.all(keys.filter(key => key.startsWith(SKINS)).map(key => caches.delete(key)));
}

async function cachedPage(url) {
  const cache = await appCache();
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
      if (response && response.status < 500) return response;
      // The fallback stays in this version's cache, so index.html and its assets belong together.
      return await cachedPage(url) || response || await network;
    } catch {
      return await cachedPage(url);
    } finally { clearTimeout(timer); }
  })();
}

function stripSearchAndHash(rawUrl) {
  const q = rawUrl.indexOf('?');
  const h = rawUrl.indexOf('#');
  const cut = q === -1 ? h : h === -1 ? q : Math.min(q, h);
  return cut === -1 ? rawUrl : rawUrl.slice(0, cut);
}

self.addEventListener('fetch', event => {
  const request = event.request;
  const rawUrl = request.url;
  const method = request.method;
  if (method !== 'GET') {
    // Works for every app version and offline as well; the request itself still goes to the server.
    if (method === 'POST' && rawUrl.startsWith(LOGOUT_PREFIX)) {
      const pathname = stripSearchAndHash(rawUrl).slice(ORIGIN.length);
      if (LOGOUT_PATH.test(pathname)) {
        event.waitUntil(removeSkinCaches().catch(() => {}));
      }
    }
    return;
  }
  const sameOrigin = rawUrl.startsWith(ORIGIN_PREFIX) || rawUrl === ORIGIN;
  if (sameOrigin && rawUrl.startsWith(API_PREFIX)) {
    // Fast bypass for all non-skin API requests without allocating a URL or inspecting headers.
    if (!rawUrl.startsWith(SKIN_PREFIX)) return;
    const url = new URL(rawUrl);
    if (SKIN_PATH.test(url.pathname) && url.searchParams.get('v') && !request.headers.has('Range')) {
      const sub = tokenSubject(request.headers.get('Authorization'));
      if (sub) event.respondWith(skinResponse(event, request, url, sub));
    }
    return;
  }
  // Authorized media and non-public requests always use the network.
  if (request.headers.has('Authorization')) return;
  if (request.mode === 'navigate' && sameOrigin) {
    event.respondWith(navigation(event, request, new URL(rawUrl)));
    return;
  }
  const cleanHref = stripSearchAndHash(rawUrl);
  if (!assets.has(cleanHref)) return;
  event.respondWith((async () => {
    const cache = await appCache();
    const cached = await cache.match(cleanHref);
    if (cached) return cached;
    const response = await fetch(request);
    // Build files are content-addressed, so a late copy is still the right one.
    if (response.ok && response.type === 'basic') event.waitUntil(cache.put(cleanHref, response.clone()).catch(() => {}));
    return response;
  })());
});
