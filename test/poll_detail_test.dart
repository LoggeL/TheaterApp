import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/features/polls/polls.dart';

import 'app_controller_test.dart' show TestServer, signIn;

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
}
