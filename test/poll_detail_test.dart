import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/polls/polls.dart';

import 'app_controller_test.dart' show TestServer, signIn;

JsonMap _poll({bool closed = false, int? eligibleVotes}) => {
  'id': 'p',
  'title': 'Welches Essen?',
  'closed': closed,
  'eligibleCount': 30,
  'eligibleVotes': ?eligibleVotes,
  'addressedToMe': true,
  'options': [
    {'id': 'a', 'label': 'Pizza', 'votes': 8},
    {'id': 'b', 'label': 'Pasta', 'votes': 4},
  ],
};

const _all = ['pollRemind', 'pollDelete', 'nudges'];

void main() {
  setUpAll(() => initializeDateFormatting('de'));

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

  Future<AppController> open(
    WidgetTester tester,
    TestServer server, {
    List<String> features = _all,
    bool closed = false,
    int? eligibleVotes,
  }) async {
    server.data['polls'] = [
      _poll(closed: closed, eligibleVotes: eligibleVotes),
    ];
    server.data['capabilities'] = {
      'pushConfigured': true,
      'features': features,
    };
    final c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => PollDetailScreen(controller: c, pollId: 'p'),
                ),
              ),
              child: const Text('öffnen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('admins see participation and remind open voters', (
    tester,
  ) async {
    final server = TestServer();
    final c = await open(tester, server);
    expect(find.text('12 von 30 haben abgestimmt'), findsOneWidget);
    await tester.tap(find.text('Offene erinnern'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '18 Personen bekommen eine Push-Erinnerung an diese Abstimmung.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Erinnerung senden'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {'action': 'poll.remindOpen', 'id': 'p'});
    expect(find.text('Erinnerung an 18 Personen gesendet.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'edit a voted answer and enable multiple answers from the poll detail',
    (tester) async {
      tester.view.physicalSize = const Size(650, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = TestServer();
      final c = await open(
        tester,
        server,
        features: [..._all, 'pollMultiSelect'],
      );
      await tester.tap(find.byTooltip('Abstimmung bearbeiten'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mehrere Antworten erlauben'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Antwort 1'),
        'Pizza Margherita',
      );
      await tester.tap(find.text('Antwort hinzufügen'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Antwort 3'),
        'Suppe',
      );
      expect(find.byTooltip('Antwort entfernen'), findsOneWidget);
      final save = find.widgetWithText(FilledButton, 'Speichern');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final saved = server.actionBodies.last;
      expect(saved['id'], 'p');
      expect(saved['allowMultiple'], true);
      expect(saved['options'], [
        {'id': 'a', 'label': 'Pizza Margherita'},
        {'id': 'b', 'label': 'Pasta'},
        {'label': 'Suppe'},
      ]);
      expect(find.byType(PollEditorScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'offline checkboxes keep earlier choices and count each person once',
    (tester) async {
      final server = TestServer();
      server.data['polls'] = [
        {
          ..._poll(eligibleVotes: 12),
          'allowMultiple': true,
          'totalVotes': 12,
          'choices': ['a'],
        },
      ];
      final c = server.controller();
      await signIn(c);
      server.offline = true;
      await tester.pumpWidget(
        MaterialApp(
          home: PollDetailScreen(controller: c, pollId: 'p'),
        ),
      );
      Future<void> tap(String label) async {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      await tap('Pasta');
      expect(find.byIcon(Icons.check_box), findsNWidgets(2));
      expect(c.polls.single.selectedOptionIds, ['a', 'b']);
      expect(c.polls.single.options.map((o) => o.votes), [8, 5]);
      expect(c.polls.single.eligibleVotes, 12);
      await tap('Pizza');
      expect(c.polls.single.selectedOptionIds, ['b']);
      await tap('Pasta');
      expect(c.polls.single.hasVoted, isFalse);
      expect(c.polls.single.totalVotes, 11);
      expect(c.polls.single.eligibleVotes, 11);
      expect(c.outbox.map((a) => a.payload['selected']), [true, false, false]);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('votes from outside the audience do not hide open voters', (
    tester,
  ) async {
    final server = TestServer();
    final c = await open(tester, server, eligibleVotes: 10);
    expect(find.text('10 von 30 haben abgestimmt'), findsOneWidget);
    await tester.tap(find.text('Offene erinnern'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '20 Personen bekommen eine Push-Erinnerung an diese Abstimmung.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('without the flags the poll keeps today\'s options', (
    tester,
  ) async {
    final server = TestServer();
    final c = await open(tester, server, features: const [], closed: true);
    expect(find.text('Offene erinnern'), findsNothing);
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    expect(find.text('Löschen'), findsNothing);
    await tester.tap(find.text('Wieder öffnen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Die Frist wird entfernt.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Wieder öffnen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last.containsKey('closesAt'), isFalse);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('reopening offers to keep going without a deadline', (
    tester,
  ) async {
    final server = TestServer();
    final c = await open(tester, server, closed: true);
    // Closed polls offer no reminder.
    expect(find.text('Offene erinnern'), findsNothing);
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wieder öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Neue Frist wählen'), findsOneWidget);
    await tester.tap(find.text('Ohne Frist'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'poll.close',
      'id': 'p',
      'version': 1,
      'closed': false,
    });
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('admins delete a poll after confirming', (tester) async {
    final server = TestServer();
    final c = await open(tester, server);
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    expect(find.text('Abstimmung löschen?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'poll.delete',
      'id': 'p',
      'version': 1,
    });
    expect(find.text('Abstimmung gelöscht'), findsOneWidget);
    expect(find.byType(PollDetailScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  test('a queued deletion hides the poll right away', () async {
    final server = TestServer();
    server.data['polls'] = [_poll()];
    final c = server.controller();
    addTearDown(c.dispose);
    await signIn(c);
    server.offline = true;
    await c.performAction({'action': 'poll.delete', 'id': 'p', 'version': 1});
    expect(c.polls, isEmpty);
  });

  test('a queued vote keeps the server\'s extra poll fields', () async {
    final server = TestServer();
    server.data['polls'] = [
      {..._poll(), 'futureField': 'bleibt'},
    ];
    final c = server.controller();
    addTearDown(c.dispose);
    await signIn(c);
    server.offline = true;
    await c.vote('p', 'b');
    final poll = c.polls.single;
    expect(poll.selectedOptionId, 'b');
    expect(poll.eligibleCount, 30);
    expect(poll.addressedToMe, isTrue);
    expect(poll.totalVotes, 13);
  });
}
