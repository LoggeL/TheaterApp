import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/app/shell/app_section.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/auth/auth.dart';
import 'package:theater_app/main.dart';

import 'app_controller_test.dart' show fixedNow, jsonResponse;
import 'firebase_access_test.dart' show FakeIdentity;

bool isPath(http.Request request, String path) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '').endsWith(path);

/// Like Firebase: no uid until the sign-in is restored, which [gate] holds.
class GatedIdentity extends FakeIdentity {
  GatedIdentity(this.restoredUid);
  String? restoredUid;
  Completer<void>? gate = Completer<void>();
  bool ready = false;
  int signOuts = 0;

  @override
  String? get uid => ready ? restoredUid : null;
  @override
  set uid(String? value) => restoredUid = value;

  @override
  Future<void> initialize() async {
    await gate?.future;
    ready = true;
  }

  void release() {
    if (!gate!.isCompleted) gate!.complete();
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    restoredUid = null;
  }
}

/// A Firebase server: `/auth/session`, `/snapshot`, `/actions`, `/devices`.
class FirebaseServer {
  String status = 'approved';
  List<String> features = ['addressedToMe'];
  final requests = <String>[];
  Future<http.Response>? Function(http.Request)? override;

  int count(String method, String path) =>
      requests.where((r) => r == '$method $path').length;

  JsonMap user(String uid) => {
    'userId': uid,
    'displayName': 'Testmitglied',
    'email': uid,
    'role': 'member',
    'status': status,
    'personId': status == 'approved' ? 1 : null,
    'identityReady': true,
    'emailVerified': true,
    // The app does not keep `provider`; it used to break the comparison.
    'provider': 'password',
    'permissions': <String>[],
  };

  JsonMap snapshot(String uid) => {
    ...DemoData(now: fixedNow).snapshot(),
    'user': user(uid),
    'capabilities': {'pushConfigured': true, 'features': features},
    'serverTime': DateTime.now().toIso8601String(),
  };

  MockClient client(String? Function() uid) => MockClient((request) async {
    final path = request.url.path
        .replaceFirst(ApiClient.pathPrefix, '')
        .replaceFirst(RegExp(r'/$'), '');
    requests.add('${request.method} $path');
    final special = override?.call(request);
    if (special != null) return special;
    final who = uid() ?? '';
    return switch (path) {
      '/auth/session' => jsonResponse({'user': user(who)}),
      '/snapshot' when status != 'approved' => jsonResponse({
        'error': 'Dein Theaterzugang ist noch nicht freigegeben.',
        'code': 'access',
      }, 403),
      '/snapshot' => jsonResponse(snapshot(who)),
      '/devices' => jsonResponse({'ok': true, 'pushEnabled': true}),
      '/actions' => jsonResponse({'ok': true, 'id': 'server-id'}),
      _ => jsonResponse({'ok': true}),
    };
  });
}

class Session {
  Session(this.server, {this.uid = 'a@example.invalid'});
  final FirebaseServer server;
  final String uid;
  final store = MemoryLocalStore();
  final credentials = MemoryCredentialStore();
  var now = fixedNow;

  AppController controller(FakeIdentity identity) => AppController(
    identity: identity,
    localStore: store,
    credentialStore: credentials,
    apiClient: ApiClient(client: server.client(() => identity.uid)),
    clock: () => now,
  );

  /// Signs in once and syncs, so the next start finds stored data.
  Future<void> signInOnce() async {
    final identity = FakeIdentity();
    final c = controller(identity);
    await c.init();
    await c.login(
      email: uid,
      password: 'Long password!2026',
      baseUrl: 'https://theater.example.invalid',
    );
    expect(c.hasAccess, server.status == 'approved');
    c.dispose();
    server.requests.clear();
  }
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('silent sync', () {
    test('an unchanged sync notifies no listener', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      final c = session.controller(GatedIdentity(session.uid)..release());
      addTearDown(c.dispose);
      await c.init();
      await c.refresh(silent: true);
      var notified = 0;
      c.addListener(() => notified++);
      // Within the access interval only the snapshot is asked.
      await c.refresh(silent: true);
      expect(notified, 0);
      expect(session.server.count('GET', '/auth/session'), 1);
      // With a due access check as well.
      session.now = session.now.add(AppController.accessCheckInterval);
      await c.refresh(silent: true);
      expect(notified, 0);
      expect(session.server.count('GET', '/auth/session'), 2);
      expect(session.server.count('GET', '/snapshot'), 3);
    });

    test('a changed user still redraws once', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      final c = session.controller(GatedIdentity(session.uid)..release());
      addTearDown(c.dispose);
      await c.init();
      await c.refresh(silent: true);
      var notified = 0;
      c.addListener(() => notified++);
      session.server.override = (request) => isPath(request, '/snapshot')
          ? Future.value(
              jsonResponse({
                ...session.server.snapshot(session.uid),
                'user': {
                  ...session.server.user(session.uid),
                  'displayName': 'Neuer Name',
                },
              }),
            )
          : null;
      await c.refresh(silent: true);
      expect(notified, 1);
      expect(c.user!.name, 'Neuer Name');
    });

