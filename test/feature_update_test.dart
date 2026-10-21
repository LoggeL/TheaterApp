import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/main.dart';

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
      if (width >= 900) {
        // The rail lists Admin as a section.
        expect(find.text('Admin'), findsOneWidget);
        await tester.tap(find.text('Admin'));
      } else {
        // Phones keep five tabs; Admin opens from the app bar.
        expect(find.byType(NavigationDestination), findsNWidgets(5));
        expect(find.text('Admin'), findsNothing);
        await tester.tap(find.byTooltip('Admin'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Administration.'), findsOneWidget);
      expect(find.text('Personen & Zugänge'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (width < 900) {
        await tester.tap(find.byTooltip('Zurück'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Termine'));
      await tester.pumpAndSettle();
      if (width < 1250) {
        await tester.tap(find.byTooltip('Kalender'));
        await tester.pumpAndSettle();
      }
      expect(find.byType(RehearsalCalendar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
