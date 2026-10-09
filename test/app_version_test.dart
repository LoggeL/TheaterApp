import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_version.dart';

void main() {
  test('the displayed version matches pubspec.yaml', () {
    final version = RegExp(
      r'^version: ([^+\s]+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(appVersion, version);
    expect(appVersionLabel, 'Version $appVersion');
  });
}
