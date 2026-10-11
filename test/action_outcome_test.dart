import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/shared/feedback.dart';

import 'app_controller_test.dart'
    show TestServer, signIn, fixedNow, jsonResponse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a change confirmed by the server is synced', () async {
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);

    expect(
      await controller.respond('demo-rehearsal', 'yes'),
      ActionOutcome.synced,
    );
    expect(
      (await controller.addAbsence(fixedNow, fixedNow, 'Urlaub')).outcome,
      ActionOutcome.synced,
    );
    expect(controller.pendingCount, 0);
  });

  test('a change made offline is queued', () async {
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    server.offline = true;

    expect(
      await controller.respond('demo-rehearsal', 'yes'),
      ActionOutcome.queued,
    );
    expect(
      (await controller.addAbsence(fixedNow, fixedNow, 'Urlaub')).outcome,
      ActionOutcome.queued,
    );
    expect(controller.pendingCount, 2);
  });

  test('a rejected change still throws instead of returning', () async {
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    server.actionStatus = 409;

    await expectLater(
      controller.respond('demo-rehearsal', 'yes'),
      throwsA(isA<ApiException>()),
    );
  });

  test('the server reply comes with a synced change only', () async {
    final server = TestServer();
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    server.override = (request) =>
        request.url.path.contains('/actions') && !server.offline
        ? Future.value(jsonResponse({'ok': true, 'id': 'm1', 'recipients': 23}))
        : null;

    final synced = await controller.performActionWithResult({
      'action': 'message.send',
      'title': 'Hallo',
    });
    expect(synced.outcome, ActionOutcome.synced);
    expect(synced.data?['recipients'], 23);

    server.offline = true;
    final queued = await controller.performActionWithResult({
      'action': 'message.send',
      'title': 'Später',
    });
    expect(queued.outcome, ActionOutcome.queued);
    expect(queued.data, isNull);
  });

  test('a rejection keeps the server status and code', () async {
    final server = TestServer();
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    server.override = (request) => request.url.path.contains('/actions')
        ? Future.value(
            jsonResponse({
              'error': 'Nur für Admins.',
              'code': 'forbidden',
            }, 403),
          )
        : null;

    await expectLater(
      controller.performAction({'action': 'push.test'}),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.code, 'code', 'forbidden')
            .having((e) => e.message, 'message', 'Nur für Admins.'),
      ),
    );
    final failed = controller.outbox.single;
    expect(failed.lastStatus, 403);
    expect(failed.lastErrorCode, 'forbidden');
    expect(failed.retryable, isFalse);
  });

  test('feature flags come from the snapshot capabilities', () async {
    final server = TestServer();
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    expect(controller.supports('pollPush'), isFalse);

    server.data['capabilities'] = {
      'features': ['pollPush', 'nudges'],
    };
    await controller.refresh();
    expect(controller.supports('pollPush'), isTrue);
    expect(controller.supports('seriesEdit'), isFalse);
  });

  test('outbox entries load with and without the error details', () {
    final old = PendingAction.fromJson({
      'id': 'a',
      'payload': {'action': 'attendance'},
      'createdAt': '2026-09-12T10:00:00.000',
      'status': 'failed',
      'lastError': 'Termin gesperrt',
    });
    expect(old.lastStatus, isNull);
    expect(old.lastErrorCode, isNull);
    expect(old.retryable, isTrue);
    expect(old.toJson().containsKey('lastErrorCode'), isFalse);

    final current = PendingAction.fromJson(
      old.withStatus('failed', 'Frist vorbei', 409, 'closed').toJson(),
    );
    expect(current.lastStatus, 409);
    expect(current.lastErrorCode, 'closed');
    expect(current.retryable, isFalse);
  });

  test('demo changes are synced', () async {
    final controller = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
      clock: () => fixedNow,
    );
    await controller.startDemo();

    expect(
      await controller.respond('demo-rehearsal', 'yes'),
      ActionOutcome.synced,
    );
  });

  test('outcomeText picks the matching text', () {
    expect(
      outcomeText(ActionOutcome.synced, done: 'gespeichert', queued: 'wartet'),
      'gespeichert',
    );
    expect(
      outcomeText(ActionOutcome.queued, done: 'gespeichert', queued: 'wartet'),
      'wartet',
    );
  });
}
