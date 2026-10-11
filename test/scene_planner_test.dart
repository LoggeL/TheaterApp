import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/features/rehearsal/rehearsal.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  JsonMap rehearsal({
    String? productionId = DemoData.mainProductionId,
    List<String> scenes = const [],
  }) => {
    'id': 'rehearsal',
    'title': 'Szenenprobe',
    'startsAt': '2026-09-13T17:00:00Z',
    'endsAt': '2026-09-13T19:00:00Z',
    'productionId': productionId,
    'sceneIds': scenes,
    'version': 1,
  };

  Future<AppController> open(WidgetTester tester, TestServer server) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ScenePlannerScreen(
                    controller: controller,
                    event: controller.events.single,
                  ),
                ),
              ),
              child: const Text('öffnen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> finish(WidgetTester tester, AppController controller) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  bool usesCheckins(WidgetTester tester) => tester
      .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
      .selected
      .single;
  Finder save() =>
      find.widgetWithText(FilledButton, 'Für diese Probe speichern');

  testWidgets('plans by responses until attendance was recorded', (
    tester,
  ) async {
    final server = TestServer()..data['events'] = [rehearsal()];
    var controller = await open(tester, server);
    expect(usesCheckins(tester), isFalse);
    expect(find.text('Nach Rückmeldungen'), findsOneWidget);
    await finish(tester, controller);

    server.data['checkinsByEvent'] = {
      'rehearsal': {'1': true},
    };
    controller = await open(tester, server);
    expect(usesCheckins(tester), isTrue);
    expect(find.text('Nach Anwesenheit'), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('an event without production asks for one', (tester) async {
    final productions = [
      for (final p in jsonList(TestServer().data['productions']))
        {
          ...jsonMap(p),
          'archived': jsonMap(p)['id'] == DemoData.secondProductionId,
        },
    ];
    final server = TestServer()
      ..data['events'] = [rehearsal(productionId: null)]
      ..data['productions'] = productions;
    var controller = await open(tester, server);
    List<String?> choices() => [
      for (final item
          in tester
              .widget<DropdownButton<String>>(
                find.byType(DropdownButton<String>),
              )
              .items!)
        item.value,
    ];
    expect(find.text('Keine Produktion gewählt'), findsOneWidget);
    expect(choices(), [DemoData.mainProductionId]);
    expect(tester.widget<FilledButton>(save()).onPressed, isNull);
    await finish(tester, controller);

    // An archived production stays selectable for its own rehearsal.
    server.data['events'] = [
      rehearsal(productionId: DemoData.secondProductionId),
    ];
    controller = await open(tester, server);
    expect(choices(), [DemoData.mainProductionId, DemoData.secondProductionId]);
    await finish(tester, controller);
  });

  testWidgets('filters playable scenes and saves the selection', (
    tester,
  ) async {
    final server = TestServer()
      ..data['events'] = [
        rehearsal(scenes: ['3', '1']),
      ];
    server.data['members'] = jsonList(server.data['members']).take(2).toList();
    final productions = jsonList(server.data['productions']);
    productions[0] = {
      ...jsonMap(productions[0]),
      'casting': {'LENA': 1, 'OSKAR': 2},
    };
    server.data['productions'] = productions;
    server.data['checkinsByEvent'] = {
      'rehearsal': {'1': true, '2': true},
    };
    final controller = await open(tester, server);
    final all = find.byType(CheckboxListTile).evaluate().length;
    expect(find.text('Nur spielbare (1)'), findsOneWidget);
    await tester.tap(find.text('Nur spielbare (1)'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(find.text('Nur spielbare (1)'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile).evaluate().length, all);

    // The reader opens at the first chosen scene in script order.
    expect(find.text('Drehbuch ab Szene 1 öffnen'), findsOneWidget);
    expect(find.text('2 Szenen ausgewählt'), findsOneWidget);

    await tester.tap(save());
    await tester.pumpAndSettle();
    expect(server.actionBodies.single, {
      'action': 'event.script',
      'eventId': 'rehearsal',
      'version': 1,
      'productionId': DemoData.mainProductionId,
      'sceneIds': ['3', '1'],
    });
    expect(find.text('öffnen'), findsOneWidget);
    expect(find.text('Szenenauswahl gespeichert.'), findsOneWidget);
    await finish(tester, controller);
  });
}
