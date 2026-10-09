import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/ui/calendar.dart';
import 'package:theater_app/ui/events.dart';
import 'package:theater_app/ui/theme.dart';
import 'package:theater_app/ui/responsive.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  TestServer server() {
    final result = TestServer();
    result.data['events'] = [
      for (final id in ['first', 'second'])
        {
          'id': id,
          'title': 'Probe $id',
          'startsAt': '2027-01-12T17:00:00Z',
          'endsAt': '2027-01-12T19:00:00Z',
          'place': 'Probensaal',
        },
    ];
    return result;
  }

  testWidgets(
    'desktop selection remains inline and RSVP targets selected event',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = server();
      final controller = backend.controller();
      await signIn(controller);
      backend.offline = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(body: ScheduleScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('schedule-event-second')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-event-second')));
      await tester.pumpAndSettle();
      expect(find.byType(EventDetailScreen), findsNothing);
      expect(
        tester
            .widget<EventDetailContent>(find.byType(EventDetailContent))
            .event
            .id,
        'second',
      );
      await tester.ensureVisible(find.text('Bin dabei'));
      await tester.tap(find.text('Bin dabei'));
      await tester.pumpAndSettle();
      expect(controller.outbox.single.payload['eventId'], 'second');
      expect(
        controller.events.firstWhere((e) => e.id == 'second').response,
        'yes',
      );
      expect(
        tester
            .widget<EventDetailContent>(find.byType(EventDetailContent))
            .event
            .id,
        'second',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'constrained desktop details retain usable width and scroll independently',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = server().controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(
            body: ContentWidth(
              maxWidth: 1000,
              child: ScheduleScreen(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final detail = find.byType(EventDetailContent);
      final detailList = find.descendant(
        of: detail,
        matching: find.byType(ListView),
      );
      final agendaList = find.byKey(const PageStorageKey('schedule-agenda'));
      final panelRect = tester.getRect(detail);
      final rsvpRect = tester.getRect(find.byType(RsvpPanel));
      expect(rsvpRect.width, greaterThan(450));
      expect(tester.widget<RsvpPanel>(find.byType(RsvpPanel)).compact, isTrue);
      final choiceRects = [
        for (final label in ['Bin dabei', 'Komme später', 'Kann nicht'])
          tester.getRect(find.widgetWithText(OutlinedButton, label)),
      ];
      expect(
        choiceRects.map((rect) => rect.top).toSet(),
        hasLength(1),
        reason: "$choiceRects RSVP $rsvpRect",
      );
      for (final rect in choiceRects) {
        expect(rect.left, greaterThanOrEqualTo(rsvpRect.left));
        expect(rect.right, lessThanOrEqualTo(rsvpRect.right));
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      expect(rsvpRect.left, greaterThanOrEqualTo(panelRect.left + 24));
      expect(rsvpRect.right, lessThanOrEqualTo(panelRect.right - 24));
      final detailScroll = tester.state<ScrollableState>(
        find
            .descendant(of: detailList, matching: find.byType(Scrollable))
            .first,
      );
      final agendaScroll = tester.state<ScrollableState>(
        find
            .descendant(of: agendaList, matching: find.byType(Scrollable))
            .first,
      );
      expect(identical(detailScroll.position, agendaScroll.position), isFalse);
      await tester.binding.setSurfaceSize(const Size(1360, 600));
      await tester.pumpAndSettle();
      final agendaOffset = agendaScroll.position.pixels;
      await tester.drag(detailList, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(detailScroll.position.pixels, greaterThan(0));
      expect(agendaScroll.position.pixels, agendaOffset);
      await tester.ensureVisible(find.text('Bin dabei'));
      expect(tester.getSize(find.text('Bin dabei')).width, greaterThan(50));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'calendar empty day clears inline detail and narrow resize uses mobile agenda',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = server().controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(body: ScheduleScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .widget<RehearsalCalendar>(find.byType(RehearsalCalendar))
          .onSelected(DateTime(2027, 1, 13));
      await tester.pumpAndSettle();
      expect(find.text('Kein Termin ausgewählt'), findsOneWidget);
      expect(find.byType(RsvpPanel), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Kommend'));
      await tester.pumpAndSettle();
      expect(find.byType(EventDetailContent), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(600, 900));
      await tester.pumpAndSettle();
      expect(find.byType(EventDetailContent), findsNothing);
      expect(find.byType(EventCard), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
