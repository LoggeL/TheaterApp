import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/features/absences/absences.dart';
import 'package:theater_app/features/events/events.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

final _start = DateTime(2027, 1, 12, 19), _end = DateTime(2027, 1, 12, 21);
String _hm(DateTime t) => DateFormat.Hm('de').format(t);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  test('every response reads the same everywhere', () {
    expect(statusText('yes'), 'Zugesagt');
    expect(statusText('late'), 'Später');
    expect(statusText('no'), 'Abgesagt');
    expect(statusText('open'), 'Offen');
    expect(statusText('unbekannt'), 'Offen');
  });

  group('pickLateArrival', () {
    /// Runs the picker from a button and records what it resolved to.
    Future<List<LateArrival?>> pump(
      WidgetTester tester,
      TheaterEvent event, {
      DateTime? initial,
    }) async {
      final results = <LateArrival?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => results.add(
                  await pickLateArrival(context, event, initial: initial),
                ),
                child: const Text('Uhrzeit'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Uhrzeit'));
      await tester.pumpAndSettle();
      return results;
    }

    final event = TheaterEvent(
      id: 'a',
      title: 'Probe',
      startsAt: _start,
      endsAt: _end,
    );

    testWidgets('offers to leave the time open', (tester) async {
      final results = await pump(tester, event);
      expect(find.text('Voraussichtlich da ab'), findsOneWidget);
      await tester.tap(find.text('Ohne Uhrzeit'));
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
      expect(results.single, isNotNull);
      expect(results.single!.arrival, isNull);
    });

    testWidgets('cancelling resolves to nothing', (tester) async {
      final results = await pump(tester, event);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(results, [null]);
    });

    testWidgets('only accepts a time between start and end', (tester) async {
      final early = _start.subtract(const Duration(minutes: 30));
      final results = await pump(tester, event, initial: early);
      expect(find.text('${_hm(early)} Uhr'), findsOneWidget);
      expect(
        find.text(
          'Bitte eine Uhrzeit nach ${_hm(_start)} und vor ${_hm(_end)} '
          'Uhr wählen.',
        ),
        findsOneWidget,
      );
      FilledButton accept() =>
          tester.widget(find.widgetWithText(FilledButton, 'Übernehmen'));
      expect(accept().onPressed, isNull);
      final later = _start.add(const Duration(minutes: 30));
      await tester.tap(find.widgetWithText(ChoiceChip, _hm(later)));
      await tester.pump();
      expect(find.textContaining('Bitte eine Uhrzeit'), findsNothing);
      expect(accept().onPressed, isNotNull);
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      expect(results.single!.arrival, later);
    });

    testWidgets('without an end there is nothing to ask', (tester) async {
      final results = await pump(
        tester,
        TheaterEvent(id: 'b', title: 'Probe', startsAt: _start),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(results.single!.arrival, isNull);
    });
  });

  Future<(TestServer, AppController)> panel(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final server = TestServer();
    server.data['events'] = [
      {
        'id': 'a',
        'title': 'Probe',
        'startsAt': fixedNow
            .add(const Duration(days: 3))
            .toUtc()
            .toIso8601String(),
        'endsAt': fixedNow
            .add(const Duration(days: 3, hours: 2))
            .toUtc()
            .toIso8601String(),
      },
    ];
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => ListView(
              children: [
                RsvpPanel(
                  controller: controller,
                  event: controller.events.single,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return (server, controller);
  }

  testWidgets('a late arrival can drop its time again before saving', (
    tester,
  ) async {
    final (server, controller) = await panel(tester);
    final start = controller.events.single.startsAt!;
    await tester.tap(find.text('Komme später'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uhrzeit optional'));
    await tester.pumpAndSettle();
    final later = start.add(const Duration(minutes: 30));
    await tester.tap(find.widgetWithText(ChoiceChip, _hm(later)));
    await tester.pump();
    await tester.tap(find.text('Übernehmen'));
    await tester.pumpAndSettle();
    expect(find.text('${_hm(later)} Uhr'), findsOneWidget);
    await tester.tap(find.text('${_hm(later)} Uhr'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ohne Uhrzeit'));
    await tester.pumpAndSettle();
    expect(find.text('Uhrzeit optional'), findsOneWidget);
    await tester.tap(find.text('Späterkommen speichern'));
    await tester.pumpAndSettle();
    expect(find.text('Später · Uhrzeit offen'), findsOneWidget);
    final body = server.actionBodies.last;
    expect(body['status'], 'late');
    expect(body['expectedArrivalAt'], isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the decline sheet leads to a longer absence instead', (
    tester,
  ) async {
    final (server, controller) = await panel(tester);
    await tester.tap(find.text('Kann nicht'));
    await tester.pumpAndSettle();
    expect(find.text('Dieses Mal ohne dich.'), findsOneWidget);
    await tester.tap(find.text('Länger weg? Abwesenheit melden'));
    await tester.pumpAndSettle();
    expect(find.byType(AddAbsenceScreen), findsOneWidget);
    // Nothing was declined on the way.
    expect(
      server.actionBodies.where((b) => b['action'] == 'attendance'),
      isEmpty,
    );
    expect(controller.events.single.response, 'open');
    // Let the sheet's text field dispose after its closing animation.
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
