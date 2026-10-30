// Browser caches that hold account data outside the app's own storage (the
// service worker's wardrobe pictures); nothing to clear on other platforms.
export 'private_web_caches_io.dart'
    if (dart.library.js_interop) 'private_web_caches_web.dart';
