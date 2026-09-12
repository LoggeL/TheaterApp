import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/data/local_store.dart';

final fixedNow = DateTime(2026, 9, 12, 12);

http.Response jsonResponse(JsonMap value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

class TestServer {
  TestServer() {
    data = DemoData(now: fixedNow).snapshot();
    data['user'] = user;
  }
  late JsonMap data;
  bool offline = false, passwordRequired = false, failDeviceDeletion = false;
  int actionStatus = 200, logoutCalls = 0;
  String userId = 'member-a', token = 'test-token';
  final List<String> actionKeys = [];
  final List<JsonMap> actionBodies = [];
  Future<http.Response>? Function(http.Request)? override;
  JsonMap get user => {
    'userId': userId,
    'displayName': 'Testmitglied',
    'email': 'test@example.invalid',
    'role': 'admin',
    'mustChangePassword': passwordRequired,
  };

  Future<http.Response> handle(http.Request request) async {
    final special = override?.call(request);
    if (special != null) return special;
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (path.endsWith('/auth/login')) {
      return jsonResponse({
        'token': token,
        'expiresAt': '2027-01-01T00:00:00Z',
        'user': user,
      });
    }
    if (path.endsWith('/auth/logout')) {
      logoutCalls++;
      return jsonResponse({'ok': true});
    }
    if (path.endsWith('/auth/password')) {
      token = 'rotated-test-token';
      passwordRequired = false;
      return jsonResponse({
        'token': token,
        'expiresAt': '2027-01-01T00:00:00Z',
        'user': user,
      });
    }
    if (path.endsWith('/devices')) {
      if (request.method == 'DELETE' && failDeviceDeletion) {
        return jsonResponse({'error': 'device unavailable'}, 503);
      }
      return jsonResponse({'ok': true, 'pushEnabled': true});
    }
    if (path.endsWith('/snapshot')) {
      if (offline) throw http.ClientException('test offline');
      if (passwordRequired) {
        return jsonResponse({'error': 'Passwort ändern'}, 403);
      }
      data['user'] = user;
      return jsonResponse(data);
    }
    if (path.endsWith('/actions')) {
      actionKeys.add(request.headers['Idempotency-Key']!);
      final body = jsonMap(jsonDecode(request.body));
      actionBodies.add(body);
      if (offline) throw http.ClientException('test offline');
      if (actionStatus != 200) {
        return jsonResponse({
          'error': 'Termin inzwischen gesperrt',
        }, actionStatus);
      }
      if (body['action'] == 'attendance') {
        (data['attendanceByEvent'] as Map)[body['eventId']] = body['status'];
      }
      return jsonResponse({'ok': true, 'id': 'server-created-absence'});
    }
    if (path.endsWith('/script')) {
      if (offline) throw http.ClientException('test offline');
      return jsonResponse(
        DemoData(now: fixedNow).script(DemoData.mainProductionId).toJson(),
      );
    }
    return jsonResponse({'error': 'not found'}, 404);
  }

  AppController controller({
    MemoryLocalStore? store,
    MemoryCredentialStore? credentials,
  }) => AppController(
    apiClient: ApiClient(client: MockClient(handle)),
    localStore: store ?? MemoryLocalStore(),
    credentialStore: credentials ?? MemoryCredentialStore(),
    clock: () => fixedNow,
  );
}

Future<void> signIn(
  AppController controller, {
  String origin = 'https://theater.example.invalid',
}) async {
  await controller.init();
  await controller.login(
    email: 'test@example.invalid',
    password: 'secret-long-password',
    baseUrl: origin,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'offline change survives restart and keeps one idempotency key until acknowledged',
    () async {
      final server = TestServer(),
          store = MemoryLocalStore(),
          credentials = MemoryCredentialStore();
      final first = server.controller(store: store, credentials: credentials);
      await signIn(first);
      server.offline = true;
      await first.respond('demo-rehearsal', 'yes');
      expect(first.pendingCount, 1);
      expect(first.events.first.response, 'yes');
      expect(first.isOffline, isTrue);
      final key = first.outbox.single.id;
      expect(
        jsonEncode(credentials.value),
        isNot(contains('secret-long-password')),
      );
      first.dispose();

      final second = server.controller(store: store, credentials: credentials);
      await second.init();
      expect(second.pendingCount, 1);
      expect(second.events.first.response, 'yes');
      expect(second.outbox.single.id, key);
      server.offline = false;
      await second.refresh();
      expect(second.pendingCount, 0);
      expect(second.events.first.response, 'yes');
      expect(server.actionKeys.toSet(), {key});
      second.dispose();
    },
  );

  test(
    'permanent conflict rolls back optimism and explicit retry uses a fresh key',
    () async {
      final server = TestServer();
      final subject = server.controller();
      await signIn(subject);
      server.actionStatus = 409;
      await expectLater(
        subject.respond('demo-rehearsal', 'yes'),
        throwsA(isA<ApiException>()),
      );
      expect(subject.failedCount, 1);
      expect(subject.pendingCount, 0);
      expect(subject.events.first.response, 'open');
      expect(subject.outbox.single.lastError, 'Termin inzwischen gesperrt');
      final oldId = subject.outbox.single.id;
      server.actionStatus = 200;
      await subject.retryFailed(oldId);
      expect(subject.failedCount, 0);
      expect(subject.events.first.response, 'yes');
      expect(server.actionKeys.last, isNot(oldId));
      subject.dispose();
    },
  );

  test('late login response cannot restore credentials after logout', () async {
    final gate = Completer<http.Response>(), requested = Completer<void>();
    final server = TestServer(), credentials = MemoryCredentialStore();
    server.override = (request) {
      if (request.url.path
          .replaceFirst(RegExp(r'/$'), '')
          .endsWith('/auth/login')) {
        requested.complete();
        return gate.future;
      }
      return null;
    };
    final controller = server.controller(credentials: credentials);
    await controller.init();
    final login = controller.login(
      email: 'test@example.invalid',
      password: 'secret-long-password',
      baseUrl: 'https://theater.example.invalid',
    );
    await requested.future;
    await controller.logout();
    gate.complete(jsonResponse({'token': 'late-token', 'user': server.user}));
    await login;
    expect(controller.user, isNull);
    expect(credentials.value, isNull);
    expect(controller.events, isEmpty);
    controller.dispose();
  });

  test(
    'logout fences an in-flight mutation and removes account cache',
    () async {
      final gate = Completer<http.Response>(), requested = Completer<void>();
      final server = TestServer(),
          store = MemoryLocalStore(),
          credentials = MemoryCredentialStore();
      final controller = server.controller(
        store: store,
        credentials: credentials,
      );
      await signIn(controller);
      server.override = (request) {
        if (request.url.path
            .replaceFirst(RegExp(r'/$'), '')
            .endsWith('/actions')) {
          requested.complete();
          return gate.future;
        }
        return null;
      };
      final change = controller.respond('demo-rehearsal', 'yes');
      await requested.future;
      await controller.logout();
      gate.complete(jsonResponse({'ok': true}));
      await change;
      expect(controller.user, isNull);
      expect(controller.pendingCount, 0);
      expect(credentials.value, isNull);
      server.override = null;
      server.offline = true;
      await controller.login(
        email: 'test@example.invalid',
        password: 'secret-long-password',
        baseUrl: 'https://theater.example.invalid',
      );
      expect(controller.events, isEmpty);
      controller.dispose();
    },
  );

  test(
    'cache and preferences are isolated by server origin and account',
    () async {
      final server = TestServer();
      final subject = server.controller();
      await signIn(subject);
      await subject.setPreference('reader.role', 'PRIVATE-A');
      server.offline = true;
      await subject.login(
        email: 'test@example.invalid',
        password: 'secret-long-password',
        baseUrl: 'https://other.example.invalid',
      );
      expect(subject.preferences, isEmpty);
      expect(subject.events, isEmpty);
      expect(subject.isDemo, isFalse);
      server.userId = 'member-b';
      await subject.login(
        email: 'other@example.invalid',
        password: 'secret-long-password',
        baseUrl: 'https://theater.example.invalid',
      );
      expect(subject.preferences, isEmpty);
      expect(subject.events, isEmpty);
      subject.dispose();
    },
  );

  test(
    'fresh mandatory-password flag wins over a stale cached user profile',
    () async {
      final server = TestServer();
      final controller = server.controller();
      await signIn(controller);
      expect(controller.user!.mustChangePassword, isFalse);
      server.passwordRequired = true;
      await controller.login(
        email: 'test@example.invalid',
        password: 'temporary-password',
        baseUrl: 'https://theater.example.invalid',
      );
      expect(controller.user!.mustChangePassword, isTrue);
      await expectLater(
        controller.respond('demo-rehearsal', 'yes'),
        throwsA(isA<ApiException>()),
      );
      controller.dispose();
    },
  );

  test(
    'older snapshot cannot erase an action committed while it was in flight',
    () async {
      final server = TestServer();
      final subject = server.controller();
      await signIn(subject);
      final oldSnapshot = cloneJson(server.data),
          gate = Completer<http.Response>(),
          requested = Completer<void>();
      var heldOnce = false;
      server.override = (request) {
        if (request.url.path
                .replaceFirst(RegExp(r'/$'), '')
                .endsWith('/snapshot') &&
            !heldOnce) {
          heldOnce = true;
          requested.complete();
          return gate.future;
        }
        return null;
      };
      final refresh = subject.refresh();
      await requested.future;
      final change = subject.respond('demo-rehearsal', 'yes');
      while (server.actionKeys.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      // Let the acknowledged action update the baseline before releasing the old snapshot.
      while (subject.pendingCount != 0) {
        await Future<void>.delayed(Duration.zero);
      }
      gate.complete(jsonResponse(oldSnapshot));
      await Future.wait([refresh, change]);
      expect(subject.events.first.response, 'yes');
      subject.dispose();
    },
  );

  test(
    'password rotation fences unauthorized responses using the previous token',
    () async {
      final server = TestServer();
      final subject = server.controller();
      await signIn(subject);
      final gate = Completer<http.Response>(), requested = Completer<void>();
      server.override = (request) {
        if (request.url.path
                .replaceFirst(RegExp(r'/$'), '')
                .endsWith('/snapshot') &&
            request.headers['Authorization'] == 'Bearer test-token') {
          requested.complete();
          return gate.future;
        }
        return null;
      };
      final epoch = subject.sessionEpoch;
      final oldRefresh = subject.refresh();
      await requested.future;
      await subject.changePassword('secret-long-password', 'new-long-password');
      gate.complete(jsonResponse({'error': 'old token expired'}, 401));
      await oldRefresh;
      expect(subject.user, isNotNull);
      expect(subject.sessionEpoch, greaterThan(epoch));
      expect(subject.error, isNull);
      subject.dispose();
    },
  );

  test('check-in excludes inactive members from the server payload', () async {
    final server = TestServer();
    jsonList(
      server.data['members'],
    ).add({'id': 99, 'name': 'Inactive', 'active': false});
    final controller = server.controller();
    await signIn(controller);
    await controller.checkIn('demo-rehearsal', [1, 99]);
    expect(
      jsonList(
        server.actionBodies.last['members'],
      ).map((e) => jsonMap(e)['id']),
      isNot(contains(99)),
    );
    controller.dispose();
  });

  test(
    'absence overlay uses authoritative German date near UTC midnight',
    () async {
      final server = TestServer();
      server.data['events'] = [
        {
          'id': 'midnight',
          'title': 'Night rehearsal',
          'startsAt': '2026-09-11T23:30:00Z',
          'eventDate': '2026-09-12',
        },
      ];
      final controller = server.controller();
      await signIn(controller);
      server.offline = true;
      await controller.addAbsence(
        DateTime(2026, 9, 12),
        DateTime(2026, 9, 12),
        'Away',
      );
      expect(controller.events.single.response, 'no');
      await controller.deleteAbsence(controller.absences.single.id);
      expect(controller.events.single.response, 'open');
      expect(controller.pendingCount, 0);
      controller.dispose();
    },
  );

  test(
    'script-service outage preserves previously loaded production metadata',
    () async {
      final server = TestServer();
      final subject = server.controller();
      await signIn(subject);
      await subject.loadScript(DemoData.mainProductionId);
      server.data['productions'] = [];
      server.data['scriptService'] = {'available': false};
      await subject.refresh();
      expect(subject.productions, isNotEmpty);
      expect(subject.scripts[DemoData.mainProductionId]?.cues, isNotEmpty);
      server.data['scriptService'] = {'available': true};
      await subject.refresh();
      expect(subject.productions, isEmpty);
      subject.dispose();
    },
  );

  test('device deletion failure never prevents session logout', () async {
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    await controller.registerDevice('fake-token', 'android');
    server.failDeviceDeletion = true;
    await controller.logout();
    expect(server.logoutCalls, 1);
    controller.dispose();
  });

  test(
    'unconfirmed successful HTTP response keeps its durable action pending',
    () async {
      final server = TestServer();
      final controller = server.controller();
      await signIn(controller);
      server.override = (request) => request.url.path.endsWith('/actions/')
          ? Future.value(jsonResponse({'unexpected': true}))
          : null;
      await controller.respond('demo-rehearsal', 'yes');
      expect(controller.pendingCount, 1);
      expect(
        controller.outbox.single.lastError,
        contains('nicht eindeutig bestätigt'),
      );
      controller.dispose();
    },
  );

  test(
    'native rehearsal-script assignment is reversible and persisted in demo',
    () async {
      final controller = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
        clock: () => fixedNow,
      );
      await controller.init();
      await controller.startDemo();
      await controller.linkEventScript(
        'demo-rehearsal',
        DemoData.secondProductionId,
        ['1'],
      );
      expect(controller.events.first.productionId, DemoData.secondProductionId);
      expect(controller.events.first.sceneIds, ['1']);
      await controller.linkEventScript('demo-rehearsal', null, []);
      expect(controller.events.first.productionId, isNull);
      expect(controller.events.first.sceneIds, isEmpty);
      controller.dispose();
    },
  );

  test(
    'demo is explicit, mutable and contains only fictional fixtures',
    () async {
      final controller = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
        clock: () => fixedNow,
      );
      await controller.init();
      expect(controller.isDemo, isFalse);
      expect(controller.user, isNull);
      await controller.startDemo();
      expect(controller.isDemo, isTrue);
      expect(controller.events.first.startsAt, DateTime(2026, 9, 13, 19));
      await controller.respond('demo-rehearsal', 'no', reason: 'Test');
      expect(controller.events.first.declineReason, 'Test');
      expect(controller.polls, isEmpty);
      await controller.respond(
        'demo-rehearsal',
        'late',
        expectedArrivalAt: DateTime(2026, 9, 13, 19, 30),
      );
      expect(controller.events.first.response, 'late');
      expect(
        controller.events.first.expectedArrivalAt,
        DateTime(2026, 9, 13, 19, 30),
      );
      await controller.addAbsence(
        DateTime(2026, 9, 15),
        DateTime(2026, 9, 16),
        'Demo',
      );
      expect(controller.absences, hasLength(1));
      expect(controller.pendingCount, 0);
      controller.dispose();
    },
  );

  test('API rejects credential-bearing or insecure origins', () {
    expect(
      () => ApiClient.normalizeBaseUrl('https://name:secret@example.invalid'),
      throwsA(isA<ApiException>()),
    );
    expect(
      () => ApiClient.normalizeBaseUrl('http://example.invalid'),
      throwsA(isA<ApiException>()),
    );
    expect(
      () => ApiClient.normalizeBaseUrl('https://example.invalid/api'),
      throwsA(isA<ApiException>()),
    );
    expect(
      ApiClient.normalizeBaseUrl('https://example.invalid/'),
      'https://example.invalid',
    );
  });
}
