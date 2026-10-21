import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/accounts/accounts.dart';
import 'package:theater_app/features/messages/messages.dart';
import 'package:theater_app/features/today/today.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

JsonMap _event(String id, String title, int days) {
  final start = fixedNow.add(Duration(days: days));
  return {
    'id': id,
    'title': title,
    'startsAt': start.toUtc().toIso8601String(),
    'endsAt': start.add(const Duration(hours: 2)).toUtc().toIso8601String(),
    'place': 'Kolpingheim',
  };
}

JsonMap _message(String id, String title, {required bool read}) => {
  'id': id,
  'title': title,
  'body': 'Bitte lesen.',
  'authorName': 'Regie',
  'createdAt': fixedNow
      .subtract(const Duration(hours: 1))
      .toUtc()
      .toIso8601String(),
  'read': read,
};

JsonMap _poll({String? choice}) => {
  'id': 'poll',
  'title': 'Welche Bühne?',
  'anonymous': true,
  'choice': choice,
  'options': [
    {'id': 'a', 'label': 'Großer Saal', 'votes': 2},
    {'id': 'b', 'label': 'Kleine Bühne', 'votes': 1},
  ],
};

/// A start page with answered events, one unread and one read message and
/// an already voted poll.
TestServer _handledServer() => TestServer()
  ..data['events'] = [
    _event('next', 'Szenenprobe', 2),
    _event('later', 'Durchlaufprobe', 5),
  ]
  ..data['attendanceByEvent'] = {'next': 'yes', 'later': 'yes'}
  ..data['messages'] = [
    _message('new', 'Probenraum geändert', read: false),
    _message('old', 'Willkommen', read: true),
  ]
  ..data['polls'] = [_poll(choice: 'a')];

