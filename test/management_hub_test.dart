import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/features/accounts/accounts.dart';
import 'package:theater_app/features/admin/admin.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

JsonMap _event(
  String id,
  String title,
  Duration fromNow, {
  String kind = 'meeting',
  String? productionId,
  String? slotPoolId,
  bool withEnd = true,
}) {
  final start = fixedNow.add(fromNow);
  return {
    'id': id,
    'title': title,
    'type': kind,
    'startsAt': start.toUtc().toIso8601String(),
    if (withEnd)
      'endsAt': start.add(const Duration(hours: 2)).toUtc().toIso8601String(),
    'productionId': ?productionId,
    'slotPoolId': ?slotPoolId,
  };
}

Future<void> _pumpHub(WidgetTester tester, TestServer server) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: ManagementScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('the hub shows the next event in time order and plans scenes '
      'for the next rehearsal', (tester) async {
    final server = TestServer();
    // Listed out of order: the snapshot order must not decide.
    server.data['events'] = [
      _event(
        'rehearsal',
        'Szenenprobe',
        const Duration(days: 3),
        kind: 'rehearsal',
        productionId: DemoData.mainProductionId,
      ),
      _event('meeting', 'Ensembletreffen', const Duration(days: 1)),
      // Booked slots and events without an end count as well.
      _event(
        'slot',
        'Fototermin',
        const Duration(hours: 2),
        slotPoolId: 'pool',
      ),
      _event(
        'open-end',
        'Aufbau ohne Ende',
        const Duration(hours: 5),
        kind: 'setup',
        withEnd: false,
      ),
    ];
    await _pumpHub(tester, server);
    expect(find.text('NÄCHSTER TERMIN'), findsOneWidget);
    expect(find.text('Aufbau ohne Ende'), findsOneWidget);
    expect(find.text('Fototermin'), findsNothing);
    expect(find.text('Szenen planen'), findsOneWidget);
    expect(find.textContaining('Für Szenenprobe'), findsOneWidget);
    // Duplicates of member entries keep the member label.
    expect(find.text('Galerien'), findsOneWidget);
    expect(find.text('Galerien verwalten'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final waiting in [0, 1]) {
    testWidgets('the access tile with $waiting waiting registrations', (
      tester,
    ) async {
      final server = TestServer();
      server.data['pendingAccounts'] = [
        if (waiting > 0)
          {'uid': 'new', 'status': 'pending', 'identityReady': true},
        // Unconfirmed registrations cannot be approved and do not count.
        {'uid': 'unverified', 'status': 'pending', 'identityReady': false},
      ];
      await _pumpHub(tester, server);
      // One tile for people and their access.
      expect(find.text('Personen & Zugänge'), findsOneWidget);
      for (final gone in [
        'Zugänge & Rechte',
        'Ensemble verwalten',
        'Konten & Verknüpfungen',
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      for (final kept in [
        'Rollen verwalten',
        'Ensembles & Verteiler',
        'Teilnahme im Ensemble',
      ]) {
        expect(find.text(kept), findsOneWidget, reason: kept);
      }
      final subtitle = waiting == 0
          ? 'Personen, Zugänge und Rechte'
          : '1 neue Registrierung wartet auf Zuordnung';
      expect(find.text(subtitle), findsOneWidget);
      await tester.tap(find.text('Personen & Zugänge'));
      await tester.pumpAndSettle();
      final screen = tester.widget<AccountsAdminScreen>(
        find.byType(AccountsAdminScreen),
      );
      // Waiting registrations stand on top of the list, so it opens whole.
      expect(screen.initialStatus, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('scene planning is hidden without an upcoming rehearsal', (
    tester,
  ) async {
    final server = TestServer();
    server.data['events'] = [
      _event('meeting', 'Ensembletreffen', const Duration(days: 1)),
      // A rehearsal without a production has no scenes to plan.
      _event(
        'loose',
        'Freie Probe',
        const Duration(days: 2),
        kind: 'rehearsal',
      ),
    ];
    await _pumpHub(tester, server);
    expect(find.text('Ensembletreffen'), findsOneWidget);
    expect(find.text('Szenen planen'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('the scene planning target skips meetings and unlinked rehearsals', () {
    final events = [
      TheaterEvent.fromJson(
        _event('a', 'Treffen', const Duration(hours: 1), productionId: 'p'),
      ),
      TheaterEvent.fromJson(
        _event('b', 'Probe', const Duration(hours: 2), kind: 'rehearsal'),
      ),
      TheaterEvent.fromJson(
        _event(
          'c',
          'Generalprobe',
          const Duration(hours: 3),
          kind: 'dress',
          productionId: 'p',
        ),
      ),
    ];
    expect(nextScenePlanningEvent(events)?.id, 'c');
    expect(nextScenePlanningEvent(events.take(2)), isNull);
  });
}
