import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/main.dart';
import 'package:theater_app/ui/admin.dart';
import 'package:theater_app/ui/events.dart';
import 'package:theater_app/ui/polls.dart';
import 'package:theater_app/ui/theme.dart';
import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  test(
    'descriptions and member roles survive model copies and cache serialization',
    () {
      final event = TheaterEvent.fromJson({
        'id': 'e',
        'title': 'Aufbau',
        'description': 'Werkzeug\nmitbringen',
        'type': 'setup',
      });
      expect(
        TheaterEvent.fromJson(
          event.copyWith(response: 'yes').toJson(),
        ).description,
        'Werkzeug\nmitbringen',
      );
      expect(
        calendarFile(
          TheaterEvent(
            id: 'e',
            title: 'Aufbau',
            startsAt: DateTime(2027),
            description: 'Werkzeug\nmitbringen',
          ),
        ),
        contains(r'DESCRIPTION:Werkzeug\nmitbringen'),
      );
      final member = TheaterMember.fromJson({
        'id': 1,
        'name': 'Sam',
        'roleIds': ['r1', 'r2'],
      });
      expect(TheaterMember.fromJson(member.toJson()).roleIds, ['r1', 'r2']);
    },
  );
  test(
    'offline votes survive synchronization conflicts without inflating results',
    () async {
      final server = TestServer();
      server.data['polls'] = [
        {
          'id': 'p',
          'title': 'Essen',
          'options': [
            {'id': 'a', 'label': 'Pizza', 'votes': 0},
            {'id': 'b', 'label': 'Pasta', 'votes': 0},
          ],
        },
      ];
      final c = server.controller();
      await signIn(c);
      server.offline = true;
      await c.vote('p', 'a');
      await c.vote('p', 'b');
      expect(c.polls.single.options.map((o) => o.votes), [0, 1]);
      expect(c.polls.single.selectedOptionId, 'b');
      server.offline = false;
      server.actionStatus = 409;
      server.data['polls'][0]['closed'] = true;
      await c.refresh();
      expect(c.polls.single.totalVotes, 0);
      expect(c.failedCount, 2);
      expect(c.polls.single.isClosed, true);
      c.dispose();
    },
  );
  for (final width in [390.0, 900.0, 1440.0]) {
    testWidgets('Admin navigation and plan fit ${width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = TestServer().controller();
      await signIn(c);
      await tester.pumpWidget(
        TheaterApp(controller: c, enableDeviceServices: false),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(NavigationRail),
        width >= 900 ? findsOneWidget : findsNothing,
      );
      expect(find.text('Admin'), findsOneWidget);
      await tester.tap(find.text('Admin'));
      await tester.pumpAndSettle();
      expect(find.text('Administration'), findsOneWidget);
      expect(find.text('Konten & Verknüpfungen'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Termine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kalender'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
  testWidgets('event editor saves description and additional event type', (
    tester,
  ) async {
    final server = TestServer(), c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: EventEditorScreen(controller: c),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Titel'),
      'Werkstatt',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Beschreibung'),
      'Schraubendreher mitbringen',
    );
    final kind = find.byKey(const ValueKey('event-kind'));
    await tester.scrollUntilVisible(
      kind,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(kind);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Aufbau').last);
    await tester.tap(find.text('Aufbau').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Termin speichern'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Termin speichern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['type'], 'setup');
    expect(
      server.actionBodies.last['description'],
      'Schraubendreher mitbringen',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('member editor saves two independently selectable roles', (
    tester,
  ) async {
    final server = TestServer();
    server.data['personRoles'] = [
      {'id': 'r1', 'name': 'Technik'},
      {'id': 'r2', 'name': 'Requisite'},
    ];
    final c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      MaterialApp(home: MemberEditorScreen(controller: c)),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Sam');
    await tester.tap(find.text('Technik'));
    await tester.tap(find.text('Requisite'));
    await tester.ensureVisible(find.text('Speichern'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['roleIds'], ['r1', 'r2']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('poll detail sends a general choice and renders results', (
    tester,
  ) async {
    final server = TestServer();
    server.data['polls'] = [
      {
        'id': 'p',
        'title': 'Welches Essen?',
        'options': [
          {'id': 'a', 'label': 'Pizza', 'votes': 2},
          {'id': 'b', 'label': 'Pasta', 'votes': 1},
        ],
      },
    ];
    final c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      MaterialApp(
        home: PollDetailScreen(controller: c, pollId: 'p'),
      ),
    );
    await tester.tap(find.text('Pasta'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'poll.vote',
      'pollId': 'p',
      'optionId': 'b',
    });
    expect(find.text('3 Stimmen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
