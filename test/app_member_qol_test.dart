import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/platform/pwa_install.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/app_version.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/identity.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/core/passkeys.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/auth/ui/account_providers_screen.dart';
import 'package:theater_app/features/auth/ui/firebase_welcome_screen.dart';
import 'package:theater_app/features/auth/ui/passkeys_screen.dart';
import 'package:theater_app/features/changelog/changelog.dart';
import 'package:theater_app/features/feedback/feedback.dart';
import 'package:theater_app/features/me/me.dart';
import 'package:theater_app/features/settings/settings.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;
import 'firebase_access_test.dart' show FakeIdentity;

class _PasskeyTestIdentity extends FakeIdentity implements PasskeyIdentity {
  final confirmations = <String>[];

  @override
  Future<void> signInWithCustomToken(String token, String expectedUid) async {
    uid = expectedUid;
    email = 'passkey@example.invalid';
  }

  @override
  Future<void> reauthenticateForPasskeys({
    String? password,
    String? provider,
  }) async {
    confirmations.add(provider ?? password ?? '');
  }

  @override
  Future<void> social(String provider, {bool link = false}) async {
    uid = 'google-uid';
    email = 'social@example.invalid';
  }
}

class _PasskeyTestDevice implements PasskeyDevice {
  bool available = true;
  final registrations = <JsonMap>[];

  @override
  Future<bool> supported(JsonMap configuration) async =>
      available && configuration['enabled'] == true;

  @override
  Future<JsonMap> authenticate(JsonMap options) async => {
    'id': 'signed-credential',
  };

  @override
  Future<JsonMap> register(JsonMap options) async {
    registrations.add(options);
    return {'id': 'new-credential'};
  }
}

class _MemberServer extends TestServer {
  @override
  JsonMap get user => {...super.user, 'role': 'member'};
}

