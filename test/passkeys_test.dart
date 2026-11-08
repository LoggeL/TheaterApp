import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/identity.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/core/passkeys.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/auth/ui/firebase_welcome_screen.dart';
import 'package:theater_app/features/auth/ui/passkeys_screen.dart';

import 'firebase_access_test.dart' show FakeIdentity;

class _Identity extends FakeIdentity implements PasskeyIdentity {
  final customTokens = <String>[];
  final confirmations = <String>[];
  @override
  Future<void> signInWithCustomToken(String token, String expectedUid) async {
    customTokens.add(token);
    uid = expectedUid;
    email = 'member@example.invalid';
  }

  @override
  Future<void> reauthenticateForPasskeys({
    String? password,
    String? provider,
  }) async {
    confirmations.add(provider ?? password ?? '');
  }
}

class _Device implements PasskeyDevice {
  bool available = true;
  Object? error;
  Completer<JsonMap>? authentication;
  Completer<void>? prompted;
  final registrations = <JsonMap>[];
  @override
  Future<bool> supported(JsonMap configuration) async =>
      available && configuration['enabled'] == true;
  @override
  Future<JsonMap> authenticate(JsonMap options) async {
    prompted?.complete();
    if (error != null) throw error!;
    return authentication?.future ?? {'id': 'signed-credential'};
  }

  @override
  Future<JsonMap> register(JsonMap options) async {
    registrations.add(options);
    if (error != null) throw error!;
    return {'id': 'new-credential'};
  }
}

