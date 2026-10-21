import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/features/events/events.dart';

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

  testWidgets('a new series where everyone counts as attending says so', (
    tester,
  ) async {
    final (server, controller) = await pump(
      tester,
      (c) =>
          EventEditorScreen(controller: c, initialDay: DateTime(2026, 9, 15)),
      prepare: (server) => server.data['capabilities'] = {
        'pushConfigured': true,
        'features': ['autoAccept'],
      },
    );
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Probe');
    await tester.tap(find.byKey(const ValueKey('event-repeat')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wöchentlich').last);
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('event-auto-accept'));
    await scrollTo(tester, toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Gilt für alle Termine der Serie.'),
      findsOneWidget,
    );
    final save = find.text('Terminserie speichern');
    await scrollTo(tester, save);
    await tester.tap(save);
    await tester.pump();
    final body = server.actionBodies.lastWhere(
      (b) => b['action'] == 'event.save',
    );
    expect(body['repeat'], isNotNull);
    expect(body['autoAccept'], isTrue);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('the series id survives the event model', () {
    final event = TheaterEvent.fromJson({
      'id': 'a',
      'title': 'Probe',
      'seriesId': 's',
      'seriesRepeat': {'every': '2weeks', 'until': '2026-12-01'},
    });
    expect(event.copyWith(response: 'yes').seriesId, 's');
    expect(TheaterEvent.fromJson(event.toJson()).seriesId, 's');
    expect(TheaterEvent.fromJson(event.toJson()).seriesEvery, '2weeks');
    expect(TheaterEvent.fromJson({'id': 'b', 'title': 'X'}).inSeries, isFalse);
    expect(
      TheaterEvent.fromJson({'id': 'b', 'title': 'X'}).seriesEvery,
      isNull,
    );
  });

  group('planSeriesEnd', () {
    // Tuesdays 1 to 29 September; 1 and 8 September have begun.
    final starts = [
      for (final d in [1, 8, 15, 22, 29]) DateTime(2026, 9, d, 19),
    ];
    final now = DateTime(2026, 9, 12, 12);
    SeriesEndChange plan(
      DateTime until, {
      SeriesRhythm? rhythm = SeriesRhythm.week,
      DateTime? anchor,
    }) => planSeriesEnd(
      starts: starts,
      anchor: anchor ?? starts[2],
      rhythm: rhythm,
      until: until,
      now: now,
    );

    test('a later end adds dates in the rhythm, an earlier one removes', () {
      final later = plan(DateTime(2026, 10, 14));
      expect(later.added, [DateTime(2026, 10, 6), DateTime(2026, 10, 13)]);
      expect(later.summary, 'Fügt 2 Termine hinzu: 6.10. bis 13.10.');
      expect(
        plan(DateTime(2026, 10, 14), rhythm: SeriesRhythm.twoWeeks).summary,
        'Fügt 1 Termin hinzu: 13.10.',
      );
      final earlier = plan(DateTime(2026, 9, 20));
      expect(earlier.removed, starts.sublist(3));
      expect(earlier.summary, 'Entfernt 2 Termine nach dem 20.9.');
      expect(plan(DateTime(2026, 9, 29)).summary, isEmpty);
    });

    test('mirrors the server limits', () {
      expect(plan(DateTime(2026, 9, 14)).problem, contains('vor diesem'));
      expect(
        plan(DateTime(2026, 9, 1), anchor: starts.first).problem,
        contains('Begonnene Termine'),
      );
      expect(plan(DateTime(2026, 10, 5)).problem, contains('kein Termin'));
      expect(plan(DateTime(2027, 9, 30)).problem, contains('ein Jahr'));
      expect(plan(DateTime(2027, 9, 29)).added, hasLength(52));
      expect(
        plan(DateTime(2026, 10, 14), rhythm: null).problem,
        contains('Rhythmus'),
      );
    });

    test('monthly series return to their day of the month', () {
      final monthly = [DateTime(2027, 1, 31, 19), DateTime(2027, 2, 28, 19)];
      final plan = planSeriesEnd(
        starts: monthly,
        anchor: monthly.first,
        rhythm: SeriesRhythm.month,
        until: DateTime(2027, 4, 30),
        now: now,
      );
      expect(plan.added, [DateTime(2027, 3, 31), DateTime(2027, 4, 30)]);
      expect(
        seriesRhythmLabel(SeriesRhythm.month, monthly),
        'Monatlich am 31.',
      );
      expect(seriesRhythmLabel(SeriesRhythm.week, starts), 'Jeden Dienstag');
      expect(
        seriesRhythmLabel(SeriesRhythm.twoWeeks, starts),
        'Alle 2 Wochen dienstags',
      );
    });
  });

  group('whole series', () {
    // Tuesdays 19:00–21:30; 1 and 8 September have begun (now: 12 September).
    void weekly(TestServer server, {bool rhythm = true}) {
      server.data['capabilities'] = {
        'pushConfigured': true,
        'features': ['seriesEdit', 'seriesManage'],
      };
      server.data['events'] = [
        for (final d in [1, 8, 15, 22, 29])
          {
            'id': 'probe-$d',
            'title': 'Probe',
            'startsAt': DateTime(2026, 9, d, 19).toUtc().toIso8601String(),
            'endsAt': DateTime(2026, 9, d, 21, 30).toUtc().toIso8601String(),
            'place': 'Saal',
            'seriesId': 'serie',
            if (rhythm) 'seriesRepeat': {'every': 'week'},
            'version': 1,
          },
      ];
    }

    Future<(TestServer, AppController)> openSeries(
      WidgetTester tester, {
      bool rhythm = true,
    }) => pump(
      tester,
      (c) => EventEditorScreen(
        controller: c,
        event: c.events.firstWhere((e) => e.id == 'probe-15'),
      ),
      prepare: (server) => weekly(server, rhythm: rhythm),
    );

    Future<void> pickSeriesEnd(
      WidgetTester tester,
      String day, {
      bool nextMonth = false,
    }) async {
      await tester.tap(find.byKey(const ValueKey('event-series-until')));
      await tester.pumpAndSettle();
      if (nextMonth) {
        await tester.tap(find.byTooltip('Next month'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(day));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    String endSummary(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('event-series-end-summary')))
        .data!;

    testWidgets('edits all upcoming dates and explains the choice', (
      tester,
    ) async {
      final (server, controller) = await openSeries(tester);
      final hint = find.byKey(const ValueKey('event-series-scope-hint'));
      expect(
        tester.widget<Text>(hint).data,
        'Teil einer Serie – Änderungen gelten nur für diesen Termin.',
      );
      expect(find.byKey(const ValueKey('event-series-rhythm')), findsNothing);
      await tester.tap(find.text('Ganze Serie'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(hint).data,
        startsWith(
          'Gilt für alle 3 kommenden Termine der Serie, vergangene bleiben '
          'unverändert. Übernommen wird nur, was du hier änderst',
        ),
      );
      expect(find.text('Serie bearbeiten'), findsOneWidget);
      expect(find.text('Jeden Dienstag'), findsOneWidget);
      // The end shows the last date; unchanged, it is not sent.
      expect(find.text('Dienstag, 29. September 2026'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('event-series-end-summary')),
        findsNothing,
      );
      expect(find.text('19:00 Uhr · Datum je Termin'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Ort'), 'Aula');
      final save = find.text('Serie speichern');
      await scrollTo(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final body = server.actionBodies.lastWhere(
        (b) => b['action'] == 'event.save',
      );
      expect(
        [body['id'], body['series'], body['place']],
        ['probe-15', 'all', 'Aula'],
      );
      expect(body.containsKey('until'), isFalse);
      expect(
        body['startsAt'],
        DateTime(2026, 9, 15, 19).toUtc().toIso8601String(),
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('a later end extends the series with one push', (tester) async {
      final (server, controller) = await openSeries(tester);
      await tester.tap(find.text('Ganze Serie'));
      await tester.pumpAndSettle();
      await pickSeriesEnd(tester, '13', nextMonth: true);
      expect(endSummary(tester), 'Fügt 2 Termine hinzu: 6.10. bis 13.10.');
      await scrollTo(tester, find.byKey(const ValueKey('event-push')));
      expect(find.text('Eingeladene per Push benachrichtigen'), findsOneWidget);
      expect(
        find.textContaining('Eine Benachrichtigung für die neuen Termine.'),
        findsOneWidget,
      );
      final save = find.text('Serie speichern');
      await scrollTo(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final body = server.actionBodies.lastWhere(
        (b) => b['action'] == 'event.save',
      );
      expect(
        [body['series'], body['until'], body['push']],
        ['all', '2026-10-13', isTrue],
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('an earlier end asks before dates are removed', (tester) async {
      final (server, controller) = await openSeries(tester);
      await tester.tap(find.text('Ganze Serie'));
      await tester.pumpAndSettle();
      await pickSeriesEnd(tester, '15');
      expect(endSummary(tester), 'Entfernt 2 Termine nach dem 15.9.');
      final save = find.text('Serie speichern');
      await scrollTo(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Serie verkürzen?'), findsOneWidget);
      expect(
        find.textContaining(
          'Die 2 Termine nach dem 15. September werden mit ihren '
          'Rückmeldungen gelöscht.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(
        server.actionBodies.where((b) => b['action'] == 'event.save'),
        isEmpty,
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 Termine löschen'));
      await tester.pumpAndSettle();
      final body = server.actionBodies.lastWhere(
        (b) => b['action'] == 'event.save',
      );
      expect([body['series'], body['until']], ['all', '2026-09-15']);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('without a known rhythm the end stays as it is', (
      tester,
    ) async {
      final (server, controller) = await openSeries(tester, rhythm: false);
      await tester.tap(find.text('Ganze Serie'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Unregelmäßig – das Serienende lässt sich hier nicht ändern.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('event-series-until')), findsNothing);
      // Back to this date alone, nothing of the series is sent.
      await tester.tap(find.text('Nur dieser Termin'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('event-series-rhythm')), findsNothing);
      final save = find.text('Termin speichern');
      await scrollTo(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final body = server.actionBodies.lastWhere(
        (b) => b['action'] == 'event.save',
      );
      expect(body.containsKey('series'), isFalse);
      expect(body.containsKey('until'), isFalse);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });
}
