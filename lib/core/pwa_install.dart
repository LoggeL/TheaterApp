import 'package:flutter/foundation.dart';
import 'pwa_install_stub.dart'
    if (dart.library.js_interop) 'pwa_install_web.dart'
    as platform;

class PwaInstallation extends ChangeNotifier {
  static PwaInstallation create() => platform.createPwaInstallation();
  bool get available => false;
  bool get installed => false;
  bool get canPrompt => false;
  String get devicePlatform => 'desktop';
  Future<bool> prompt() async => false;
}