    test('a clean send refreshes without showing progress', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      final c = session.controller(GatedIdentity(session.uid)..release());
      addTearDown(c.dispose);
      await c.init();
      await c.refresh(silent: true);
      final busy = <bool>[];
      c.addListener(() => busy.add(c.busy));
      final event = c.events.first;
      await c.respond(event.id, 'yes');
      expect(busy, isNot(contains(true)));
      expect(session.server.count('POST', '/actions'), 1);
      expect(session.server.count('GET', '/snapshot'), 2);
      expect(c.pendingCount, 0);
    });
  });

  group('cache-first start', () {
    test(
      'shows stored data before Firebase answers and needs no network',
      () async {
        final session = Session(FirebaseServer());
        await session.signInOnce();
        final identity = GatedIdentity(session.uid);
        final c = session.controller(identity);
        addTearDown(c.dispose);
        await c.init();
        expect(c.initialized, isTrue);
        expect(c.hasAccess, isTrue);
        expect(c.user!.id, session.uid);
        expect(c.events, isNotEmpty);
        expect(c.error, isNull);
        expect(c.isOffline, isFalse);
        expect(session.server.requests, isEmpty);
        // A refresh started meanwhile joins the start's own sync.
        final joined = c.refresh(silent: true);
        await Future<void>.delayed(Duration.zero);
        expect(session.server.requests, isEmpty);
        identity.release();
        await joined;
        expect(session.server.requests, ['GET /auth/session', 'GET /snapshot']);
        expect(c.hasAccess, isTrue);
      },
    );

    test('a start makes exactly one GET /auth/session', () async {
      for (final cacheFirst in [true, false]) {
        final server = FirebaseServer();
        if (!cacheFirst) server.features = ['noCacheFirstStart'];
        final session = Session(server);
        await session.signInOnce();
        final identity = GatedIdentity(session.uid)..release();
        final c = session.controller(identity);
        await c.init();
        // Joins the background sync; without cache-first `init` waited.
        if (cacheFirst) await c.refresh(silent: true);
        expect(server.count('GET', '/auth/session'), 1, reason: '$cacheFirst');
        expect(server.count('GET', '/snapshot'), 1, reason: '$cacheFirst');
        c.dispose();
      }
    });

    test('the server can switch it off', () async {
      final server = FirebaseServer()..features = ['noCacheFirstStart'];
      final session = Session(server);
      await session.signInOnce();
      final identity = GatedIdentity(session.uid);
      final c = session.controller(identity);
      addTearDown(c.dispose);
      var done = false;
      final start = c.init().then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(done, isFalse);
      expect(c.initialized, isFalse);
      identity.release();
      await start;
      expect(c.hasAccess, isTrue);
      expect(server.count('GET', '/auth/session'), 1);
    });

    test('another Firebase account drops the shown data', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      session.server.status = 'pending';
      final identity = GatedIdentity('b@example.invalid');
      final c = session.controller(identity);
      addTearDown(c.dispose);
      await c.init();
      expect(c.user!.id, session.uid);
      final epoch = c.sessionEpoch;
      identity.release();
      await c.refresh();
      await pumpEventQueue();
      expect(c.sessionEpoch, greaterThan(epoch));
      expect(c.user!.id, 'b@example.invalid');
      expect(c.hasAccess, isFalse);
      expect(c.events, isEmpty);
      expect(c.preferences, isEmpty);
      expect(session.credentials.value!['token'], 'firebase:b@example.invalid');
      expect(session.server.requests, ['GET /auth/session']);
    });

    test('a Firebase sign-out drops the shown data and credentials', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      final identity = GatedIdentity(null);
      final c = session.controller(identity);
      addTearDown(c.dispose);
      await c.init();
      expect(c.hasAccess, isTrue);
      identity.release();
      await c.refresh();
      await pumpEventQueue();
      expect(c.user, isNull);
      expect(c.events, isEmpty);
      expect(session.credentials.value, isNull);
      expect(session.server.requests, isEmpty);
      // Logging in to the same account later continues with its own data.
      final again = session.controller(FakeIdentity());
      addTearDown(again.dispose);
      await again.init();
      await again.login(
        email: session.uid,
        password: 'Long password!2026',
        baseUrl: 'https://theater.example.invalid',
      );
      expect(again.hasAccess, isTrue);
    });

    test('a request made before Firebase answers waits for it', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      final identity = GatedIdentity(session.uid);
      final c = session.controller(identity);
      addTearDown(c.dispose);
      await c.init();
      final answer = c.respond(c.events.first.id, 'yes');
      await Future<void>.delayed(Duration.zero);
      expect(session.server.requests, isEmpty);
      identity.release();
      expect(await answer, ActionOutcome.synced);
      expect(session.server.count('POST', '/actions'), 1);
      expect(session.server.count('GET', '/auth/session'), 1);
    });

    test('a logout before Firebase answers stays logged out', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      final identity = GatedIdentity(session.uid);
      final c = session.controller(identity);
      addTearDown(c.dispose);
      await c.init();
      final logout = c.logout();
      await Future<void>.delayed(Duration.zero);
      expect(c.user, isNull);
      expect(identity.signOuts, 0);
      identity.release();
      await logout;
      await pumpEventQueue();
      expect(identity.signOuts, 1);
      expect(c.user, isNull);
      expect(c.events, isEmpty);
      expect(session.credentials.value, isNull);
      expect(session.server.count('GET', '/auth/session'), 0);
      expect(session.server.count('GET', '/snapshot'), 0);
    });

    test('a first login on the device starts like before', () async {
      final server = FirebaseServer();
      final session = Session(server);
      final identity = GatedIdentity(null);
      final c = session.controller(identity);
      addTearDown(c.dispose);
      var done = false;
      final start = c.init().then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(done, isFalse);
      identity.release();
      await start;
      expect(c.user, isNull);
      expect(c.needsBotCheck, isTrue);
      await c.login(
        email: session.uid,
        password: 'Long password!2026',
        baseUrl: 'https://theater.example.invalid',
      );
      expect(c.hasAccess, isTrue);
      expect(c.events, isNotEmpty);
      expect(server.count('GET', '/auth/session'), 1);
      expect(server.count('GET', '/snapshot'), 1);
    });

    test('a waiting account is not shown from the cache', () async {
      final session = Session(FirebaseServer()..status = 'pending');
      await session.signInOnce();
      final identity = GatedIdentity(session.uid);
      final c = session.controller(identity);
      addTearDown(c.dispose);
      var done = false;
      final start = c.init().then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(done, isFalse);
      identity.release();
      await start;
      expect(c.user!.status, 'pending');
    });

    test('offline keeps the stored data and reports it', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      session.server.override = (_) =>
          Future<http.Response>.error(http.ClientException('offline'));
      final identity = GatedIdentity(session.uid)..release();
      final c = session.controller(identity);
      addTearDown(c.dispose);
      await c.init();
      await c.refresh(silent: true);
      expect(c.hasAccess, isTrue);
      expect(c.events, isNotEmpty);
      expect(c.isOffline, isTrue);
      expect(c.error, isNotNull);
    });

    test('an expired Firebase session signs out', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      session.server.override = (request) => isPath(request, '/auth/session')
          ? Future.value(jsonResponse({'error': 'expired'}, 401))
          : null;
      final identity = GatedIdentity(session.uid)..release();
      final c = session.controller(identity);
      addTearDown(c.dispose);
      await c.init();
      await c.refresh(silent: true);
      await pumpEventQueue();
      expect(c.user, isNull);
      expect(c.events, isEmpty);
      expect(session.credentials.value, isNull);
    });
  });

  group('access check', () {
    test('a snapshot without access asks the session at once', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      final c = session.controller(GatedIdentity(session.uid)..release());
      addTearDown(c.dispose);
      await c.init();
      await c.refresh(silent: true);
      await c.setPreference('private-note', 'Privat');
      session.server.status = 'suspended';
      final epoch = c.sessionEpoch;
      await c.refresh(silent: true);
      expect(session.server.count('GET', '/auth/session'), 2);
      expect(c.sessionEpoch, greaterThan(epoch));
      expect(c.hasAccess, isFalse);
      expect(c.user!.status, 'suspended');
      expect(c.events, isEmpty);
      expect(c.preferences, isEmpty);
    });

    test(
      'a snapshot without access but approved session keeps the error',
      () async {
        final session = Session(FirebaseServer());
        await session.signInOnce();
        final c = session.controller(GatedIdentity(session.uid)..release());
        addTearDown(c.dispose);
        await c.init();
        await c.refresh(silent: true);
        session.server.override = (request) => isPath(request, '/snapshot')
            ? Future.value(
                jsonResponse({'error': 'Gesperrt', 'code': 'access'}, 403),
              )
            : null;
        await c.refresh(silent: true);
        expect(session.server.count('GET', '/auth/session'), 2);
        expect(c.hasAccess, isTrue);
        expect(c.error, 'Gesperrt');
        expect(c.isOffline, isFalse);
      },
    );
  });

  group('device registration', () {
    test('restoring push sends an unchanged token once a day', () async {
      final session = Session(FirebaseServer());
      await session.signInOnce();
      final c = session.controller(GatedIdentity(session.uid)..release());
      await c.init();
      await c.refresh(silent: true);
      int posts() => session.server.count('POST', '/devices');
      await Future.wait([
        c.registerDevice('token-1', 'web', ifStale: true),
        c.registerDevice('token-1', 'web', ifStale: true),
      ]);
      expect(posts(), 1);
      await c.registerDevice('token-1', 'web', ifStale: true);
      expect(posts(), 1);
      c.dispose();
      // Also after a restart.
      final next = session.controller(GatedIdentity(session.uid)..release());
      addTearDown(next.dispose);
      await next.init();
      await next.refresh(silent: true);
      var notified = 0;
      next.addListener(() => notified++);
      await next.registerDevice('token-1', 'web', ifStale: true);
      expect(posts(), 1);
      expect(notified, 0);
      // A new token, a day later or an explicit enable send it again.
      await next.registerDevice('token-2', 'web', ifStale: true);
      expect(posts(), 2);
      session.now = session.now.add(AppController.deviceRegistrationInterval);
      await next.registerDevice('token-2', 'web', ifStale: true);
      expect(posts(), 3);
      await next.registerDevice('token-2', 'web');
      expect(posts(), 4);
    });
  });

  group('app start', () {
    testWidgets('the shell shows before Firebase answers and keeps the tab', (
      tester,
    ) async {
      final session = Session(FirebaseServer());
      await tester.runAsync(session.signInOnce);
      final identity = GatedIdentity(session.uid);
      final c = session.controller(identity);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        TheaterApp(controller: c, enableDeviceServices: false),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(AppShell), findsOneWidget);
      expect(session.server.requests, isEmpty);
      final shell = tester.element(find.byType(AppShell));
      selectSection(shell, AppSection.schedule);
      await tester.pump();
      identity.release();
      await tester.runAsync(() => c.refresh(silent: true));
      await tester.pumpAndSettle();
      expect(session.server.count('GET', '/auth/session'), 1);
      expect(
        shell
            .getInheritedWidgetOfExactType<AppNavigationScope>()!
            .notifier!
            .value,
        AppSection.schedule.index,
      );
      expect(find.byType(AppShell), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('another Firebase account falls back to the welcome screen', (
      tester,
    ) async {
      final session = Session(FirebaseServer());
      await tester.runAsync(session.signInOnce);
      final identity = GatedIdentity(null);
      final c = session.controller(identity);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        TheaterApp(controller: c, enableDeviceServices: false),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(AppShell), findsOneWidget);
      identity.release();
      await tester.runAsync(() => c.refresh());
      await tester.pumpAndSettle();
      expect(find.byType(AppShell), findsNothing);
      expect(find.byType(FirebaseWelcomeScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
