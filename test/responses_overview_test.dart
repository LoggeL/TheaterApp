import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/rehearsal/rehearsal.dart';

import 'app_controller_test.dart'
    show TestServer, signIn, fixedNow, jsonResponse;

class _MemberServer extends TestServer {
  @override
  JsonMap get user => {...super.user, 'role': 'member'};
}

const _arrival = '2026-09-13T17:45:00Z';

void _seed(TestServer server) {
  server.data['events'] = [
    {
      'id': 'rehearsal',
      'title': 'Szenenprobe',
      'startsAt': '2026-09-13T17:00:00Z',
      'endsAt': '2026-09-13T19:00:00Z',
    },
  ];
  // Alex dabei, Robin später, Toni nicht dabei, Kim explizit offen, Sam ohne Antwort.
  server.data['memberAttendanceByEvent'] = {
    'rehearsal': {'1': 'yes', '2': 'late', '3': 'no', '4': 'open'},
  };
  server.data['arrivalsByEvent'] = {
    'rehearsal': {'2': _arrival},
  };
  server.data['capabilities'] = {'pushConfigured': true};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Widget screen(Widget child, {double textScale = 1}) => MaterialApp(
    theme: StageTheme.build(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: child,
  );

  Future<void> surface(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('overview counts, groups, filters and reminds open people', (
    tester,
  ) async {
    await surface(tester, const Size(1000, 2400));
    final semantics = tester.ensureSemantics();
    final server = TestServer();
    _seed(server);
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      screen(
        ResponsesAdminScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in ['1 Zugesagt', '1 Später', '1 Abgesagt', '2 Offen']) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    expect(find.text('3 von 5 haben sich zurückgemeldet'), findsOneWidget);
    expect(find.text('Noch keine Rückmeldung'), findsOneWidget);
    for (final name in [
      'Alex Bühnenfreund',
      'Robin Spielmann',
      'Toni Lichtblick',
      'Kim Kulisse',
      'Sam Vorhang',
    ]) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    final local = DateFormat.Hm(
      'de',
    ).format(DateTime.parse(_arrival).toLocal());
    expect(find.text('ab $local Uhr'), findsOneWidget);

    // A count filters the list down to its group; tapping again resets.
    await tester.tap(find.bySemanticsLabel('1 Abgesagt'));
    await tester.pumpAndSettle();
    expect(find.text('Toni Lichtblick'), findsOneWidget);
    expect(find.text('Kim Kulisse'), findsNothing);
    expect(find.text('Noch keine Rückmeldung'), findsNothing);
    await tester.tap(find.text('Alle zeigen'));
    await tester.pumpAndSettle();
    expect(find.text('Kim Kulisse'), findsOneWidget);

    // Sections collapse.
    await tester.tap(find.text('Noch keine Rückmeldung'));
    await tester.pumpAndSettle();
    expect(find.text('Kim Kulisse'), findsNothing);
    expect(find.text('Sam Vorhang'), findsNothing);
    await tester.tap(find.text('Noch keine Rückmeldung'));
    await tester.pumpAndSettle();
    expect(find.text('Sam Vorhang'), findsOneWidget);

    // The reminder names its recipients and waits for confirmation.
    final sent = server.actionBodies.length;
    await tester.tap(find.text('Offene erinnern'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '2 Personen bekommen eine Push-Erinnerung an diesen Termin: '
        'Kim Kulisse, Sam Vorhang.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies, hasLength(sent));
    await tester.tap(find.text('Offene erinnern'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Erinnerung senden'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'event.remindOpen');
    expect(server.actionBodies.last['eventId'], 'rehearsal');
    expect(find.text('Erinnerung an 2 Personen gesendet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('no reminder without push and no overview for members', (
    tester,
  ) async {
    final server = TestServer();
    _seed(server);
    server.data['capabilities'] = {'pushConfigured': false};
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      screen(
        ResponsesAdminScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Offene erinnern'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();

    final member = _MemberServer();
    _seed(member);
    final memberController = member.controller();
    await signIn(memberController);
    expect(memberController.user?.isAdmin, isFalse);
    await tester.pumpWidget(
      screen(
        ResponsesAdminScreen(
          controller: memberController,
          event: memberController.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Admin-Zugang erforderlich.'), findsOneWidget);
    expect(find.text('Kim Kulisse'), findsNothing);
    expect(find.text('Noch keine Rückmeldung'), findsNothing);
    expect(find.text('Offene erinnern'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    memberController.dispose();
  });

  for (final width in [320.0, 412.0]) {
    testWidgets('overview fits ${width.toInt()} px with large text', (
      tester,
    ) async {
      await surface(tester, Size(width, 4000));
      final server = TestServer();
      _seed(server);
      final controller = server.controller();
      await signIn(controller);
      await tester.pumpWidget(
        screen(
          ResponsesAdminScreen(
            controller: controller,
            event: controller.events.single,
          ),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Offene erinnern'), findsOneWidget);
      expect(find.text('Sam Vorhang'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('details show decline reasons, absences and the last reminder', (
    tester,
  ) async {
    await surface(tester, const Size(1000, 2400));
    final server = TestServer();
    _seed(server);
    server.data['capabilities'] = {
      'pushConfigured': true,
      'features': ['eventDetailsV2', 'nudges'],
    };
    server.override = (request) {
      if (!request.url.path.contains('/admin/events/rehearsal')) return null;
      return Future.value(
        jsonResponse({
          'responses': [
            {'personId': 1, 'status': 'yes', 'reason': ''},
            {'personId': 2, 'status': 'late', 'reason': ''},
            {'personId': 3, 'status': 'no', 'reason': 'Krank'},
          ],
          'checkins': [],
          'absences': [
            {
              'id': 'a1',
              'personId': 3,
              'from': '2026-09-13',
              'to': '2026-09-14',
            },
          ],
          // Sam is no longer invited; the server knows best.
          'invitedIds': [1, 2, 3, 4],
          'openIds': [4],
          'absentIds': [3],
          'lastRemindedAt': fixedNow
              .subtract(const Duration(minutes: 5))
              .toUtc()
              .toIso8601String(),
          'remindCount': 2,
        }),
      );
    };
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      screen(
        ResponsesAdminScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Grund: Krank'), findsOneWidget);
    expect(find.text('Abwesend gemeldet'), findsOneWidget);
    expect(find.text('Sam Vorhang'), findsNothing);
    expect(find.text('3 von 4 haben sich zurückgemeldet'), findsOneWidget);
    expect(find.text('Zuletzt erinnert: heute, 11:55 (2×)'), findsOneWidget);
    // Within the server's cooldown the button waits.
    final remind = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Offene erinnern'),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    expect(remind.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('answers come from the snapshot, not from older details', (
    tester,
  ) async {
    await surface(tester, const Size(1000, 2400));
    final server = TestServer();
    _seed(server);
    server.override = (request) {
      if (!request.url.path.contains('/admin/events/rehearsal')) return null;
      // Loaded before Kim reopened the decline; the snapshot is newer.
      return Future.value(
        jsonResponse({
          'responses': [
            {'personId': 3, 'status': 'no', 'reason': 'Krank'},
            {'personId': 4, 'status': 'no', 'reason': 'Alt'},
          ],
          'checkins': [],
          'absences': [],
        }),
      );
    };
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      screen(
        ResponsesAdminScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 von 5 haben sich zurückgemeldet'), findsOneWidget);
    expect(find.text('Grund: Krank'), findsOneWidget);
    expect(find.text('Grund: Alt'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a failing details request keeps the snapshot view', (
    tester,
  ) async {
    await surface(tester, const Size(1000, 2400));
    final server = TestServer();
    _seed(server);
    server.override = (request) => request.url.path.contains('/admin/events/')
        ? Future.value(jsonResponse({'error': 'kaputt'}, 500))
        : null;
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      screen(
        ResponsesAdminScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 von 5 haben sich zurückgemeldet'), findsOneWidget);
    expect(find.textContaining('Grund:'), findsNothing);
    expect(find.text('Offene erinnern'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
