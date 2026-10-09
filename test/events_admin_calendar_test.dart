import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/admin.dart';
import 'package:theater_app/ui/calendar.dart';
import 'package:theater_app/ui/event_style.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('event management offers a calendar that creates on the day', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = TestServer().controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: EventsAdminScreen(controller: controller),
      ),
    );
    expect(find.byType(RehearsalCalendar), findsNothing);
    await tester.tap(find.text('Kalender'));
    await tester.pumpAndSettle();
    expect(find.byType(RehearsalCalendar), findsOneWidget);
    final today = DateUtils.dateOnly(DateTime.now());
    final planned = controller.events.where((e) => eventOnDay(e, today));
    expect(find.byTooltip('Termin bearbeiten'), findsNWidgets(planned.length));
    final create = find.text(
      'Termin am ${DateFormat('d. MMMM', 'de').format(today)} anlegen',
    );
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(find.byType(EventEditorScreen), findsOneWidget);
    expect(
      find.text(
        DateFormat(
          'EEEE, d. MMMM yyyy · HH:mm',
          'de',
        ).format(today.add(const Duration(hours: 19))),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('members are invited by role or by name', () {
    const sam = TheaterMember(id: 2, name: 'Sam', roleIds: ['role-3']);
    expect(sam.inAudience(const []), isTrue);
    expect(sam.inAudience(const ['role-3']), isTrue);
    expect(sam.inAudience(const [], const [2]), isTrue);
    expect(sam.inAudience(const [], const [5]), isFalse);
    expect(sam.inAudience(const ['role-1'], const [5]), isFalse);
    expect(sam.inAudience(const ['role-1'], const [2]), isTrue);
  });

  testWidgets('the event editor invites single people besides groups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer(), controller = server.controller();
    await signIn(controller);
    final person = controller.members.first;
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: EventEditorScreen(controller: controller),
      ),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Fotos');
    expect(find.text('Eingeladen: Alle'), findsOneWidget);
    await tester.tap(find.text('Person hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, person.name));
    await tester.pump();
    await tester.tap(find.text('1 übernehmen'));
    await tester.pumpAndSettle();
    expect(find.text('Eingeladen: ${person.name}'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Alle'), findsNothing);
    final save = find.text('Termin speichern');
    await tester.dragUntilVisible(
      save,
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    final body = server.actionBodies.lastWhere(
      (b) => b['action'] == 'event.save',
    );
    expect(body['personIds'], [person.id]);
    expect(body['roleIds'], isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('calendar marks show the own response status', (tester) async {
    final day = DateTime(2027, 1, 12);
    TheaterEvent event(String id, String response) => TheaterEvent(
      id: id,
      title: id,
      startsAt: day.add(const Duration(hours: 18)),
      endsAt: day.add(const Duration(hours: 20)),
      response: response,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: RehearsalCalendar(
              selected: DateTime(2027, 1, 5),
              onSelected: (_) {},
              events: [event('a', 'yes'), event('b', 'no'), event('c', 'open')],
            ),
          ),
        ),
      ),
    );
    final marks = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle)
        .toList();
    // Three marks on the day plus four in the legend.
    expect(marks.where((d) => d.color == responseColor('yes')), hasLength(2));
    expect(marks.where((d) => d.color == responseColor('no')), hasLength(2));
    expect(
      marks.where((d) => d.color == null && d.border != null),
      hasLength(2),
    );
    for (final label in ['Zugesagt', 'Später', 'Abgesagt', 'Offen']) {
      expect(find.text(label), findsOneWidget);
    }
  });
}
