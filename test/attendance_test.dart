import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/rehearsal/rehearsal.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Widget screen(Widget child) =>
      MaterialApp(theme: StageTheme.build(Brightness.light), home: child);

  Finder choiceOf(String name) => find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
    matching: find.byType(SegmentedButton<bool>),
  );
  Finder segment(String name, String label) =>
      find.descendant(of: choiceOf(name), matching: find.text(label));
  Set<bool> selected(WidgetTester tester, String name) =>
      tester.widget<SegmentedButton<bool>>(choiceOf(name)).selected;
  Finder saveButton() =>
      find.widgetWithText(FilledButton, 'Änderungen speichern');

  testWidgets('restores existing attendance before editing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await c.init();
    await c.startDemo();
    final event = c.events.first;
    final member = c.members.first;
    await c.checkIn(event.id, [member.id]);
    await tester.pumpWidget(
      screen(AttendanceEditorScreen(controller: c, event: event)),
    );
    await tester.pumpAndSettle();
    expect(selected(tester, member.name), {true});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('marks, clears and saves attendance per person', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final server = TestServer();
    server.data['events'] = [
      {
        'id': 'rehearsal',
        'title': 'Szenenprobe',
        'startsAt': '2026-09-13T17:00:00Z',
        'endsAt': '2026-09-13T19:00:00Z',
      },
    ];
    server.data['memberAttendanceByEvent'] = {
      'rehearsal': {'1': 'yes', '2': 'yes', '3': 'no'},
    };
    server.data['checkinsByEvent'] = {
      'rehearsal': {'2': true, '3': false},
    };
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      screen(
        AttendanceEditorScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // People without a record come first, each group by name.
    final order = [
      'Alex Bühnenfreund',
      'Kim Kulisse',
      'Sam Vorhang',
      'Robin Spielmann',
      'Toni Lichtblick',
    ];
    final tops = [
      for (final name in order) tester.getTopLeft(find.text(name)).dy,
    ];
    expect(tops, [...tops]..sort());
    expect(selected(tester, 'Robin Spielmann'), {true});
    expect(selected(tester, 'Toni Lichtblick'), {false});
    expect(selected(tester, 'Alex Bühnenfreund'), isEmpty);
    expect(find.text('Alles gespeichert'), findsOneWidget);
    expect(tester.widget<FilledButton>(saveButton()).onPressed, isNull);

    await tester.tap(find.text('Alle Zugesagten als da markieren'));
    await tester.pumpAndSettle();
    expect(selected(tester, 'Alex Bühnenfreund'), {true});
    expect(find.text('2 da · 1 fehlt · 2 nicht erfasst'), findsOneWidget);
    expect(find.text('1 Änderung noch nicht gespeichert'), findsOneWidget);

    // Tapping the selected choice again leaves the person unrecorded.
    await tester.tap(segment('Toni Lichtblick', 'Fehlt'));
    await tester.pumpAndSettle();
    expect(selected(tester, 'Toni Lichtblick'), isEmpty);
    expect(find.text('2 Änderungen noch nicht gespeichert'), findsOneWidget);
    // Back to the saved state is no change.
    await tester.tap(segment('Kim Kulisse', 'Da'));
    await tester.pumpAndSettle();
    await tester.tap(segment('Kim Kulisse', 'Da'));
    await tester.pumpAndSettle();
    expect(find.text('2 Änderungen noch nicht gespeichert'), findsOneWidget);

    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    final body = server.actionBodies.single;
    expect(body['action'], 'checkin.save');
    expect(body['eventId'], 'rehearsal');
    expect(
      {
        for (final m in jsonList(body['members']))
          jsonMap(m)['id']: jsonMap(m)['present'],
      },
      {1: true, 3: null},
    );
    expect(find.text('Anwesenheit gespeichert.'), findsOneWidget);
    expect(find.text('Alles gespeichert'), findsOneWidget);
    expect(tester.widget<FilledButton>(saveButton()).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('rows fit 320 px with large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: AttendanceEditorScreen(
          controller: controller,
          event: controller.events.first,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SegmentedButton<bool>), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
