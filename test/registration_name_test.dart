import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/ui/firebase_auth.dart';

import 'firebase_access_test.dart' show FakeIdentity;

void main() {
  testWidgets(
    'pending social registration requires a name and keeps approval pending after saving',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final identity = FakeIdentity();
      String? submittedName;
      final controller = AppController(
        identity: identity,
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
        apiClient: ApiClient(
          client: MockClient((request) async {
            if (request.method == 'POST') {
              submittedName =
                  (jsonDecode(request.body) as Map)['registrationName']
                      as String;
            }
            return http.Response(
              jsonEncode({
                'user': {
                  'userId': identity.uid,
                  'displayName': submittedName ?? 'r8x',
                  'email': identity.email,
                  'status': 'pending',
                  'role': 'member',
                  'identityReady': true,
                  'needsRegistrationName': submittedName == null,
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );
      addTearDown(controller.dispose);
      await controller.init();
      await controller.login(
        email: 'r8x@example.invalid',
        password: 'test-password',
        baseUrl: 'https://theater.example.invalid',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AnimatedBuilder(
            animation: controller,
            builder: (context, _) =>
                ApprovalPendingScreen(controller: controller),
          ),
        ),
      );
      expect(find.text('Namen angeben'), findsOneWidget);
      final save = find.text('Namen speichern');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Bitte deinen Namen eingeben.'), findsOneWidget);
      expect(submittedName, isNull);
      await tester.enterText(find.byType(TextFormField), '  Sam Beispiel  ');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(submittedName, 'Sam Beispiel');
      expect(controller.hasAccess, isFalse);
      expect(controller.user!.needsRegistrationName, isFalse);
      expect(find.text('Freigabe ausstehend'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
