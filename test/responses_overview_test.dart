import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/rehearsal_admin.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn;

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

    for (final label in ['1 Dabei', '1 Später', '1 Nicht dabei', '2 Offen']) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    expect(find.text('3 von 5 haben sich zurückgemeldet'), findsOneWidget);
    expect(find.text('Fehlt noch'), findsOneWidget);
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
    await tester.tap(find.bySemanticsLabel('1 Nicht dabei'));
    await tester.pumpAndSettle();
    expect(find.text('Toni Lichtblick'), findsOneWidget);
    expect(find.text('Kim Kulisse'), findsNothing);
    expect(find.text('Fehlt noch'), findsNothing);
    await tester.tap(find.text('Alle zeigen'));
    await tester.pumpAndSettle();
    expect(find.text('Kim Kulisse'), findsOneWidget);

    // Sections collapse.
    await tester.tap(find.text('Fehlt noch'));
    await tester.pumpAndSettle();
    expect(find.text('Kim Kulisse'), findsNothing);
    expect(find.text('Sam Vorhang'), findsNothing);
    await tester.tap(find.text('Fehlt noch'));
    await tester.pumpAndSettle();
    expect(find.text('Sam Vorhang'), findsOneWidget);

    await tester.tap(find.text('Offene erinnern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'event.remindOpen');
    expect(server.actionBodies.last['eventId'], 'rehearsal');
    expect(find.text('Erinnerung an 2 Personen vorgemerkt.'), findsOneWidget);
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
    expect(find.text('Fehlt noch'), findsNothing);
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
}
