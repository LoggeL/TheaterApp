import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/events/events.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => initializeDateFormatting('de'));

  Future<void> smallScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

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

  testWidgets('past RSVP is read-only and never queues a response', (
    tester,
  ) async {
    final server = TestServer();
    server.data['events'] = [
      {
        'id': 'past',
        'title': 'Vergangene Probe',
        'startsAt': '2026-09-11T17:00:00Z',
        'endsAt': '2026-09-11T19:00:00Z',
      },
    ];
    server.data['attendanceByEvent'] = {'past': 'yes'};
    final controller = server.controller();
    await signIn(controller);
    server.offline = true;
    await tester.pumpWidget(
      screen(
        Scaffold(
          body: RsvpPanel(
            controller: controller,
            event: controller.events.single,
          ),
        ),
      ),
    );
    expect(find.text('Bin dabei'), findsNothing);
    expect(find.text('Rückmeldung zurücknehmen'), findsNothing);
    expect(
      find.text('Der Termin ist vorbei. Rückmeldungen sind geschlossen.'),
      findsOneWidget,
    );
    expect(
      tester.widget<RsvpStatusBadge>(find.byType(RsvpStatusBadge)).status,
      'yes',
    );
    expect(controller.outbox, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('all schedule filters and view choices fit at large text', (
    tester,
  ) async {
    await smallScreen(tester);
    final server = TestServer();
    server.data['events'] = [];
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      screen(
        Scaffold(body: ScheduleScreen(controller: controller)),
        textScale: 2,
      ),
    );
    for (final label in ['Kommend', 'Offen', 'Zugesagt', 'Vergangen']) {
      final rect = tester.getRect(find.widgetWithText(ChoiceChip, label));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.bottom, lessThanOrEqualTo(1000));
    }
    expect(find.text('Hier ist alles ruhig.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Kalender'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