class _Harness {
  final identity = _Identity();
  final device = _Device();
  final store = MemoryLocalStore();
  final credentials = MemoryCredentialStore();
  final requests = <http.Request>[];
  final keys = <JsonMap>[];
  late AppController controller;
  bool enabled = true;
  bool rejectLogin = false;
  Future<void> init() async {
    await store.write('_device', 'settings', {
      'baseUrl': 'https://theater.example.invalid',
    });
    controller = AppController(
      identity: identity,
      passkeyDevice: device,
      localStore: store,
      credentialStore: credentials,
      apiClient: ApiClient(
        client: MockClient((request) async {
          requests.add(request);
          final path = request.url.path
              .replaceFirst('/api/mobile/v1', '')
              .replaceFirst(RegExp(r'/$'), '');
          JsonMap payload = {};
          var status = 200;
          switch (path) {
            case '/config':
              payload = {
                'passkeys': {'enabled': enabled},
              };
            case '/auth/passkeys/options':
              payload = {
                'challengeId': 'login-challenge',
                'options': {'challenge': 'test'},
              };
            case '/auth/passkeys/verify':
              payload = rejectLogin
                  ? {'error': 'Passkey ungültig', 'code': 'passkey_invalid'}
                  : {'token': 'one-time-custom-token', 'uid': 'member'};
              status = rejectLogin ? 401 : 200;
            case '/auth/session':
            case '/snapshot':
              payload = {
                'apiVersion': 1,
                'user': {
                  'userId': identity.uid,
                  'email': identity.email,
                  'displayName': 'Test Person',
                  'status': 'approved',
                  'role': 'member',
                  'identityReady': true,
                  'emailVerified': true,
                  'personId': 1,
                },
                'capabilities': {'features': []},
              };
            case '/passkeys':
              payload = {'passkeys': keys};
            case '/passkeys/options':
              payload = {
                'challengeId': 'register-challenge',
                'options': {'challenge': 'create'},
              };
            case '/passkeys/verify':
              keys.add({
                'id': 'key-id',
                'name': 'Mein Passkey',
                'createdAt': '2026-11-08T10:00:00Z',
                'lastUsedAt': null,
              });
              payload = {'passkeys': keys};
            case '/passkeys/key-id':
              keys.clear();
              payload = {'passkeys': keys};
          }
          return http.Response(
            jsonEncode(payload),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );
    await controller.init();
  }
}

void main() {
  late _Harness h;
  setUp(() async {
    h = _Harness();
    await h.init();
  });
  tearDown(() => h.controller.dispose());

  test(
    'custom token is exchanged before adopting the same Firebase UID and never persisted',
    () async {
      await h.controller.loginWithPasskey();
      expect(h.identity.customTokens, ['one-time-custom-token']);
      expect(h.controller.user!.id, 'member');
      expect(h.controller.hasAccess, isTrue);
      final saved = jsonEncode(await h.credentials.read());
      expect(saved, contains('firebase:member'));
      expect(saved, isNot(contains('one-time-custom-token')));
      final public = h.requests.where(
        (r) => r.url.path.contains('/auth/passkeys/'),
      );
      expect(
        public.every((r) => !r.headers.containsKey('authorization')),
        isTrue,
      );
      expect(
        h.requests
            .where((r) => r.url.path.endsWith('/auth/session/'))
            .single
            .headers['authorization'],
        'Bearer fresh-token',
      );
    },
  );

  test(
    'a rejected assertion never reaches Firebase or installs a session',
    () async {
      h.rejectLogin = true;
      await expectLater(
        h.controller.loginWithPasskey(),
        throwsA(isA<ApiException>()),
      );
      expect(h.identity.customTokens, isEmpty);
      expect(h.controller.user, isNull);
      expect(await h.credentials.read(), isNull);
    },
  );

  test(
    'logging out while the device prompt is open prevents token exchange',
    () async {
      h.device.authentication = Completer<JsonMap>();
      h.device.prompted = Completer<void>();
      final login = h.controller.loginWithPasskey();
      final rejected = expectLater(
        login,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
        ),
      );
      await h.device.prompted!.future;
      final logout = h.controller.logout();
      // Logout clears the generation before it waits for the in-flight identity transition.
      await Future<void>.delayed(Duration.zero);
      h.device.authentication!.complete({'id': 'signed-credential'});
      await rejected;
      await logout;
      expect(h.identity.customTokens, isEmpty);
      expect(
        h.requests.any((r) => r.url.path.endsWith('/auth/passkeys/verify/')),
        isFalse,
      );
    },
  );

  test(
    'management uses authenticated API calls without adding to the offline queue',
    () async {
      await h.controller.loginWithPasskey();
      await h.controller.confirmPasskeyManagement(
        password: 'existing password',
      );
      final added = await h.controller.addPasskey('Mein Passkey');
      expect(added.single['id'], 'key-id');
      expect(h.identity.confirmations, ['existing password']);
      expect(h.device.registrations.single, {'challenge': 'create'});
      final finish = h.requests.singleWhere(
        (r) => r.url.path == '/api/mobile/v1/passkeys/verify/',
      );
      expect(jsonDecode(finish.body), {
        'challengeId': 'register-challenge',
        'response': {'id': 'new-credential'},
      });
      expect(finish.headers['authorization'], 'Bearer fresh-token');
      expect(finish.headers['idempotency-key'], isNull);
      expect(await h.controller.removePasskey('key-id'), isEmpty);
      expect(h.requests.any((r) => r.url.path.endsWith('/actions/')), isFalse);
    },
  );

  testWidgets(
    'login button is offered only when the device and backend support it; cancellation retains password login',
    (tester) async {
      h.device.error = const ApiException(
        'cancelled',
        code: 'passkey_cancelled',
      );
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: FirebaseWelcomeScreen(controller: h.controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Mit Passkey anmelden'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.text('cancelled'), findsNothing);
      expect(find.text('Passwort'), findsOneWidget);
      expect(h.identity.customTokens, isEmpty);
      await tester.pumpWidget(const SizedBox());
      h.enabled = false;
      await tester.pumpWidget(
        MaterialApp(home: FirebaseWelcomeScreen(controller: h.controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mit Passkey anmelden'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'adding a passkey confirms the existing account before opening the device prompt',
    (tester) async {
      await tester.runAsync(h.controller.loginWithPasskey);
      tester.view.physicalSize = const Size(600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: PasskeysScreen(controller: h.controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Passkey hinzufügen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Weiter'));
      await tester.pumpAndSettle();
      expect(h.device.registrations, isEmpty);
      await tester.enterText(find.byType(TextField).last, 'existing password');
      await tester.runAsync(() async {
        await tester.tap(find.text('Bestätigen'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(h.identity.confirmations, ['existing password']);
      expect(find.text('Mein Passkey'), findsOneWidget);
      expect(h.device.registrations, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('passkey management fits narrow screens at double text size', (
    tester,
  ) async {
    await tester.runAsync(h.controller.loginWithPasskey);
    h.keys.add({
      'id': 'key-id',
      'name': 'Mein sehr langer Passwortmanager auf dem Telefon',
      'createdAt': '2026-11-08T10:00:00Z',
    });
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 740),
            textScaler: TextScaler.linear(2),
          ),
          child: PasskeysScreen(controller: h.controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox());
  });
}
