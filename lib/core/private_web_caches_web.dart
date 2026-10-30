import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('theaterPwa')
external _PwaBridge? get _bridge;

extension type _PwaBridge(JSObject _) implements JSObject {
  external JSPromise<JSAny?> clearPrivateCaches();
}

/// Removes the service worker's per-account picture caches (web/pwa.js).
/// Failures are ignored: the logout itself must never depend on them.
Future<void> clearPrivateWebCaches() async {
  final bridge = _bridge;
  if (bridge == null || !bridge.has('clearPrivateCaches')) return;
  try {
    await bridge.clearPrivateCaches().toDart;
  } catch (_) {}
}
