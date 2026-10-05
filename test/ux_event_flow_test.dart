import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/ui/events.dart';
import 'package:theater_app/ui/rehearsal_admin.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn, jsonResponse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Future<void> smallScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget screen(Widget child, {double textScale = 1}) => MaterialApp(
    theme: StageTheme.build(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: child,
  );

  JsonMap rehearsal({int version = 1, List<String> scenes = const ['1']}) => {
    'id': 'rehearsal',
    'title': 'Szenenprobe',
    'startsAt': '2026-09-13T17:00:00Z',
    'endsAt': '2026-09-13T19:00:00Z',
    'productionId': DemoData.mainProductionId,
    'sceneIds': scenes,
    'version': version,
  };

  testWidgets('past RSVP is read-only and never queues a response', (
    tester,
  ) async {
    final server = TestServer();
    server.data['events'] = [
      {
        'id': 'past',
        'title': 'Vergangene Probe',
        'startsAt': '2026-09-11T17:00:00Z',
        'endsAt': '2026-09-11T19:00:00Z',
      },
    ];
    server.data['attendanceByEvent'] = {'past': 'yes'};
    final controller = server.controller();
    await signIn(controller);
    server.offline = true;
    await tester.pumpWidget(
      screen(
        Scaffold(
          body: RsvpPanel(
            controller: controller,
            event: controller.events.single,
          ),
        ),
      ),
    );
    expect(find.text('Bin dabei'), findsNothing);
    expect(find.text('Rückmeldung zurücknehmen'), findsNothing);
    expect(
      find.text('Der Termin ist vorbei. Rückmeldungen sind geschlossen.'),
      findsOneWidget,
    );
    expect(
      tester.widget<RsvpStatusBadge>(find.byType(RsvpStatusBadge)).status,
      'yes',
    );
    expect(controller.outbox, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('all schedule filters and view choices fit at large text', (
    tester,
  ) async {
    await smallScreen(tester);
    final server = TestServer();
    server.data['events'] = [];
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      screen(
        Scaffold(body: ScheduleScreen(controller: controller)),
        textScale: 2,
      ),
    );
    for (final label in ['Kommend', 'Offen', 'Zugesagt', 'Vergangen']) {
      final rect = tester.getRect(find.widgetWithText(ChoiceChip, label));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.bottom, lessThanOrEqualTo(1000));
    }
    expect(find.text('Kommend · 0 Termine'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Kalender'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('scene conflict keeps draft until explicit reconciliation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final server = TestServer();
    server.data['events'] = [rehearsal()];
    final controller = server.controller();
    await signIn(controller);
    await controller.loadScript(DemoData.mainProductionId);
    await tester.pumpWidget(
      screen(
        ScenePlannerScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final second = find.widgetWithText(
      CheckboxListTile,
      'Szene 2 · Hinter dem Vorhang',
    );
    await tester.ensureVisible(second);
    await tester.tap(second);
    await tester.pumpAndSettle();
    server.data['events'] = [
      rehearsal(version: 2, scenes: ['3']),
    ];
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(second).value, isTrue);
    server.actionStatus = 409;
    final save = find.widgetWithText(FilledButton, 'Für diese Probe speichern');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.actionBodies.single['version'], 1);
    expect(server.actionBodies.single['sceneIds'], ['1', '2']);
    expect(find.text('Szenenauswahl prüfen'), findsOneWidget);
    expect(find.text('Aktuell gespeichert: Szenen 3.'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(second).value, isTrue);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    final reconcile = find.text('Entwurf behalten und Stand prüfen');
    final failedId = controller.outbox.single.id;
    for (final response in [
      jsonResponse({'error': 'Snapshot nicht verfügbar'}, 400),
      http.Response('{kaputtes json', 200),
    ]) {
      server.override = (request) =>
          request.url.path.replaceFirst(RegExp(r'/$'), '').endsWith('/snapshot')
          ? Future.value(response)
          : null;
      await tester.ensureVisible(reconcile);
      await tester.tap(reconcile);
      await tester.pumpAndSettle();
      expect(controller.isOffline, isFalse);
      expect(controller.error, isNotNull);
      expect(find.text('Szenenauswahl prüfen'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(second).value, isTrue);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(controller.outbox.single.id, failedId);
      expect(controller.failedCount, 1);
      expect(
        find.text(
          'Aktueller Stand geladen. Prüfe deinen Entwurf und speichere erneut.',
        ),
        findsNothing,
      );
    }
    server.override = null;
    await tester.ensureVisible(reconcile);
    await tester.tap(reconcile);
    await tester.pumpAndSettle();
    expect(find.text('Szenenauswahl prüfen'), findsNothing);
    expect(tester.widget<CheckboxListTile>(second).value, isTrue);
    expect(controller.failedCount, 0);

    server.actionStatus = 200;
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['version'], 2);
    expect(server.actionBodies.last['sceneIds'], ['1', '2']);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('save and view scenes uses the newly captured presence offline', (
    tester,
  ) async {
    final server = TestServer();
    server.data['events'] = [rehearsal()];
    server.data['members'] = jsonList(server.data['members']).take(2).toList();
    final productions = jsonList(server.data['productions']);
    productions[0] = {
      ...jsonMap(productions[0]),
      'casting': {'LENA': 1, 'OSKAR': 2},
    };
    server.data['productions'] = productions;
    server.data['checkinsByEvent'] = {
      'rehearsal': {'2': true},
    };
    final controller = server.controller();
    await signIn(controller);
    await controller.loadScript(DemoData.mainProductionId);
    server.offline = true;
    await tester.pumpWidget(
      screen(
        AttendanceEditorScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Da').last);
    await tester.pumpAndSettle();
    final combinedSave = find.text('Speichern und Szenen ansehen');
    await tester.ensureVisible(combinedSave);
    await tester.tap(combinedSave);
    await tester.pumpAndSettle();
    expect(find.byType(ScenePlannerScreen), findsOneWidget);
    expect(jsonMap(controller.checkinsByEvent['rehearsal'])['1'], isTrue);
    expect(controller.pendingCount, 1);
    expect(find.widgetWithText(StatePill, 'Spielbar'), findsOneWidget);
    expect(server.actionBodies.single['action'], 'checkin.save');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
