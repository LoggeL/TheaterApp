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

import 'app_controller_test.dart'
    show TestServer, signIn, fixedNow, jsonResponse;
import 'firebase_access_test.dart' show FakeIdentity;

http.Response response(JsonMap data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);
JsonMap pendingUser(FakeIdentity identity) => {
  'userId': identity.uid,
  'displayName': 'Test Person',
  'email': identity.email,
  'status': 'pending',
  'role': 'member',
  'identityReady': identity.emailVerified,
  'emailVerified': identity.emailVerified,
  'needsRegistrationName': false,
};
AppController firebaseController(FakeIdentity identity, MockClient client) =>
    AppController(
      identity: identity,
      apiClient: ApiClient(client: client),
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
Future<void> login(AppController controller, String email) => controller.login(
  email: email,
  password: 'A synthetic test password',
  baseUrl: 'https://theater.example.invalid',
);

class GatedSignOutIdentity extends FakeIdentity {
  final requested = Completer<void>(), release = Completer<void>();
  @override
  Future<void> signOut() async {
    requested.complete();
    await release.future;
    await super.signOut();
  }
}

class VerificationIdentity extends FakeIdentity {
  VerificationIdentity() {
    emailVerified = false;
  }
  bool verifiedAtProvider = false;
  int reloads = 0;
  @override
  Future<void> reload() async {
    reloads++;
    emailVerified = verifiedAtProvider;
  }
}

void main() {
  for (final followUp in ['event.script', 'event.save', 'event.delete']) {
    test(
      'dependent offline $followUp stays blocked after a foreign version conflict, including retry after restart',
      () async {
        final server = TestServer();
        final store = MemoryLocalStore(), credentials = MemoryCredentialStore();
        var version = 1;
        var scenes = <String>['1'];
        var offline = false;
        final attempts = <JsonMap>[];
        void updateEvent() {
          server.data['events'] = [
            {
              'id': 'e',
              'title': 'Probe',
              'productionId': DemoData.mainProductionId,
              'sceneIds': scenes,
              'version': version,
            },
          ];
        }

        updateEvent();
        server.override = (request) {
          if (!request.url.path.endsWith('/actions/')) return null;
          final body = jsonMap(jsonDecode(request.body));
          if (offline) {
            return Future<http.Response>.error(http.ClientException('offline'));
          }
          attempts.add(body);
          if (body['version'] != version) {
            return Future.value(jsonResponse({'error': 'conflict'}, 409));
          }
          scenes = jsonList(body['sceneIds']).map((v) => v.toString()).toList();
          version++;
          updateEvent();
          return Future.value(jsonResponse({'ok': true}));
        };
        final controller = server.controller(
          store: store,
          credentials: credentials,
        );
        await signIn(controller);
        offline = true;
        await controller.linkEventScript('e', DemoData.mainProductionId, ['2']);
        if (followUp == 'event.script') {
          await controller.linkEventScript('e', DemoData.mainProductionId, [
            '3',
          ]);
        } else {
          await controller.performAction({
            'action': followUp,
            'id': 'e',
            'version': controller.events.single.version,
            if (followUp == 'event.save') 'sceneIds': ['3'],
          });
        }
        expect(controller.outbox.map((a) => a.payload['version']), [1, 2]);
        version = 2;
        scenes = ['foreign'];
        updateEvent();
        offline = false;
        await controller.refresh();
        expect(attempts.map((a) => a['version']), [1]);
        expect(controller.failedCount, 2);
        expect(scenes, ['foreign']);
        expect(version, 2);
        expect(controller.outbox.last.payload['action'], followUp);
        if (followUp != 'event.delete') {
          expect(controller.outbox.last.payload['sceneIds'], ['3']);
        }
        expect(controller.outbox.last.payload['version'], 1);
        controller.dispose();
        final restarted = server.controller(
          store: store,
          credentials: credentials,
        );
        addTearDown(restarted.dispose);
        await restarted.init();
        await restarted.retryFailed(restarted.outbox.last.id);
        expect(attempts.map((a) => a['version']), [1, 1]);
        expect(restarted.failedCount, 2);
        expect(scenes, ['foreign']);
        expect(version, 2);
        expect(restarted.outbox.last.payload['action'], followUp);
        if (followUp != 'event.delete') {
          expect(restarted.outbox.last.payload['sceneIds'], ['3']);
        }
      },
    );
  }

  test('late server logout does not sign out a new Firebase session', () async {
    final identity = FakeIdentity();
    final requested = Completer<void>();
    final release = Completer<http.Response>();
    final controller = firebaseController(
      identity,
      MockClient((request) async {
        if (request.url.path.endsWith('/auth/logout/')) {
          requested.complete();
          return release.future;
        }
        return response({'user': pendingUser(identity)});
      }),
    );
    addTearDown(controller.dispose);
    await controller.init();
    await login(controller, 'first@example.invalid');
    final logout = controller.logout();
    await requested.future;
    await login(controller, 'second@example.invalid');
    release.complete(response({'ok': true}));
    await logout;
    expect(identity.uid, 'second@example.invalid');
    expect(controller.user!.id, 'second@example.invalid');
    await controller.refresh();
    expect(controller.user!.id, identity.uid);
  });

  test('a new login waits for an already running identity sign-out', () async {
    final identity = GatedSignOutIdentity();
    final controller = firebaseController(
      identity,
      MockClient(
        (request) async => response(
          request.url.path.endsWith('/auth/logout/')
              ? {'ok': true}
              : {'user': pendingUser(identity)},
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.init();
    await login(controller, 'first@example.invalid');
    final logout = controller.logout();
    await identity.requested.future;
    final signIn = login(controller, 'second@example.invalid');
    await Future<void>.delayed(Duration.zero);
    expect(identity.uid, 'first@example.invalid');
    identity.release.complete();
    await logout;
    await signIn;
    expect(identity.uid, 'second@example.invalid');
    expect(controller.user!.id, identity.uid);
  });

  test(
    'identity verification refresh adopts a newly confirmed email',
    () async {
      final identity = VerificationIdentity();
      final controller = firebaseController(
        identity,
        MockClient(
          (request) async => response({'user': pendingUser(identity)}),
        ),
      );
      addTearDown(controller.dispose);
      await controller.init();
      await login(controller, 'pending@example.invalid');
      expect(controller.user!.identityReady, isFalse);
      identity.verifiedAtProvider = true;
      await controller.refreshIdentityAccess();
      expect(identity.reloads, 1);
      expect(controller.user!.identityReady, isTrue);
    },
  );

  test(
    'offline absences preserve past and locked responses and clear eligible ETA',
    () async {
      final server = TestServer();
      server.data['events'] = [
        {
          'id': 'past',
          'title': 'Past',
          'startsAt': '2026-09-11T17:00:00Z',
          'endsAt': '2026-09-11T19:00:00Z',
          'eventDate': '2026-09-11',
        },
        {
          'id': 'locked',
          'title': 'Locked',
          'startsAt': '2026-09-17T17:00:00Z',
          'endsAt': '2026-09-17T19:00:00Z',
          'eventDate': '2026-09-17',
          'locked': true,
        },
        {
          'id': 'future',
          'title': 'Future',
          'startsAt': '2026-09-17T17:00:00Z',
          'endsAt': '2026-09-17T19:00:00Z',
          'eventDate': '2026-09-17',
        },
        {
          'id': 'undated',
          'title': 'Undated',
          'startsAt': '2026-09-17T17:00:00Z',
          'eventDate': '2026-09-17',
        },
      ];
      server.data['attendanceByEvent'] = {
        'past': 'yes',
        'locked': 'yes',
        'future': 'late',
        'undated': 'yes',
      };
      server.data['expectedArrivals'] = {'future': '2026-09-17T18:00:00Z'};
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      server.offline = true;
      await controller.addAbsence(
        DateTime(2026, 9, 10),
        DateTime(2026, 9, 20),
        'Urlaub',
      );
      TheaterEvent event(String id) =>
          controller.events.firstWhere((e) => e.id == id);
      expect(event('past').response, 'yes');
      expect(event('locked').response, 'yes');
      expect(event('undated').response, 'yes');
      expect(event('future').response, 'no');
      expect(event('future').expectedArrivalAt, isNull);
      expect(controller.outbox.single.payload['action'], 'absence.create');
    },
  );

  test('past RSVP is rejected before creating an offline change', () async {
    final server = TestServer();
    server.data['events'] = [
      {
        'id': 'past',
        'title': 'Past',
        'startsAt': '2026-09-11T17:00:00Z',
        'endsAt': '2026-09-11T19:00:00Z',
      },
    ];
    server.data['attendanceByEvent'] = {'past': 'open'};
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    server.offline = true;
    await expectLater(
      controller.respond('past', 'yes'),
      throwsA(isA<ApiException>()),
    );
    expect(controller.events.single.response, 'open');
    expect(controller.outbox, isEmpty);
  });

  test(
    'response boundary matches server and unknown times remain answerable',
    () {
      final server = TestServer();
      final controller = server.controller();
      addTearDown(controller.dispose);
      expect(
        controller.canRespondTo(
          TheaterEvent(id: 'edge', title: 'Edge', endsAt: fixedNow),
        ),
        isTrue,
      );
      expect(
        controller.canRespondTo(
          TheaterEvent(
            id: 'ended',
            title: 'Ended',
            endsAt: fixedNow.subtract(const Duration(milliseconds: 1)),
          ),
        ),
        isFalse,
      );
      expect(
        controller.canRespondTo(
          const TheaterEvent(id: 'unknown', title: 'Unknown'),
        ),
        isTrue,
      );
      expect(
        controller.canRespondTo(
          const TheaterEvent(id: 'locked', title: 'Locked', locked: true),
        ),
        isFalse,
      );
    },
  );

  test(
    'sequential offline scene edits carry increasing expected versions',
    () async {
      final server = TestServer();
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      final event = controller.events.first;
      final production = event.productionId;
      server.offline = true;
      await controller.linkEventScript(event.id, production, ['1']);
      await controller.linkEventToScript(event.id, production, ['2']);
      expect(controller.outbox.map((a) => a.payload['version']), [
        event.version,
        event.version + 1,
      ]);
      expect(
        controller.events.firstWhere((e) => e.id == event.id).version,
        event.version + 2,
      );
      expect(controller.events.firstWhere((e) => e.id == event.id).sceneIds, [
        '2',
      ]);
    },
  );
}
