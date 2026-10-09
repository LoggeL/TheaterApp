import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/ui/messages.dart';
import 'package:theater_app/ui/theme.dart';
import 'package:theater_app/ui/today.dart';

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

/// A start page with an answered next event, one unread and one read
/// message and an already voted poll.
TestServer _handledServer() => TestServer()
  ..data['events'] = [
    _event('next', 'Szenenprobe', 2),
    _event('later', 'Durchlaufprobe', 5),
  ]
  ..data['attendanceByEvent'] = {'next': 'yes'}
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
              onPlan: () {},
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
      lessThan(_top(tester, find.text('Als Nächstes'))),
    );
    expect(
      _top(tester, find.text('Als Nächstes')),
      lessThan(_top(tester, find.text('Dein Drehbuch'))),
    );
    expect(
      _top(tester, find.text('Dein Drehbuch')),
      lessThan(_top(tester, voted)),
    );

    // Reading it moves the messages into the collapsed section.
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
    final read = find.byKey(const ValueKey('today-messages-read'));
    expect(read, findsOneWidget);
    expect(_top(tester, next), lessThan(_top(tester, read)));
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
      find.text('Jetzt abstimmen'),
      find.text('Als Nächstes'),
      find.text('Dein Drehbuch'),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(_top(tester, order[i - 1]), lessThan(_top(tester, order[i])));
    }
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
      lessThan(_top(tester, find.text('Als Nächstes'))),
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
