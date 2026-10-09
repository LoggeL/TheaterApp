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
  if ('serviceWorker' in navigator && window.isSecureContext) {
    const version = document.querySelector('meta[name="theater-pwa-version"]')?.content;
    // A build-specific query also avoids stale proxy responses for this stable URL.
    navigator.serviceWorker.register(`theater-service-worker.js?v=${encodeURIComponent(version || 'development')}`, {
      scope: './', updateViaCache: 'none',
    }).then(registration => registration.update()).catch(() => {
      // Installation and normal online use still work if offline storage is unavailable.
    });
  }
})();