String _normPath(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

void _size(WidgetTester tester, [Size size = const Size(600, 2000)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('cache-first start & welcome prefill', () {
    test(
      'legacy start with hydrated cache finishes init without waiting on slow network',
      () async {
        final server = TestServer();
        final store = MemoryLocalStore();
        final credentials = MemoryCredentialStore();
        final first = server.controller(store: store, credentials: credentials);
        await signIn(first);
        first.dispose();

        final snapshotRequested = Completer<void>();
        final snapshotGate = Completer<http.Response>();
        server.override = (request) {
          if (_normPath(request).endsWith('/snapshot')) {
            if (!snapshotRequested.isCompleted) snapshotRequested.complete();
            return snapshotGate.future;
          }
          return null;
        };
        final second = server.controller(
          store: store,
          credentials: credentials,
        );
        addTearDown(second.dispose);

        await second.init();
        expect(second.initialized, isTrue);
        expect(second.events, isNotEmpty);
        expect(second.firstSyncPending.value, isTrue);

        await snapshotRequested.future;
        snapshotGate.completeError(http.ClientException('offline'));
        await pumpEventQueue();
        expect(second.firstSyncPending.value, isFalse);
        expect(second.isOffline, isTrue);
        expect(second.events, isNotEmpty);
      },
    );

    test(
      'Firebase _restoreFirebase with hydrated cache avoids blocking init on hanging network',
      () async {
        final store = MemoryLocalStore();
        final credentials = MemoryCredentialStore();
        const origin = 'https://theater.example.invalid';
        const uid = 'member-uid';
        final account = base64Url.encode(utf8.encode('$origin\n$uid'));
        final userJson = {
          'userId': uid,
          'displayName': 'Cached Member',
          'email': 'cached@example.invalid',
          'status': 'approved',
          'role': 'member',
          'identityReady': true,
          'emailVerified': true,
          'personId': 1,
        };
        await store.write('_device', 'settings', {'baseUrl': origin});
        await credentials.write({
          'baseUrl': origin,
          'token': 'firebase:$uid',
          'user': userJson,
        });
        // Snapshot without user.userId skips _restoreCached and hits _restoreFirebase.
        final snapshot = DemoData(now: fixedNow).snapshot()..remove('user');
        await store.write(account, 'state', {'snapshot': snapshot});

        final requested = Completer<void>();
        final gate = Completer<http.Response>();
        final identity = _PasskeyTestIdentity()
          ..uid = uid
          ..email = 'cached@example.invalid';
        final controller = AppController(
          identity: identity,
          localStore: store,
          credentialStore: credentials,
          clock: () => fixedNow,
          apiClient: ApiClient(
            client: MockClient((_) {
              if (!requested.isCompleted) requested.complete();
              return gate.future;
            }),
          ),
        );
        addTearDown(controller.dispose);

        await controller.init();
        expect(controller.initialized, isTrue);
        expect(controller.hasAccess, isTrue);
        expect(controller.events, isNotEmpty);
        expect(controller.firstSyncPending.value, isTrue);

        await requested.future;
        gate.completeError(http.ClientException('timeout'));
        await pumpEventQueue();
        expect(controller.firstSyncPending.value, isFalse);
        expect(controller.isOffline, isTrue);
      },
    );

    testWidgets(
      'remembers last email & provider across logout and retries passkey check after error',
      (tester) async {
        _size(tester);
        final store = MemoryLocalStore();
        final credentials = MemoryCredentialStore();
        final identity = _PasskeyTestIdentity();
        final device = _PasskeyTestDevice();
        var configFails = true;
        var configCalls = 0;

        await store.write('_device', 'settings', {
          'baseUrl': 'https://theater.example.invalid',
        });

        AppController makeController() => AppController(
          identity: identity,
          passkeyDevice: device,
          localStore: store,
          credentialStore: credentials,
          clock: () => fixedNow,
          apiClient: ApiClient(
            client: MockClient((request) async {
              final path = _normPath(request);
              if (path.endsWith('/config')) {
                configCalls++;
                if (configFails) {
                  throw http.ClientException('offline');
                }
                return jsonResponse({
                  'passkeys': {'enabled': true},
                });
              }
              if (path.endsWith('/auth/session') || path.endsWith('/snapshot')) {
                return jsonResponse({
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
                });
              }
              return jsonResponse({'ok': true});
            }),
          ),
        );

        final first = makeController();
        await first.init();
        await first.login(
          email: 'lara@example.invalid',
          password: 'secret-long-password',
          baseUrl: 'https://theater.example.invalid',
        );
        await first.logout();
        first.dispose();

        final second = makeController();
        addTearDown(second.dispose);
        await second.init();
        expect(second.lastSignInEmail, 'lara@example.invalid');
        expect(second.lastSignInProvider, 'password');

        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: FirebaseWelcomeScreen(controller: second),
          ),
        );
        await tester.pumpAndSettle();

        // Prefilled email + last provider hint.
        final emailField = tester.widget<TextFormField>(
          find.byType(TextFormField).first,
        );
        expect(emailField.controller!.text, 'lara@example.invalid');
        expect(find.byKey(const ValueKey('last-sign-in-hint')), findsOneWidget);
        expect(
          find.text('Zuletzt angemeldet mit E-Mail & Passwort'),
          findsOneWidget,
        );

        // Initial /config failure exposes retry button and succeeds on retry.
        expect(configCalls, 1);
        expect(find.text('Mit Passkey anmelden'), findsNothing);
        final retry = find.byKey(const ValueKey('retry-passkey-check'));
        expect(retry, findsOneWidget);

        configFails = false;
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(configCalls, 2);
        expect(find.text('Mit Passkey anmelden'), findsOneWidget);
        expect(retry, findsNothing);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('passkey management QoL', () {
    testWidgets(
      'shows backedUp status, password visibility toggle, and passkey count on AccountProvidersScreen',
      (tester) async {
        _size(tester);
        final store = MemoryLocalStore();
        final credentials = MemoryCredentialStore();
        final identity = _PasskeyTestIdentity()
          ..uid = 'member'
          ..email = 'member@example.invalid'
          ..linkedProviders = ['password'];
        final device = _PasskeyTestDevice();
        final keys = <JsonMap>[
          {
            'id': 'k1',
            'name': 'iCloud Passkey',
            'createdAt': '2026-11-08T10:00:00Z',
            'lastUsedAt': null,
            'backedUp': true,
          },
          {
            'id': 'k2',
            'name': 'USB-Stick',
            'createdAt': '2026-11-08T10:00:00Z',
            'lastUsedAt': '2026-11-09T10:00:00Z',
            'backedUp': false,
          },
        ];
        var requireRecent = true;

        await store.write('_device', 'settings', {
          'baseUrl': 'https://theater.example.invalid',
        });
        final controller = AppController(
          identity: identity,
          passkeyDevice: device,
          localStore: store,
          credentialStore: credentials,
          clock: () => fixedNow,
          apiClient: ApiClient(
            client: MockClient((request) async {
              final path = _normPath(request);
              if (path.endsWith('/config')) {
                return jsonResponse({
                  'passkeys': {'enabled': true},
                });
              }
              if (path.endsWith('/auth/session') || path.endsWith('/snapshot')) {
                return jsonResponse({
                  'apiVersion': 1,
                  'user': {
                    'userId': 'member',
                    'email': 'member@example.invalid',
                    'displayName': 'Test Person',
                    'status': 'approved',
                    'role': 'member',
                    'identityReady': true,
                    'emailVerified': true,
                    'personId': 1,
                  },
                  'capabilities': {'features': []},
                });
              }
              if (path.endsWith('/passkeys')) {
                return jsonResponse({'passkeys': keys});
              }
              if (path.endsWith('/passkeys/k2') && request.method == 'DELETE') {
                if (requireRecent && identity.confirmations.isEmpty) {
                  return jsonResponse({
                    'error': 'Bitte bestätige deine Anmeldung erneut.',
                    'code': 'recent_login_required',
                  }, 401);
                }
                keys.removeWhere((k) => k['id'] == 'k2');
                return jsonResponse({'passkeys': keys});
              }
              return jsonResponse({'ok': true});
            }),
          ),
        );
        addTearDown(controller.dispose);
        await controller.init();
        await controller.refreshAccess();

        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: AccountProvidersScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('2 Passkeys eingerichtet'), findsOneWidget);

        await tester.tap(find.text('Passkeys'));
        await tester.pumpAndSettle();

        expect(find.byType(PasskeysScreen), findsOneWidget);
        expect(find.textContaining('Synchronisiert'), findsOneWidget);
        expect(find.textContaining('Gerätegebunden'), findsOneWidget);

        // Removing triggers 401 recent_login_required -> opens confirm dialog with visibility toggle.
        await tester.tap(find.byTooltip('USB-Stick entfernen'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Entfernen'));
        await tester.pumpAndSettle();
        expect(find.text('Anmeldung bestätigen'), findsOneWidget);

        final passwordField = find.byType(TextField).last;
        expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
        await tester.tap(find.byTooltip('Passwort anzeigen'));
        await tester.pump();
        expect(tester.widget<TextField>(passwordField).obscureText, isFalse);

        await tester.enterText(passwordField, 'existing-password');
        await tester.tap(find.text('Bestätigen'));
        await tester.pumpAndSettle();
        expect(identity.confirmations, ['existing-password']);
        expect(find.text('USB-Stick'), findsNothing);

        // Returning refreshes passkey count on AccountProvidersScreen.
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('1 Passkey eingerichtet'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('settings test push & offline reminder feedback', () {
    testWidgets(
      'shows Test-Push button when configured, disables it offline, and shows queued feedback on reminder switches',
      (tester) async {
        _size(tester);
        final server = TestServer();
        server.data['capabilities'] = {
          'pushConfigured': true,
          'emailConfigured': true,
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final devices = DeviceServices(
          controller,
          onTarget: (_) {},
          onForegroundMessage: (_) {},
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: SettingsScreen(controller: controller, devices: devices),
          ),
        );
        await tester.pumpAndSettle();

        final testPush = find.byKey(const ValueKey('test-push-button'));
        expect(testPush, findsOneWidget);
        expect(find.text('Test-Push senden'), findsOneWidget);
        await tester.tap(testPush);
        await tester.pumpAndSettle();
        expect(server.actionBodies.last['action'], 'push.test');
        expect(find.text('Test-Push angefordert.'), findsOneWidget);

        // Online toggle returns synced without queued message.
        expect(
          await controller.saveReminders({
            ...controller.reminders,
            'dayBefore': true,
          }),
          ActionOutcome.synced,
        );

        // Offline: Test-Push disabled, reminder toggle shows queued SnackBar.
        server.offline = true;
        await controller.refresh();
        await tester.pumpAndSettle();

        expect(
          tester.widget<ButtonStyleButton>(testPush).onPressed,
          isNull,
        );
        await tester.tap(find.widgetWithText(SwitchListTile, 'Am Vortag'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Vorgemerkt – wird übertragen'),
          findsOneWidget,
        );

        expect(
          await controller.saveCustomReminder(60),
          ActionOutcome.queued,
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('feedback & changelog QoL', () {
    testWidgets(
      'feedback thank-you screen links directly to the newly created ticket',
      (tester) async {
        _size(tester);
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['feedback', 'feedbackTickets'],
        };
        final createdTicket = {
          'id': 'fb-42',
          'message': 'Bitte Suchfeld ergänzen.',
          'category': 'idea',
          'status': 'open',
          'createdAt': fixedNow.toUtc().toIso8601String(),
          'updatedAt': fixedNow.toUtc().toIso8601String(),
          'version': 1,
          'appVersion': appVersion,
          'platform': 'android',
          'author': {'uid': 'member-a', 'personId': 1, 'name': 'Testmitglied'},
          'messages': [
            {
              'id': 'fb-42-0',
              'from': 'member',
              'text': 'Bitte Suchfeld ergänzen.',
              'at': fixedNow.toUtc().toIso8601String(),
              'author': {'personId': 1, 'name': 'Testmitglied'},
            },
          ],
          'lastActivityAt': fixedNow.toUtc().toIso8601String(),
          'unread': 0,
        };
        server.override = (request) {
          final path = _normPath(request);
          if (request.method == 'POST' && path.endsWith('/feedback')) {
            return Future.value(jsonResponse({'ok': true, 'id': 'fb-42'}));
          }
          if (request.method == 'GET' && path.endsWith('/feedback/fb-42')) {
            return Future.value(jsonResponse({'ticket': createdTicket}));
          }
          if (request.method == 'GET' && path.endsWith('/feedback')) {
            return Future.value(
              jsonResponse({'tickets': [createdTicket], 'unread': 0}),
            );
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);

        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: FeedbackFormScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey('feedback-message')),
          'Bitte Suchfeld ergänzen.',
        );
        await tester.pump();
        await tester.tap(find.text('Feedback senden'));
        await tester.pumpAndSettle();

        final openTicket = find.byKey(const ValueKey('feedback-open-ticket'));
        expect(openTicket, findsOneWidget);
        await tester.tap(openTicket);
        await tester.pumpAndSettle();

        final ticketPage = tester.widget<FeedbackTicketScreen>(
          find.byType(FeedbackTicketScreen),
        );
        expect(ticketPage.ticketId, 'fb-42');
        expect(find.text('Bitte Suchfeld ergänzen.'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'FeedbackAdminScreen filters tickets by text and author name',
      (tester) async {
        _size(tester);
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['feedback', 'feedbackTickets'],
        };
        final entries = [
          {
            'id': '1',
            'message': 'Der Spielplan ist super.',
            'category': 'idea',
            'status': 'open',
            'createdAt': fixedNow.toUtc().toIso8601String(),
            'updatedAt': fixedNow.toUtc().toIso8601String(),
            'version': 1,
            'appVersion': '0.16.2',
            'platform': 'android',
            'author': {'uid': 'u1', 'personId': 2, 'name': 'Mara Muster'},
            'messages': [
              {
                'id': '1-0',
                'from': 'member',
                'text': 'Der Spielplan ist super.',
                'at': fixedNow.toUtc().toIso8601String(),
                'author': {'personId': 2, 'name': 'Mara Muster'},
              },
            ],
            'lastActivityAt': fixedNow.toUtc().toIso8601String(),
            'unread': 0,
          },
          {
            'id': '2',
            'message': 'Login hängt im Keller.',
            'category': 'bug',
            'status': 'open',
            'createdAt': fixedNow.toUtc().toIso8601String(),
            'updatedAt': fixedNow.toUtc().toIso8601String(),
            'version': 1,
            'appVersion': '0.16.1',
            'platform': 'ios',
            'author': {'uid': 'u2', 'personId': 3, 'name': 'Jonas Bühne'},
            'messages': [
              {
                'id': '2-0',
                'from': 'member',
                'text': 'Login hängt im Keller.',
                'at': fixedNow.toUtc().toIso8601String(),
                'author': {'personId': 3, 'name': 'Jonas Bühne'},
              },
            ],
            'lastActivityAt': fixedNow.toUtc().toIso8601String(),
            'unread': 0,
          },
        ];
        server.override = (request) =>
            request.method == 'GET' && _normPath(request).endsWith('/admin/feedback')
            ? Future.value(jsonResponse({'feedback': entries}))
            : null;
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);

        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: FeedbackAdminScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        final search = find.byKey(const ValueKey('feedback-admin-search'));
        expect(search, findsOneWidget);

        // Search by author name.
        await tester.enterText(search, 'jonas');
        await tester.pumpAndSettle();
        expect(find.text('Login hängt im Keller.'), findsOneWidget);
        expect(find.text('Der Spielplan ist super.'), findsNothing);
        expect(find.text('Offen (1)'), findsOneWidget);

        // Search with zero hits shows reset action.
        await tester.enterText(search, 'unbekannter-begriff');
        await tester.pumpAndSettle();
        expect(find.text('Keine Treffer'), findsOneWidget);
        await tester.tap(find.text('Suche zurücksetzen'));
        await tester.pumpAndSettle();
        expect(find.text('Der Spielplan ist super.'), findsOneWidget);
        expect(find.text('Login hängt im Keller.'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'MyAreaScreen shows Neu badge for unseen changelog and member view hides admin items',
      (tester) async {
        _size(tester);
        final server = _MemberServer();
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final devices = DeviceServices(
          controller,
          onTarget: (_) {},
          onForegroundMessage: (_) {},
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: Scaffold(
              body: MyAreaScreen(
                controller: controller,
                devices: devices,
                installation: PwaInstallation(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('changelog-new-badge')),
          findsOneWidget,
        );
        await tester.tap(find.text('Changelog'));
        await tester.pumpAndSettle();

        // Member hides leadership-only items by default and can opt in via Alle zeigen.
        expect(find.textContaining('Für die Theaterleitung:'), findsNothing);
        expect(
          find.byKey(const ValueKey('changelog-show-all')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('changelog-show-all')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Für die Theaterleitung:'), findsWidgets);

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('changelog-new-badge')),
          findsNothing,
        );
        expect(controller.preferences[seenChangelogVersionKey], appVersion);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
