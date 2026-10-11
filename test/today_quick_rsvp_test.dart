import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/features/events/ui/rsvp/rsvp_actions.dart';
import 'package:theater_app/features/today/today.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  for (final answered in [false, true]) {
    testWidgets(
      answered
          ? 'answered events collapse to a compact row on the start page'
          : 'open events can be answered on the start page',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final start = fixedNow.add(const Duration(days: 2));
        final server = TestServer();
        server.data['events'] = [
          {
            'id': 'next',
            'title': 'Szenenprobe',
            'startsAt': start.toUtc().toIso8601String(),
            'endsAt': start
                .add(const Duration(hours: 2))
                .toUtc()
                .toIso8601String(),
            'place': 'Kolpingheim',
          },
        ];
        server.data['attendanceByEvent'] = answered ? {'next': 'yes'} : {};
        final controller = server.controller();
        await signIn(controller);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: Scaffold(
              // The app shell rebuilds the start page on controller changes.
              body: ListenableBuilder(
                listenable: controller,
                builder: (_, _) => TodayScreen(
                  controller: controller,
                  onPlan: () {},
                  onScripts: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final compact = find.byKey(const ValueKey('today-next-compact'));
        if (answered) {
          expect(find.text('Bist du dabei?'), findsNothing);
          expect(compact, findsOneWidget);
          expect(find.text('Du bist dabei'), findsOneWidget);
        } else {
          expect(compact, findsNothing);
          expect(find.text('Bist du dabei?'), findsOneWidget);
          await tester.tap(find.text('Kann nicht'));
          await tester.pumpAndSettle();
          expect(find.text('Dieses Mal ohne dich.'), findsOneWidget);
          await tester.tapAt(const Offset(20, 20));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Bin dabei'));
          await tester.pumpAndSettle();
          final body = server.actionBodies.last;
          expect(
            [body['action'], body['eventId'], body['status']],
            ['attendance', 'next', 'yes'],
          );
          expect(find.text('Bist du dabei?'), findsNothing);
          expect(compact, findsOneWidget);
          expect(find.text('Du bist dabei'), findsOneWidget);
          expect(find.text('Zusage gespeichert'), findsOneWidget);
          // Undo takes the answer back and brings the questions back.
          await tester.tap(find.text('Rückgängig'));
          await tester.pumpAndSettle();
          expect(server.actionBodies.last['status'], 'open');
          expect(find.text('Rückmeldung zurückgenommen'), findsOneWidget);
          expect(find.text('Bist du dabei?'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }

  testWidgets('late without an end time is saved with the time open', (
    tester,
  ) async {
    final server = _serverWith(
      start: fixedNow.add(const Duration(days: 2)),
      end: null,
    );
    final controller = server.controller();
    await signIn(controller);
    await _pumpToday(tester, controller);
    await tester.tap(find.text('Komme später'));
    await tester.pumpAndSettle();
    // No time picker: there is no window to pick a time in.
    expect(find.byType(TimePickerDialog), findsNothing);
    final body = server.actionBodies.last;
    expect(
      [body['action'], body['status'], body['expectedArrivalAt']],
      ['attendance', 'late', null],
    );
    expect(controller.events.single.response, 'late');
    expect(find.text('Später gespeichert'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('an arrival outside the event is not sent', (tester) async {
    final start = fixedNow.add(const Duration(days: 2));
    final server = _serverWith(
      start: start,
      end: start.add(const Duration(hours: 2)),
    );
    final controller = server.controller();
    await signIn(controller);
    final sent = server.actionBodies.length;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: StageTheme.ink,
          body: QuickRsvp(
            event: controller.events.single,
            controller: controller,
            pickArrival: (_, event) async => LateArrival(
              event.startsAt!.subtract(const Duration(minutes: 30)),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Komme später'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.length, sent);
    expect(controller.events.single.response, 'open');
    final event = controller.events.single;
    final hm = DateFormat.Hm('de');
    expect(
      find.text(
        'Die Ankunft muss zwischen ${hm.format(event.startsAt!)} und '
        '${hm.format(event.endsAt!)} Uhr liegen.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('shortly before the start declining points to the direction', (
    tester,
  ) async {
    final start = fixedNow.add(const Duration(minutes: 30));
    final server = _serverWith(
      start: start,
      end: start.add(const Duration(hours: 2)),
    );
    final controller = server.controller();
    await signIn(controller);
    await _pumpToday(tester, controller);
    expect(
      find.text(
        'Absage nicht mehr möglich – bitte melde dich direkt bei der '
        'Probenleitung.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Kann nicht'));
    await tester.pumpAndSettle();
    expect(find.text('Dieses Mal ohne dich.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}

TestServer _serverWith({required DateTime start, required DateTime? end}) =>
    TestServer()
      ..data['events'] = [
        {
          'id': 'next',
          'title': 'Szenenprobe',
          'startsAt': start.toUtc().toIso8601String(),
          'endsAt': end?.toUtc().toIso8601String(),
          'place': 'Kolpingheim',
        },
      ]
      ..data['attendanceByEvent'] = {};

Future<void> _pumpToday(WidgetTester tester, AppController controller) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (_, _) => TodayScreen(
            controller: controller,
            onPlan: () {},
            onScripts: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
