import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/main.dart';
import 'package:theater_app/ui/events.dart';
import 'package:theater_app/ui/more.dart';

void main() {
  setUpAll(() async => initializeDateFormatting('de'));
  test('Deep links accept only local declared routes without tokens', () {
    expect(AppTarget.fromUri(Uri.parse('https://evil.test/events/1')), isNull);
    expect(AppTarget.fromUri(Uri.parse('theaterapp://evil/events/1')), isNull);
    expect(
      AppTarget.fromUri(Uri.parse('theaterapp://user@app/events/1')),
      isNull,
    );
    final target = AppTarget.fromUri(
      Uri.parse('theaterapp://app/events/probe-1'),
    );
    expect(target?.kind, 'events');
    expect(target?.id, 'probe-1');
  });
  test('Calendar export uses UTC, escapes text and folds UTF8 at 75 bytes', () {
    final event = TheaterEvent(
      id: 'test',
      title: 'Probe, nächste; Szene\nBühne',
      startsAt: DateTime.parse('2026-10-25T18:00:00+01:00'),
      endsAt: DateTime.parse('2026-10-25T20:00:00+01:00'),
      place: 'Ramsen',
    );
    final ics = calendarFile(event, now: DateTime.utc(2026));
    expect(ics, contains('DTSTART:20261025T170000Z\r\n'));
    expect(ics, contains(r'SUMMARY:Probe\, nächste\; Szene\nBühne'));
    expect(ics.endsWith('END:VCALENDAR\r\n'), isTrue);
  });
  testWidgets('Native demo navigation and attendance work at 390px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await c.init();
    await c.startDemo();
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('Heute'), findsOneWidget);
    expect(find.text('Dein Probenplan.'), findsNothing);
    await tester.tap(find.text('Termine'));
    await tester.pumpAndSettle();
    expect(find.text('Dein Probenplan.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final card = find.byType(EventCard).first;
    await tester.tap(card);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bin dabei'));
    await tester.pumpAndSettle();
    expect(c.events.first.response, 'yes');
    expect(find.text('Rückmeldung gespeichert'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('First start offers explicit demo and login at narrow width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mit Theaterkonto anmelden'), findsOneWidget);
    expect(find.text('App mit Beispieldaten ausprobieren'), findsOneWidget);
    expect(c.isDemo, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Admin links a real scene selection to a rehearsal in demo', (
    tester,
  ) async {
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await c.init();
    await c.startDemo();
    final event = c.events.first;
    await tester.pumpWidget(
      MaterialApp(
        home: EventScriptLinkScreen(controller: c, event: event),
      ),
    );
    await tester.pumpAndSettle();
    final boxes = find.byType(CheckboxListTile);
    expect(boxes, findsWidgets);
    await tester.tap(boxes.last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Zuordnung speichern'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Zuordnung speichern'));
    await tester.pumpAndSettle();
    final linked = c.events.firstWhere((e) => e.id == event.id);
    expect(linked.productionId, event.productionId);
    expect(
      linked.sceneIds,
      contains(c.scripts[event.productionId]!.scenes.last.id),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('Check-in restores existing attendance before editing', (
    tester,
  ) async {
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await c.init();
    await c.startDemo();
    final member = c.members.first;
    await c.checkIn(c.events.first.id, [member.id]);
    await tester.pumpWidget(
      MaterialApp(
        home: CheckInScreen(controller: c, event: c.events.first),
      ),
    );
    await tester.pumpAndSettle();
    final row = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile).first,
    );
    expect(row.value, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
