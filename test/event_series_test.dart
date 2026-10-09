import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/event_series.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/admin.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('planSeries', () {
    // Device-local wall times, so the result is the same in every time zone.
    final start = DateTime(2026, 9, 15, 19),
        end = DateTime(2026, 9, 15, 21, 30);

    test('weekly series keep the wall-clock time', () {
      final plan = planSeries(
        start,
        end,
        SeriesRhythm.week,
        DateTime(2026, 12, 1),
      );
      expect(plan.problem, isNull);
      expect(plan.starts, hasLength(12));
      expect(plan.starts.every((s) => s.hour == 19 && s.minute == 0), isTrue);
      expect(plan.starts.last, DateTime(2026, 12, 1, 19));
      expect(
        plan.summary,
        'Erstellt 12 Termine: dienstags 19:00–21:30, 15.9. bis 1.12.',
      );
    });

    test('fortnightly and monthly series', () {
      expect(
        planSeries(
          start,
          end,
          SeriesRhythm.twoWeeks,
          DateTime(2026, 10, 13),
        ).summary,
        'Erstellt 3 Termine: alle 2 Wochen dienstags 19:00–21:30, '
        '15.9. bis 13.10.',
      );
      final monthly = planSeries(
        DateTime(2026, 10, 31, 19),
        DateTime(2026, 10, 31, 21),
        SeriesRhythm.month,
        DateTime(2027, 2, 28),
      );
      expect(monthly.starts.map((d) => '${d.month}/${d.day}'), [
        '10/31',
        '11/30',
        '12/31',
        '1/31',
        '2/28',
      ]);
      expect(
        monthly.summary,
        'Erstellt 5 Termine: monatlich am 31., 19:00–21:00, '
        '31.10.2026 bis 28.2.2027',
      );
    });

    test('mirrors the server limits', () {
      String? problem(DateTime until) =>
          planSeries(start, end, SeriesRhythm.week, until).problem;
      expect(problem(DateTime(2026, 9, 14)), contains('vor dem ersten'));
      expect(problem(DateTime(2026, 9, 21)), contains('nur ein Termin'));
      expect(problem(DateTime(2027, 9, 14)), contains('höchstens 52'));
      expect(problem(DateTime(2027, 9, 16)), contains('höchstens ein Jahr'));
      expect(problem(DateTime(2027, 9, 13)), isNull);
      expect(seriesUntilValue(DateTime(2027, 2, 3)), '2027-02-03');
    });
  });

  Future<(TestServer, AppController)> pump(
    WidgetTester tester,
    Widget Function(AppController) screen, {
    void Function(TestServer)? prepare,
  }) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    server.data['capabilities'] = {'pushConfigured': true};
    prepare?.call(server);
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => screen(controller)),
                ),
                child: const Text('öffnen'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    return (server, controller);
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.dragUntilVisible(
      target,
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
  }

  String summary(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('event-repeat-summary')))
      .data!;

  testWidgets('a new event can repeat weekly until a picked day', (
    tester,
  ) async {
    final (server, controller) = await pump(
      tester,
      (c) =>
          EventEditorScreen(controller: c, initialDay: DateTime(2026, 9, 15)),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Probe');
    expect(find.byKey(const ValueKey('event-repeat-summary')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('event-repeat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wöchentlich').last);
    await tester.pumpAndSettle();
    // Eight weeks by default.
    expect(
      summary(tester),
      'Erstellt 9 Termine: dienstags 19:00–21:00, 15.9. bis 10.11.',
    );

    await tester.tap(find.byKey(const ValueKey('event-repeat-until')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('24'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(
      summary(tester),
      'Erstellt 11 Termine: dienstags 19:00–21:00, 15.9. bis 24.11.',
    );

    await tester.tap(find.byKey(const ValueKey('event-repeat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle 2 Wochen').last);
    await tester.pumpAndSettle();
    expect(
      summary(tester),
      'Erstellt 6 Termine: alle 2 Wochen dienstags 19:00–21:00, '
      '15.9. bis 24.11.',
    );

    // One push for the whole series stays switched on.
    await scrollTo(tester, find.byKey(const ValueKey('event-push')));
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('event-push')))
          .value,
      isTrue,
    );
    expect(
      find.text('Eine Benachrichtigung für die ganze Serie. Geht an: Alle'),
      findsOneWidget,
    );
    final save = find.text('Terminserie speichern');
    await scrollTo(tester, save);
    await tester.tap(save);
    await tester.pump();
    final body = server.actionBodies.lastWhere(
      (b) => b['action'] == 'event.save',
    );
    expect(body['repeat'], {'every': '2weeks', 'until': '2026-11-24'});
    expect(body['push'], isTrue);
    expect(body['id'], isNull);
    expect(
      body['startsAt'],
      DateTime(2026, 9, 15, 19).toUtc().toIso8601String(),
    );
    expect(body['endsAt'], DateTime(2026, 9, 15, 21).toUtc().toIso8601String());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a single event sends no repetition', (tester) async {
    final (server, controller) = await pump(
      tester,
      (c) => EventEditorScreen(controller: c),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Fotos');
    final save = find.text('Termin speichern');
    await scrollTo(tester, save);
    await tester.tap(save);
    await tester.pump();
    final body = server.actionBodies.lastWhere(
      (b) => b['action'] == 'event.save',
    );
    expect(body.containsKey('repeat'), isFalse);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('an invalid series cannot be saved', (tester) async {
    final (_, controller) = await pump(
      tester,
      (c) =>
          EventEditorScreen(controller: c, initialDay: DateTime(2026, 9, 15)),
    );
    await tester.tap(find.byKey(const ValueKey('event-repeat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monatlich').last);
    await tester.pumpAndSettle();
    // The default eight weeks hold two monthly dates.
    expect(summary(tester), startsWith('Erstellt 2 Termine: monatlich am 15.'));
    await tester.tap(find.byKey(const ValueKey('event-repeat-until')));
    await tester.pumpAndSettle();
    // Back to September, then pick the 20th.
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(summary(tester), contains('nur ein Termin'));
    final save = find.text('Terminserie speichern');
    await scrollTo(tester, save);
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(of: save, matching: find.byType(FilledButton)),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('series events are marked and can be deleted from here on', (
    tester,
  ) async {
    late String id;
    final (server, controller) = await pump(
      tester,
      (c) => EventEditorScreen(
        controller: c,
        event: c.events.firstWhere((e) => e.id == id),
      ),
      prepare: (server) {
        final event = (server.data['events'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((e) => e['slotPoolId'] == null);
        event['seriesId'] = 'series-1';
        id = event['id'] as String;
      },
    );
    expect(controller.events.firstWhere((e) => e.id == id).inSeries, isTrue);
    expect(find.byKey(const ValueKey('event-repeat')), findsNothing);
    final delete = find.text('Termin löschen');
    await scrollTo(tester, delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Serientermin löschen?'), findsOneWidget);
    expect(find.text('Nur diesen Termin'), findsOneWidget);
    await tester.tap(find.text('Diesen und alle folgenden'));
    await tester.pumpAndSettle();
    final body = server.actionBodies.lastWhere(
      (b) => b['action'] == 'event.delete',
    );
    expect(body['id'], id);
    expect(body['series'], 'following');
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: EventsAdminScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    final marked = controller.events.where((e) => e.inSeries).length;
    expect(find.byTooltip('Serientermin'), findsNWidgets(marked));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('the series id survives the event model', () {
    final event = TheaterEvent.fromJson({
      'id': 'a',
      'title': 'Probe',
      'seriesId': 's',
    });
    expect(event.copyWith(response: 'yes').seriesId, 's');
    expect(TheaterEvent.fromJson(event.toJson()).seriesId, 's');
    expect(TheaterEvent.fromJson({'id': 'b', 'title': 'X'}).inSeries, isFalse);
  });
}
