import 'dart:io';

import 'package:flutter/services.dart';

/// Answered by MainActivity (android/app/src/main/kotlin/…/MainActivity.kt).
const _device = MethodChannel('theater/device');

/// Milliseconds since the page started loading; only on the web.
double? pageClockMs() => null;

/// Device facts that do not change while the app runs. On Android also
/// `processAgeMs`: how long the process has been running at the answer.
Future<Map<String, Object>> probeDevice() async {
  final out = <String, Object>{
    'platform': Platform.isAndroid
        ? 'android'
        : Platform.isIOS
        ? 'ios'
        : Platform.operatingSystem,
    'cores': Platform.numberOfProcessors,
  };
  if (Platform.isAndroid || Platform.isIOS) {
    out['renderer'] = 'impeller';
    out['mobile'] = true;
  }
  if (!Platform.isAndroid) return out;
  try {
    final info = await _device.invokeMapMethod<String, Object?>('info');
    if (info == null) return out;
    final model = info['model'], sdk = info['sdk'], release = info['release'];
    final memory = info['memoryMb'], age = info['processAgeMs'];
    if (model is String) out['model'] = model;
    if (sdk is int) out['sdk'] = sdk;
    out['os'] = release is String ? 'Android $release' : 'Android';
    if (memory is int && memory > 0) {
      out['mem'] = (memory / 1024 * 10).roundToDouble() / 10;
    }
    if (age is int && age >= 0) out['processAgeMs'] = age;
  } on PlatformException {
    // Older app builds without the channel report less.
  } on MissingPluginException {
    // Same.
  }
  return out;
}

/// Context that can change while the app runs.
Map<String, Object> currentContext() => const {};

/// How the page was loaded; only on the web.
Map<String, Object> startInfo() => const {};

/// Page visibility callbacks exist only on the web; elsewhere the app
/// lifecycle reports going to the background.
void onPageHidden(void Function() hidden) {}
