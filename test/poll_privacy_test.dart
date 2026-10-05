import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/polls.dart';
import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test(
    'anonymous cache drops voter identities while named choices keep their mode and names',
    () {
      final json = <String, dynamic>{
        'id': 'p',
        'title': 'Pause',
        'options': [
          {
            'id': 'a',
            'label': 'Drinnen',
            'votes': 1,
            'voters': [
              {'personId': 7, 'name': 'Mara Beispiel'},
            ],
          },
          {'id': 'b', 'label': 'Draußen', 'votes': 0, 'voters': []},
        ],
        'choice': 'a',
        'closesAt': '2026-12-01T19:00:00Z',
      };
      final anonymous = Poll.fromJson(json);
      expect(anonymous.anonymous, isTrue);
      expect(anonymous.options.first.voters, isEmpty);
      expect(jsonEncode(anonymous.toJson()), isNot(contains('Mara Beispiel')));
      final named = Poll.fromJson({...json, 'anonymous': false});
      final changed = named.withChoice(
        'b',
        voter: const PollVoter(personId: 7, name: 'Mara Beispiel'),
      );
      final restored = Poll.fromJson(changed.toJson());
      expect(restored.anonymous, isFalse);
      expect(restored.options.first.voters, isEmpty);
      expect(restored.options.last.voters.single.name, 'Mara Beispiel');
      expect(restored.options.map((o) => o.votes), [0, 1]);
      expect(restored.closesAt, named.closesAt);
    },
  );

  testWidgets(
    'creator selects named voting and an optional end date at mobile width',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = TestServer();
      final controller = server.controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(home: PollEditorScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Frage'),
        'Wo machen wir Pause?',
      );
      await tester.tap(find.text('Namentlich'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Antwort 1'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Antwort 1'),
        'Drinnen',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Antwort 2'),
        'Draußen',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Enddatum festlegen'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Enddatum festlegen'));
      await tester.pumpAndSettle();
      expect(find.text('Enddatum und Uhrzeit'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Speichern'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Speichern'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      expect(server.actionBodies.last['anonymous'], false);
      expect(
        DateTime.parse(
          server.actionBodies.last['closesAt'] as String,
        ).isAfter(DateTime.now()),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  for (final anonymous in [true, false]) {
    testWidgets(
      'results ${anonymous ? 'hide' : 'show'} voter names and expire locally',
      (tester) async {
        final server = TestServer();
        server.data['polls'] = [
          {
            'id': 'p',
            'title': 'Pause',
            'anonymous': anonymous,
            'closesAt': '2020-01-01T00:00:00Z',
            'options': [
              {
                'id': 'a',
                'label': 'Drinnen',
                'votes': 1,
                'voters': [
                  {'personId': 7, 'name': 'Mara Beispiel'},
                ],
              },
              {'id': 'b', 'label': 'Draußen', 'votes': 0},
            ],
          },
        ];
        final controller = server.controller();
        await signIn(controller);
        await tester.pumpWidget(
          MaterialApp(
            home: PollDetailScreen(controller: controller, pollId: 'p'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(anonymous ? 'Anonym' : 'Namentlich'), findsOneWidget);
        expect(
          find.text('Mara Beispiel'),
          anonymous ? findsNothing : findsOneWidget,
        );
        expect(find.text('Abgeschlossen · 1 Stimme'), findsOneWidget);
        await tester.tap(find.text('Draußen'));
        await tester.pumpAndSettle();
        expect(server.actionBodies, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}
