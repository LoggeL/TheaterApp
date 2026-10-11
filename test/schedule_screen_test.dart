import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/absences/absences.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/slots/slots.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;
import 'slots_test.dart' show SlotServer, pool;

class _MemberServer extends TestServer {
  @override
  JsonMap get user => {...super.user, 'role': 'member'};
}

String _at(Duration offset) => fixedNow.add(offset).toUtc().toIso8601String();

JsonMap _event(String id, Duration start) => {
  'id': id,
  'title': 'Probe $id',
  'startsAt': _at(start),
  'endsAt': _at(start + const Duration(hours: 2)),
  'place': 'Probensaal',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Future<AppController> pump(
    WidgetTester tester,
    TestServer server, {
    Size size = const Size(390, 900),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(body: ScheduleScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> finish(WidgetTester tester, AppController controller) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  /// Chips and agenda entries may sit outside the viewport first.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  double y(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  testWidgets('admins create events from the plan, on the chosen day', (
    tester,
  ) async {
    final controller = await pump(tester, TestServer());
    expect(find.text('Termine.'), findsOneWidget);
    final create = find.widgetWithText(FloatingActionButton, 'Termin anlegen');
    expect(create, findsOneWidget);
    await tester.tap(find.byTooltip('Kalender'));
    await tester.pumpAndSettle();
    tester
        .widget<RehearsalCalendar>(find.byType(RehearsalCalendar))
        .onSelected(DateTime(2026, 9, 20));
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(find.byType(EventEditorScreen), findsOneWidget);
    expect(
      find.text(
        DateFormat(
          'EEEE, d. MMMM yyyy · HH:mm',
          'de',
        ).format(DateTime(2026, 9, 20, 19)),
      ),
      findsOneWidget,
    );
    await finish(tester, controller);
  });

  testWidgets('members get no create button', (tester) async {
    final controller = await pump(tester, _MemberServer());
    expect(find.byType(FloatingActionButton), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('past events come newest first, also in the desktop detail', (
    tester,
  ) async {
    final server = TestServer();
    server.data['events'] = [
      _event('alt', const Duration(days: -10)),
      _event('neu', const Duration(days: -3)),
      _event('bald', const Duration(days: 2)),
    ];
    var controller = await pump(tester, server);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Vergangen'));
    expect(find.text('Probe bald'), findsNothing);
    expect(y(tester, 'Probe neu'), lessThan(y(tester, 'Probe alt')));
    await finish(tester, controller);

    controller = await pump(tester, server, size: const Size(1360, 1000));
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Vergangen'));
    expect(
      tester
          .widget<EventDetailContent>(find.byType(EventDetailContent))
          .event
          .id,
      'neu',
    );
    await finish(tester, controller);
  });

  testWidgets('paging months keeps the selection, filter and view', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final server = TestServer();
    server.data['events'] = [
      _event('a', const Duration(days: 2)),
      _event('b', const Duration(days: 5)),
    ];
    var controller = await pump(tester, server, size: const Size(1360, 1000));
    await tapVisible(tester, find.byKey(const ValueKey('schedule-event-b')));
    final september = DateFormat.yMMMM('de').format(fixedNow);
    expect(find.text(september), findsOneWidget);
    // One event on the day reads in the singular.
    final day = DateFormat.yMMMMEEEEd('de').format(fixedNow.add(2.days));
    expect(find.bySemanticsLabel('$day, 1 Termin'), findsOneWidget);
    await tapVisible(tester, find.byTooltip('Nächster Monat'));
    expect(find.text(september), findsNothing);
    expect(
      tester
          .widget<EventDetailContent>(find.byType(EventDetailContent))
          .event
          .id,
      'b',
    );
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Kommend')),
      isA<ChoiceChip>().having((c) => c.selected, 'selected', isTrue),
    );
    await finish(tester, controller);

    controller = await pump(tester, server);
    await tester.tap(find.byTooltip('Kalender'));
    await tester.pumpAndSettle();
    final selectedDay = DateFormat.yMMMMEEEEd('de').format(fixedNow);
    expect(find.text(selectedDay), findsOneWidget);
    await tester.tap(find.byTooltip('Vorheriger Monat'));
    await tester.pumpAndSettle();
    expect(find.byType(RehearsalCalendar), findsOneWidget);
    expect(find.text(selectedDay), findsOneWidget);
    semantics.dispose();
    await finish(tester, controller);
  });

  testWidgets('empty days and filters explain themselves', (tester) async {
    final server = TestServer();
    server.data['events'] = [_event('a', const Duration(days: 2))];
    final controller = await pump(tester, server);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Vergangen'));
    expect(find.text('Hier ist alles ruhig.'), findsOneWidget);
    expect(
      find.text('Es gibt noch keine vergangenen Termine.'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Kalender'));
    await tester.pumpAndSettle();
    final empty = DateTime(2026, 9, 13);
    tester
        .widget<RehearsalCalendar>(find.byType(RehearsalCalendar))
        .onSelected(empty);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Am ${DateFormat('EEEE, d. MMMM', 'de').format(empty)} '
        'ist nichts geplant.',
      ),
      findsOneWidget,
    );
    await finish(tester, controller);
  });

  testWidgets('a waiting slot pool shows a banner that opens the finder', (
    tester,
  ) async {
    final server = SlotServer()..data['slotPools'] = [pool()];
    final controller = await pump(tester, server);
    final banner = find.text('Terminfinder: Wähle noch ein Zeitfenster');
    expect(banner, findsOneWidget);
    expect(find.text('Fototermin'), findsOneWidget);
    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(find.byType(SlotPoolsScreen), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('without a waiting pool there is no banner', (tester) async {
    final server = SlotServer()..data['slotPools'] = [pool(myBooking: 's3')];
    final controller = await pump(tester, server);
    expect(find.text('Terminfinder: Wähle noch ein Zeitfenster'), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('the header menu leads to the finder and absences', (
    tester,
  ) async {
    final controller = await pump(tester, _MemberServer());
    await tester.tap(find.byTooltip('Weitere Optionen'));
    await tester.pumpAndSettle();
    expect(find.text('Terminfinder'), findsOneWidget);
    await tester.tap(find.text('Abwesenheit melden'));
    await tester.pumpAndSettle();
    expect(find.byType(AddAbsenceScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Weitere Optionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terminfinder'));
    await tester.pumpAndSettle();
    expect(find.byType(SlotPoolsScreen), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('event cards spell out open and closed responses', (
    tester,
  ) async {
    final server = TestServer();
    server.data['events'] = [
      _event('offen', const Duration(days: 2)),
      {..._event('zu', const Duration(days: 3)), 'locked': true},
    ];
    server.data['attendanceByEvent'] = {};
    final controller = await pump(tester, server);
    Finder inCard(String title, String text) => find.descendant(
      of: find.widgetWithText(EventCard, title),
      matching: find.text(text),
    );
    expect(inCard('Probe offen', 'Offen'), findsOneWidget);
    expect(inCard('Probe zu', 'Geschlossen'), findsOneWidget);
    await finish(tester, controller);
  });
}

extension on int {
  Duration get days => Duration(days: this);
}
