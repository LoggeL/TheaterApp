import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/ui/theme.dart';
import 'package:theater_app/ui/today.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  for (final answered in [false, true]) {
    testWidgets(
      answered
          ? 'answered events keep their status on the start page'
          : 'open events can be answered on the start page',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final start = DateTime.now().add(const Duration(days: 2));
        final server = TestServer();
        server.data['events'] = [
          {
            'id': 'next',
            'title': 'Szenenprobe',
            'startsAt': start.toUtc().toIso8601String(),
            'endsAt': start
                .add(const Duration(hours: 2))
                .toUtc()
                .toIso8601String(),
            'place': 'Kolpingheim',
          },
        ];
        server.data['attendanceByEvent'] = answered ? {'next': 'yes'} : {};
        final controller = server.controller();
        await signIn(controller);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: Scaffold(
              // The app shell rebuilds the start page on controller changes.
              body: ListenableBuilder(
                listenable: controller,
                builder: (_, _) => TodayScreen(
                  controller: controller,
                  onPlan: () {},
                  onScripts: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (answered) {
          expect(find.text('Bist du dabei?'), findsNothing);
        } else {
          expect(find.text('Bist du dabei?'), findsOneWidget);
          await tester.tap(find.text('Kann nicht'));
          await tester.pumpAndSettle();
          expect(find.text('Dieses Mal ohne dich.'), findsOneWidget);
          await tester.tapAt(const Offset(20, 20));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Bin dabei'));
          await tester.pumpAndSettle();
          final body = server.actionBodies.last;
          expect(
            [body['action'], body['eventId'], body['status']],
            ['attendance', 'next', 'yes'],
          );
          expect(find.text('Bist du dabei?'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}
