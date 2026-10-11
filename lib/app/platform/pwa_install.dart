import 'package:flutter/foundation.dart';
import 'pwa_install_stub.dart'
    if (dart.library.js_interop) 'pwa_install_web.dart'
    as platform;

class PwaInstallation extends ChangeNotifier {
  static PwaInstallation create() => platform.createPwaInstallation();
  bool get available => false;
  bool get installed => false;
  bool get canPrompt => false;

  /// An in-app browser that cannot add pages to the home screen.
  bool get embedded => false;

  /// The member hid the install hint on the home screen.
  bool get dismissed => false;
  void dismiss() {}
  String get devicePlatform => 'desktop';
  Future<bool> prompt() async => false;
}
