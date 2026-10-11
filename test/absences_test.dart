import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/features/absences/absences.dart';

import 'app_controller_test.dart'
    show TestServer, signIn, fixedNow, jsonResponse;

/// An event at a local wall-clock time, so dates hold in any time zone.
JsonMap event(String id, DateTime start, {JsonMap extra = const {}}) => {
  'id': id,
  'title': id,
  'startsAt': start.toUtc().toIso8601String(),
  'endsAt': start.add(const Duration(hours: 2)).toUtc().toIso8601String(),
  ...extra,
};

void seedEvents(TestServer server) {
  server.data['events'] = [
    event('a', DateTime(2026, 9, 14, 19)),
    event('b', DateTime(2026, 9, 13, 19)),
    event('locked', DateTime(2026, 9, 14, 19), extra: {'locked': true}),
    event('slot', DateTime(2026, 9, 15, 10), extra: {'slotPoolId': 'pool'}),
    event(
      'light',
      DateTime(2026, 9, 15, 19),
      extra: {
        'roleIds': ['role-light'],
      },
    ),
    event('declined', DateTime(2026, 9, 15, 19)),
    // Inside the decline cutoff of one hour.
    event('soon', fixedNow.add(const Duration(minutes: 30))),
    event('later', DateTime(2026, 9, 20, 19)),
  ];
  server.data['attendanceByEvent'] = {'declined': 'no'};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Widget screen(Widget child) =>
      MaterialApp(theme: StageTheme.build(Brightness.light), home: child);

  test('affected events mirror the offline projection', () async {
    final server = TestServer();
    seedEvents(server);
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    final affected = affectedEventsForAbsence(
      controller,
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 15),
    );
    expect([for (final e in affected) e.id], ['b', 'a']);

    // Saving offline declines exactly these events.
    server.offline = true;
    await controller.addAbsence(
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 15),
      'Urlaub',
    );
    expect(
      [
        for (final e in controller.events)
          if (e.response == 'no' && e.id != 'declined') e.id,
      ]..sort(),
      ['a', 'b'],
    );
    expect(
      affectedEventsForAbsence(
        controller,
        DateTime(2026, 9, 12),
        DateTime(2026, 9, 15),
      ),
      isEmpty,
    );
  });

  test('a rejected absence throws and stays for review', () async {
    final server = TestServer();
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    server.actionStatus = 409;
    await expectLater(
      controller.addAbsence(fixedNow, fixedNow, 'Urlaub'),
      throwsA(isA<ApiException>()),
    );
    expect(controller.failedCount, 1);
  });

  testWidgets('absences are sorted and grouped, past ones collapsed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final server = TestServer();
    server.data['absences'] = [
      {
        'id': 'x2',
        'from': '2026-10-01',
        'to': '2026-10-05',
        'reason': 'Urlaub',
      },
      {
        'id': 'x1',
        'from': '2026-09-10',
        'to': '2026-09-21',
        'reason': 'Arbeit',
      },
      {'id': 'old', 'from': '2026-08-01', 'to': '2026-08-03', 'reason': 'Kur'},
    ];
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(screen(AbsencesScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('Aktuell & geplant'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Arbeit')).dy,
      lessThan(tester.getTopLeft(find.text('Urlaub')).dy),
    );
    expect(find.text('Vergangen (1)'), findsOneWidget);
    expect(find.text('Kur'), findsNothing);
    await tester.tap(find.text('Vergangen (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Kur'), findsOneWidget);

    final delete = find.descendant(
      of: find.ancestor(of: find.text('Arbeit'), matching: find.byType(Card)),
      matching: find.byTooltip('Abwesenheit löschen'),
    );
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Abwesenheit entfernen?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Entfernen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {'action': 'absence.delete', 'id': 'x1'});
    expect(find.text('Abwesenheit entfernt.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  Future<void> report(WidgetTester tester, AppController controller) async {
    await tester.pumpWidget(
      screen(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => AddAbsenceScreen(controller: controller),
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
    expect(
      find.text(
        'Termine in diesem Zeitraum werden beim Speichern automatisch abgesagt.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Zeitraum auswählen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '09/12/2026');
    await tester.enterText(fields.at(1), '09/15/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Damit sagst du 2 Termine ab'), findsOneWidget);
    expect(find.text('b · Sonntag, 13. September'), findsOneWidget);
  }

  Finder save() => find.widgetWithText(FilledButton, 'Abwesenheit melden');

  testWidgets('saving names the declined events', (tester) async {
    final server = TestServer();
    seedEvents(server);
    final controller = server.controller();
    await signIn(controller);
    await report(tester, controller);
    await tester.tap(save());
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'absence.create');
    expect(find.text('öffnen'), findsOneWidget);
    expect(
      find.text('Abwesenheit gespeichert · 2 Termine abgesagt'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('offline the absence is queued', (tester) async {
    final server = TestServer();
    seedEvents(server);
    final controller = server.controller();
    await signIn(controller);
    server.offline = true;
    await report(tester, controller);
    await tester.tap(save());
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Abwesenheit vorgemerkt · 2 Termine abgesagt – wird bei Verbindung gesendet',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a rejected absence keeps the form open', (tester) async {
    final server = TestServer();
    seedEvents(server);
    final controller = server.controller();
    await signIn(controller);
    await report(tester, controller);
    server.actionStatus = 409;
    await tester.tap(save());
    await tester.pumpAndSettle();
    expect(save(), findsOneWidget);
    expect(
      find.textContaining('Die Abwesenheit wurde nicht gespeichert'),
      findsOneWidget,
    );
    expect(find.textContaining('vorgemerkt'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the declined count comes from the server when it tells', (
    tester,
  ) async {
    final server = TestServer();
    seedEvents(server);
    server.override = (request) {
      if (!request.url.path.contains('/actions')) return null;
      return Future.value(
        jsonResponse({
          'ok': true,
          'id': 'abs-1',
          'declinedEventIds': ['b', 'a', 'later'],
        }),
      );
    };
    final controller = server.controller();
    await signIn(controller);
    await report(tester, controller);
    await tester.tap(save());
    await tester.pumpAndSettle();
    // The preview said 2; the server's Berlin dates decide.
    expect(
      find.text('Abwesenheit gespeichert · 3 Termine abgesagt'),
      findsOneWidget,
    );
    await tester.tap(find.text('Termine ansehen'));
    await tester.pumpAndSettle();
    expect(find.text('Abgesagte Termine'), findsOneWidget);
    expect(find.text('later'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('removing an absence offers to reopen events with the flag', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final server = TestServer();
    server.data['capabilities'] = {
      'features': ['absenceOutcome'],
    };
    server.data['absences'] = [
      {'id': 'x1', 'from': '2026-09-14', 'to': '2026-09-20', 'reason': 'Kur'},
    ];
    final bodies = <JsonMap>[];
    server.override = (request) {
      if (!request.url.path.contains('/actions')) return null;
      bodies.add(jsonMap(jsonDecode(request.body)));
      return Future.value(
        jsonResponse({
          'ok': true,
          'reopenedEventIds': ['a'],
        }),
      );
    };
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(screen(AbsencesScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Abwesenheit löschen'));
    await tester.pumpAndSettle();
    expect(find.text('Abgesagte Termine wieder öffnen'), findsOneWidget);
    expect(find.textContaining('Bereits gespeicherte Absagen'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Entfernen'));
    await tester.pumpAndSettle();
    expect(bodies.last, {
      'action': 'absence.delete',
      'id': 'x1',
      'reopen': true,
    });
    expect(
      find.text('Abwesenheit entfernt · 1 Termin wieder geöffnet.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('without the flag the reopen option stays hidden', (
    tester,
  ) async {
    final server = TestServer();
    server.data['absences'] = [
      {'id': 'x1', 'from': '2026-09-14', 'to': '2026-09-20', 'reason': 'Kur'},
    ];
    final controller = server.controller();
    await signIn(controller);
    // Even a direct wish is not sent to a server that does not know it.
    await controller.deleteAbsence('x1', reopen: true);
    expect(server.actionBodies.last, {'action': 'absence.delete', 'id': 'x1'});
    controller.dispose();
  });
}
