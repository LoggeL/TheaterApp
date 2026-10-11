import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/shared/feedback.dart';

import 'app_controller_test.dart' show TestServer, signIn, fixedNow;

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
      await controller.addAbsence(fixedNow, fixedNow, 'Urlaub'),
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
      await controller.addAbsence(fixedNow, fixedNow, 'Urlaub'),
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
