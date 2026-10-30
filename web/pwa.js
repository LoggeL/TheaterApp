(() => {
  'use strict';
  const listeners = new Set();
  const standalone = window.matchMedia('(display-mode: standalone)');
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  // In-app browsers (WhatsApp, Instagram, Mail previews …) embed WebKit without
  // the Safari token and cannot add pages to the home screen.
  const embedded = ios && (!/Safari\//.test(navigator.userAgent) ||
    /FBAN|FBAV|Instagram/.test(navigator.userAgent));
  const dismissKey = 'theaterPwaHintDismissed';
  let dismissed = false;
  try { dismissed = localStorage.getItem(dismissKey) === '1'; } catch (_) {}
  let deferredPrompt = null;
  let installed = standalone.matches || navigator.standalone === true;
  const notify = () => listeners.forEach(listener => listener());
  window.theaterPwa = {
    get installed() { return installed; },
    get canPrompt() { return deferredPrompt !== null && !installed; },
    get embedded() { return embedded; },
    get dismissed() { return dismissed; },
    dismiss() {
      dismissed = true;
      try { localStorage.setItem(dismissKey, '1'); } catch (_) {}
      notify();
    },
    get platform() { return ios ? 'ios' : /Android/.test(navigator.userAgent) ? 'android' : /Mac/.test(navigator.platform) ? 'macos' : 'desktop'; },
    subscribe(listener) { listeners.add(listener); },
    unsubscribe(listener) { listeners.delete(listener); },
    async install() {
      const prompt = deferredPrompt;
      if (!prompt || installed) return false;
      deferredPrompt = null;
      notify();
      try {
        await prompt.prompt();
        const choice = await prompt.userChoice;
        if (choice.outcome === 'accepted') installed = true;
        return choice.outcome === 'accepted';
      } finally { notify(); }
    },
    // Logging out removes the wardrobe pictures the service worker keeps per account (prefix as in
    // theater-service-worker.js), also offline and on a page the worker does not control.
    async clearPrivateCaches() {
      const storage = window.caches;
      if (!storage) return;
      const keys = await storage.keys();
      await Promise.all(keys.filter(key => key.startsWith('theater-skins-v1-')).map(key => storage.delete(key)));
    },
  };
  window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault();
    deferredPrompt = event;
    notify();
  });
  window.addEventListener('appinstalled', () => {
    installed = true;
    deferredPrompt = null;
    notify();
  });
  standalone.addEventListener('change', () => {
    installed = standalone.matches || navigator.standalone === true;
    notify();
  });
  // The static start screen in index.html stays until Flutter shows its first picture.
  window.addEventListener('flutter-first-frame', () => {
    window.document?.getElementById('theater-splash')?.remove();
  }, {once: true});
  if ('serviceWorker' in navigator && window.isSecureContext) {
    let registered = false;
    // The worker's precache must not compete with the app's own start for the connection,
    // so it starts after the first picture; a start that never gets there registers after 10 s.
    const register = () => {
      if (registered) return;
      registered = true;
      const version = window.document?.querySelector('meta[name="theater-pwa-version"]')?.content;
      // A build-specific query also avoids stale proxy responses for this stable URL.
      navigator.serviceWorker.register(`theater-service-worker.js?v=${encodeURIComponent(version || 'development')}`, {
        scope: './', updateViaCache: 'none',
      }).then(registration => registration.update()).catch(() => {
        // Installation and normal online use still work if offline storage is unavailable.
      });
    };
    window.addEventListener('flutter-first-frame', register, {once: true});
    const idle = () => window.requestIdleCallback ? window.requestIdleCallback(register, {timeout: 2000}) : register();
    const fallback = () => window.setTimeout(idle, 10000);
    if (window.document?.readyState === 'complete') fallback();
    else window.addEventListener('load', fallback, {once: true});
  }
})();
