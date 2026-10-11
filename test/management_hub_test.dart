import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
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
