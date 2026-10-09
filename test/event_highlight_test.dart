import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/ui/calendar.dart';
import 'package:theater_app/ui/event_style.dart';
import 'package:theater_app/ui/events.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  TestServer server() {
    final now = DateTime.now();
    String at(Duration offset) => now.add(offset).toUtc().toIso8601String();
    final result = TestServer();
    result.data['events'] = [
      {
        'id': 'running',
        'title': 'Laufende Probe',
        'kind': 'rehearsal',
        'startsAt': at(const Duration(minutes: -30)),
        'endsAt': at(const Duration(minutes: 90)),
      },
      {
        'id': 'premiere',
        'title': 'Premiere',
        'kind': 'performance',
        'startsAt': at(const Duration(days: 2)),
        'endsAt': at(const Duration(days: 2, hours: 3)),
      },
      {
        'id': 'past',
        'title': 'Alte Probe',
        'kind': 'rehearsal',
        'startsAt': at(const Duration(days: -3)),
        'endsAt': at(const Duration(days: -3, hours: 2)),
      },
    ];
    result.data['attendanceByEvent'] = {'running': 'yes'};
    return result;
  }

  for (final brightness in Brightness.values) {
    testWidgets('agenda highlights running, prominent and open events '
        'in ${brightness.name} mode', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = server().controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(brightness),
          home: Scaffold(body: ScheduleScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      // The running event is also the earliest one still ahead.
      expect(find.text('LÄUFT GERADE'), findsOneWidget);
      expect(find.text('ALS NÄCHSTES'), findsNothing);
      expect(
        find.descendant(
          of: find.widgetWithText(EventCard, 'Premiere'),
          matching: find.byType(EventKindPill),
        ),
        findsOneWidget,
      );
      final badges = tester
          .widgetList<RsvpStatusBadge>(find.byType(RsvpStatusBadge))
          .toList();
      expect(badges.every((badge) => badge.emphasizeOpen), isTrue);
      expect(badges.map((badge) => badge.status), containsAll(['yes', 'open']));
      expect(
        find.descendant(
          of: find.byType(EventCard),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, 'Vergangen'));
      await tester.pumpAndSettle();
      final past = find.widgetWithText(EventCard, 'Alte Probe');
      expect(
        tester
            .widget<Opacity>(
              find.descendant(of: past, matching: find.byType(Opacity)),
            )
            .opacity,
        lessThan(1),
      );
      expect(
        tester
            .widget<RsvpStatusBadge>(find.byType(RsvpStatusBadge))
            .emphasizeOpen,
        isFalse,
      );

      await tester.tap(find.text('Kalender'));
      await tester.pumpAndSettle();
      expect(find.byType(RehearsalCalendar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('desktop agenda marks the next event once it is not running', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1360, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = server();
    backend.data['events'] = [
      for (final event in backend.data['events'] as List)
        if ((event as Map)['id'] != 'running') event,
    ];
    final controller = backend.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.dark),
        home: Scaffold(body: ScheduleScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('schedule-event-premiere'));
    expect(
      find.descendant(of: tile, matching: find.text('ALS NÄCHSTES')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.byType(RsvpStatusBadge)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(EventDetailContent),
        matching: find.byType(EventKindPill),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
