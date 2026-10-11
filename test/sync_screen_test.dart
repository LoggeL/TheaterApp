import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/sync/sync.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

void main() {
  test('the remaining count after a sync reads naturally', () {
    expect(remainingChanges(0, 0), isNull);
    expect(remainingChanges(1, 0), '1 Änderung wartet noch');
    expect(
      remainingChanges(2, 1),
      '2 Änderungen warten noch · 1 Änderung braucht deine Prüfung',
    );
    expect(remainingChanges(0, 3), '3 Änderungen brauchen deine Prüfung');
  });

  testWidgets('discarding asks first and syncing confirms the result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    server.offline = true;
    await controller.respond('demo-rehearsal', 'yes');
    await controller.respond('demo-rehearsal', 'late');
    expect(controller.pendingCount, 2);
    await tester.pumpWidget(
      MaterialApp(home: SyncScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Technische Details'), findsOneWidget);
    expect(find.text(controller.apiBaseUrl), findsNothing);
    expect(find.text('Offline'), findsWidgets);

    await tester.tap(find.byTooltip('Änderung bearbeiten').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Änderung verwerfen'));
    await tester.pumpAndSettle();
    expect(find.text('Änderung verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(controller.pendingCount, 2);

    await tester.tap(find.byTooltip('Änderung bearbeiten').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Änderung verwerfen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Verwerfen'));
    await tester.pumpAndSettle();
    expect(controller.pendingCount, 1);
    expect(find.text('Änderung verworfen.'), findsOneWidget);

    server.offline = false;
    await tester.tap(find.text('Jetzt synchronisieren'));
    await tester.pumpAndSettle();
    expect(controller.pendingCount, 0);
    expect(find.text('Alles übertragen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the demo shows a neutral state without a sync button', (
    tester,
  ) async {
    final controller = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
      clock: () => fixedNow,
    );
    await controller.startDemo();
    await tester.pumpWidget(
      MaterialApp(home: SyncScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lokale Demo'), findsOneWidget);
    expect(find.text('Jetzt synchronisieren'), findsNothing);
    expect(find.text('Technische Details'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