Future<void> _pump(
  WidgetTester tester,
  AppController controller, {
  double width = 390,
  double scale = 1,
  VoidCallback? onPlan,
}) async {
  tester.view.physicalSize = Size(width, 2600);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 2600),
            textScaler: TextScaler.linear(scale),
          ),
          child: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => TodayScreen(
              controller: controller,
              onPlan: onPlan ?? () {},
              onScripts: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

double _top(WidgetTester tester, Finder finder) => tester.getTopLeft(finder).dy;

const _allDone = 'Alles erledigt – keine offenen Rückmeldungen.';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('unread messages come first, handled items collapse below', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final server = _handledServer();
    final controller = server.controller();
    await signIn(controller);
    await _pump(tester, controller);
    final unread = find.byKey(const ValueKey('today-unread-new'));
    final next = find.byKey(const ValueKey('today-next-compact'));
    final voted = find.byKey(const ValueKey('today-poll-voted'));
    expect(find.text('Rückmeldungen offen'), findsNothing);
    expect(find.text('Bist du dabei?'), findsNothing);
    expect(find.text('Jetzt abstimmen'), findsNothing);
    expect(find.text('Du bist dabei'), findsOneWidget);
    // Only the unread message is listed on top; the read one waits below.
    expect(find.text('Willkommen'), findsNothing);
    expect(find.byKey(const ValueKey('today-messages-read')), findsNothing);
    expect(_top(tester, unread), lessThan(_top(tester, next)));
    expect(
      _top(tester, next),
      lessThan(_top(tester, find.text('Weitere Termine'))),
    );
    expect(
      _top(tester, find.text('Weitere Termine')),
      lessThan(_top(tester, find.text('Dein Drehbuch'))),
    );
    expect(
      _top(tester, find.text('Dein Drehbuch')),
      lessThan(_top(tester, voted)),
    );

    expect(find.text(_allDone), findsNothing);

    // Once it is read, one quiet line replaces the open items.
    await tester.tap(unread);
    await tester.pumpAndSettle();
    expect(find.byType(MessageDetailScreen), findsOneWidget);
    expect(server.actionBodies.last['action'], 'message.read');
    server.data['messages'] = [
      _message('new', 'Probenraum geändert', read: true),
      _message('old', 'Willkommen', read: true),
    ];
    await controller.refresh();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Neue Mitteilungen'), findsNothing);
    expect(find.byKey(const ValueKey('today-messages-read')), findsNothing);
    final done = find.text(_allDone);
    expect(done, findsOneWidget);
    expect(_top(tester, done), lessThan(_top(tester, next)));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('an open next event and an open poll stay expanded on top', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final server = TestServer()
      ..data['events'] = [
        _event('next', 'Szenenprobe', 2),
        _event('later', 'Durchlaufprobe', 5),
        _event('far', 'Premiere', 20),
      ]
      ..data['attendanceByEvent'] = {}
      ..data['messages'] = [_message('new', 'Probenraum geändert', read: false)]
      ..data['polls'] = [_poll()];
    final controller = server.controller();
    await signIn(controller);
    await _pump(tester, controller);
    expect(find.byKey(const ValueKey('today-next-compact')), findsNothing);
    expect(find.text('Erledigt'), findsNothing);
    final order = [
      find.text('Bist du dabei?'),
      find.byKey(const ValueKey('today-unread-new')),
      find.byKey(const ValueKey('today-open-later')),
      find.text('Jetzt abstimmen'),
      find.text('Weitere Termine'),
      find.text('Dein Drehbuch'),
    ];
    // The open event is answerable above, so the preview only shows 'far'.
    expect(find.text('Durchlaufprobe'), findsOneWidget);
    expect(find.text('Premiere'), findsOneWidget);
    for (var i = 1; i < order.length; i++) {
      expect(_top(tester, order[i - 1]), lessThan(_top(tester, order[i])));
    }
    // One tap votes, so each answer row is a full-size target.
    final answer = find.ancestor(
      of: find.text('Großer Saal'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(answer.first).height, greaterThanOrEqualTo(48));
    // The expanded cards also fit a small phone with large text.
    await _pump(tester, controller, width: 320, scale: 2);
    await tester.scrollUntilVisible(find.text('Jetzt abstimmen'), 300);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('collapsed sections fit small phones, large text and desktop', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final controller = _handledServer().controller();
    await signIn(controller);
    for (final (width, scale) in [(320.0, 2.0), (412.0, 1.0), (1360.0, 1.0)]) {
      await _pump(tester, controller, width: width, scale: scale);
      for (final key in ['today-next-compact', 'today-poll-voted']) {
        await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 300);
      }
      expect(tester.takeException(), isNull);
    }
    // On wide windows the events stay left, open items lead the right column.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('today-primary-column')),
        matching: find.byKey(const ValueKey('today-next-compact')),
      ),
      findsOneWidget,
    );
    final secondary = find.byKey(const ValueKey('today-secondary-column'));
    expect(
      _top(
        tester,
        find.descendant(
          of: secondary,
          matching: find.byKey(const ValueKey('today-unread-new')),
        ),
      ),
      lessThan(_top(tester, find.text('Dein Drehbuch'))),
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a slot pool still waiting for a choice is listed on top', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final controller = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await controller.init();
    await controller.startDemo();
    await _pump(tester, controller);
    expect(find.text('Terminfinder'), findsOneWidget);
    expect(
      _top(tester, find.text('Fotos fürs Programmheft')),
      lessThan(_top(tester, find.text('Weitere Termine'))),
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('further open events can be answered right on the start page', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final server = TestServer()
      ..data['events'] = [
        _event('next', 'Szenenprobe', 2),
        _event('second', 'Kostümprobe', 3),
        _event('third', 'Durchlaufprobe', 4),
        _event('fourth', 'Technikprobe', 6),
        _event('fifth', 'Generalprobe', 8),
      ]
      ..data['attendanceByEvent'] = {}
      ..data['messages'] = <dynamic>[];
    final controller = server.controller();
    await signIn(controller);
    var plans = 0;
    await _pump(tester, controller, onPlan: () => plans++);
    final second = find.byKey(const ValueKey('today-open-second'));
    final third = find.byKey(const ValueKey('today-open-third'));
    expect(find.text('Offene Rückmeldungen'), findsOneWidget);
    expect(find.byKey(const ValueKey('today-open-fifth')), findsNothing);
    await tester.tap(find.text('+ 1 weitere im Plan'));
    expect(plans, 1);

    await tester.tap(
      find.descendant(of: second, matching: find.text('Bin dabei')),
    );
    await tester.pumpAndSettle();
    expect(
      [server.actionBodies.last['eventId'], server.actionBodies.last['status']],
      ['second', 'yes'],
    );
    expect(find.text('Zusage gespeichert'), findsOneWidget);
    expect(second, findsNothing);

    await tester.tap(
      find.descendant(of: third, matching: find.text('Kann nicht')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Absagen'));
    // The shared sheet waits briefly before it lets go of its text field.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      [server.actionBodies.last['eventId'], server.actionBodies.last['status']],
      ['third', 'no'],
    );
    expect(find.text('Absage gespeichert'), findsOneWidget);
    expect(third, findsNothing);
    // The next event itself is still waiting on its large card.
    expect(find.text('Bist du dabei?'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('an open poll can be voted in from its preview', (tester) async {
    addTearDown(tester.view.reset);
    final server = TestServer()
      ..data['polls'] = [
        _poll(),
        {..._poll(), 'id': 'second', 'title': 'Welches Datum?'},
      ];
    // Keep the vote on the fake server, which only records actions.
    server.override = (request) {
      if (request.url.path.contains('/actions') &&
          request.body.contains('poll.vote')) {
        (server.data['polls'] as List).first['choice'] = 'b';
      }
      return null;
    };
    final controller = server.controller();
    await signIn(controller);
    await _pump(tester, controller);
    expect(find.text('+ 1 weitere Abstimmung'), findsOneWidget);
    await tester.tap(find.text('Kleine Bühne'));
    await tester.pumpAndSettle();
    final body = server.actionBodies.last;
    expect(
      [body['action'], body['pollId'], body['optionId']],
      ['poll.vote', 'poll', 'b'],
    );
    expect(find.text('Stimme gespeichert'), findsOneWidget);
    // The second poll now leads, without a further hint.
    expect(find.text('Welches Datum?'), findsOneWidget);
    expect(find.text('+ 1 weitere Abstimmung'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('admins see new registrations among the open items', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final server = TestServer()
      ..data['pendingAccounts'] = [
        {'uid': 'new', 'status': 'pending', 'identityReady': true},
        {'uid': 'other', 'status': 'pending', 'identityReady': true},
      ];
    final controller = server.controller();
    await signIn(controller);
    await _pump(tester, controller);
    final tile = find.byKey(const ValueKey('today-registrations'));
    expect(
      find.descendant(of: tile, matching: find.text('2 neue Registrierungen')),
      findsOneWidget,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final screen = tester.widget<AccountsAdminScreen>(
      find.byType(AccountsAdminScreen),
    );
    // The waiting registrations stand on top of the whole list.
    expect(screen.initialStatus, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('cards show weekday, date and place', (tester) async {
    addTearDown(tester.view.reset);
    final server = TestServer()
      ..data['events'] = [
        _event('next', 'Szenenprobe', 2),
        _event('later', 'Durchlaufprobe', 5),
      ]
      ..data['attendanceByEvent'] = {};
    final controller = server.controller();
    await signIn(controller);
    await _pump(tester, controller);
    final next = controller.events.firstWhere((e) => e.id == 'next');
    final day = DateFormat('EEE d. MMM', 'de').format(next.startsAt!);
    expect(find.textContaining(day), findsOneWidget);
    // Answering keeps the slot on top while it collapses to one row.
    await tester.tap(find.text('Bin dabei').first);
    await tester.pumpAndSettle();
    final compact = find.byKey(const ValueKey('today-next-compact'));
    expect(
      find.descendant(of: compact, matching: find.text('Kolpingheim')),
      findsOneWidget,
    );
    expect(
      _top(tester, compact),
      lessThan(_top(tester, find.byKey(const ValueKey('today-open-later')))),
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
