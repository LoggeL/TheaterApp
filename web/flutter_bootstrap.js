{{flutter_js}}
{{flutter_build_config}}

// On high-DPR mobile screens (e.g. 3x iPhone = 9x pixel fill rate), cap Flutter's
// backing-store DPR at 2x to cut WebGL fill-rate, VRAM and Metal compositing bandwidth
// by ~56% while keeping 300+ ppi Retina sharpness. Desktop displays are unaffected.
(() => {
  'use strict';
  const nav = navigator || {};
  const minDim = Math.min(window.innerWidth || 0, window.innerHeight || 0);
  const smallViewport = minDim > 0 && minDim <= 520;
  const mobile = /iPad|iPhone|iPod|Android|Mobile/i.test(nav.userAgent || '') ||
    (nav.platform === 'MacIntel' && (nav.maxTouchPoints || 0) > 1) ||
    (typeof window.matchMedia === 'function' && window.matchMedia('(pointer: coarse)').matches) ||
    smallViewport;
  if (mobile && (window.devicePixelRatio || 1) > 2) {
    try {
      const desc = Object.getOwnPropertyDescriptor(window, 'devicePixelRatio') ||
        (typeof Window !== 'undefined' && Object.getOwnPropertyDescriptor(Window.prototype, 'devicePixelRatio'));
      if (!desc || desc.configurable) {
        const nativeGet = desc && typeof desc.get === 'function' ? desc.get : null;
        const clamp = v => (v > 2 ? 2 : v);
        let lastRaw = nativeGet ? nativeGet.call(window) : 2;
        // Expose the capped DPR as a plain data property (not a JS getter) so
        // Flutter's frequent per-frame devicePixelRatio reads stay on the fast
        // property-load path without invoking a getter closure every read.
        Object.defineProperty(window, 'devicePixelRatio', {
          configurable: true,
          enumerable: true,
          writable: true,
          value: clamp(lastRaw),
        });
        if (nativeGet) {
          function watchMedia() {
            if (typeof window.matchMedia !== 'function') return;
            const mq = window.matchMedia(`(resolution: ${lastRaw}dppx)`);
            if (mq && typeof mq.addEventListener === 'function') {
              mq.addEventListener('change', syncDpr, {once: true, passive: true});
            }
          }
          function syncDpr() {
            const raw = nativeGet.call(window);
            if (raw !== lastRaw) {
              lastRaw = raw;
              window.devicePixelRatio = clamp(raw);
              watchMedia();
            }
          }
          if (typeof window.addEventListener === 'function') {
            window.addEventListener('resize', syncDpr, {passive: true});
          }
          if (window.visualViewport && typeof window.visualViewport.addEventListener === 'function') {
            window.visualViewport.addEventListener('resize', syncDpr, {passive: true});
          }
          watchMedia();
        }
      }
    } catch (_) {}
  }

  // Serve the renderer with the app so the offline cache includes it.
  // Cap overlay WebGL surfaces on mobile/WebKit to stay well within Safari's WebGL context limit.
  _flutter.loader.load({
    config: {
      assetBase: './',
      canvasKitBaseUrl: 'canvaskit/',
      canvasKitMaximumSurfaces: mobile ? 2 : 4,
    },
  });
})();
