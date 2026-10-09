import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/ui/polls.dart';
import 'package:theater_app/ui/theme.dart';
import 'package:theater_app/ui/today.dart';
import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('desktop columns show real poll and open its voting route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1360, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final server = TestServer();
    server.data['polls'] = [
      {
        'id': 'today-poll',
        'title': 'Welche Bühne?',
        'anonymous': false,
        'closesAt': DateTime.now()
            .add(const Duration(days: 7))
            .toUtc()
            .toIso8601String(),
        'options': [
          {'id': 'a', 'label': 'Großer Saal', 'votes': 2},
          {'id': 'b', 'label': 'Kleine Bühne', 'votes': 1},
        ],
      },
    ];
    final controller = server.controller();
    await signIn(controller);
    addTearDown(controller.dispose);
    var plans = 0;
    var scripts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayScreen(
            controller: controller,
            onPlan: () => plans++,
            onScripts: () => scripts++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final primary = find.byKey(const ValueKey('today-primary-column'));
    final secondary = find.byKey(const ValueKey('today-secondary-column'));
    expect(primary, findsOneWidget);
    expect(
      tester.getTopLeft(secondary).dx,
      greaterThan(tester.getTopLeft(primary).dx),
    );
    await tester.tap(find.text('Zum Plan'));
    expect(plans, 1);
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(SectionTitle, 'Dein Drehbuch'),
        matching: find.text('Alle ansehen'),
      ),
    );
    expect(scripts, 1);
    final poll = controller.polls.firstWhere((p) => !p.isClosed);
    expect(find.text(poll.title), findsOneWidget);
    expect(find.text(poll.options.first.label), findsOneWidget);
    await tester.ensureVisible(find.text('Jetzt abstimmen'));
    await tester.tap(find.text('Jetzt abstimmen'));
    await tester.pumpAndSettle();
    expect(find.byType(PollDetailScreen), findsOneWidget);
    expect(find.text(poll.title), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'available width and large text fall back to mobile with truthful empty states',
    (tester) async {
      tester.view.physicalSize = const Size(1360, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
      );
      await controller.init();
      addTearDown(controller.dispose);
      Future<void> pump(double width, double scale) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: TodayScreen(
                      controller: controller,
                      onPlan: () {},
                      onScripts: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await pump(600, 1);
      expect(find.byKey(const ValueKey('today-primary-column')), findsNothing);
      expect(find.text('Keine anstehenden Termine'), findsOneWidget);
      expect(find.text('Kein aktuelles Stück'), findsOneWidget);
      await pump(1360, 1);
      expect(
        find.byKey(const ValueKey('today-primary-column')),
        findsOneWidget,
      );
      await pump(1360, 2);
      expect(find.byKey(const ValueKey('today-primary-column')), findsNothing);
      await pump(390, 2);
      expect(find.text('Keine anstehenden Termine'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
