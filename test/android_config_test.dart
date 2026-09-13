import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Dart options agree with native Firebase initialization', () {
    final config =
        jsonDecode(File('config/production.android.json').readAsStringSync())
            as Map;
    final native =
        jsonDecode(File('android/app/google-services.json').readAsStringSync())
            as Map;
    final client =
        (native['client'] as List).singleWhere(
              (c) =>
                  c['client_info']['android_client_info']['package_name'] ==
                  'de.kolpingtheater.ramsen.theaterapp',
            )
            as Map;
    expect(
      config['FIREBASE_APP_ID'],
      client['client_info']['mobilesdk_app_id'],
    );
    expect(config['FIREBASE_PROJECT_ID'], native['project_info']['project_id']);
    // firebase_core rejects conflicting apiKey values as duplicate-app on every
    // cold start, even though both keys belong to the same Firebase project.
    expect(config['FIREBASE_API_KEY'], client['api_key'][0]['current_key']);
  });
}
