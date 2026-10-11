import 'dart:js_interop';
import 'pwa_install.dart';

@JS('theaterPwa')
external _PwaBridge? get _bridge;

extension type _PwaBridge(JSObject _) implements JSObject {
  external JSBoolean get installed;
  external JSBoolean get canPrompt;
  external JSString get platform;
  external JSBoolean? get embedded;
  external JSBoolean? get dismissed;
  external void dismiss();
  external void subscribe(JSFunction listener);
  external void unsubscribe(JSFunction listener);
  external JSPromise<JSBoolean> install();
}

PwaInstallation createPwaInstallation() => _WebPwaInstallation();

class _WebPwaInstallation extends PwaInstallation {
  _WebPwaInstallation() {
    _listener = (() => notifyListeners()).toJS;
    _bridge?.subscribe(_listener);
  }
  late final JSFunction _listener;
  @override
  bool get available => _bridge != null;
  @override
  bool get installed => _bridge?.installed.toDart ?? false;
  @override
  bool get canPrompt => _bridge?.canPrompt.toDart ?? false;
  @override
  bool get embedded => _bridge?.embedded?.toDart ?? false;
  @override
  bool get dismissed => _bridge?.dismissed?.toDart ?? false;
  @override
  void dismiss() => _bridge?.dismiss();
  @override
  String get devicePlatform => _bridge?.platform.toDart ?? 'desktop';
  @override
  Future<bool> prompt() async =>
      (await _bridge?.install().toDart)?.toDart ?? false;
  @override
  void dispose() {
    _bridge?.unsubscribe(_listener);
    super.dispose();
  }
}
