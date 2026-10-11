import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/messages/messages.dart';
import 'package:theater_app/features/polls/polls.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;
import 'messages_test.dart' show message;

/// A server that signs in as [role] linked to the person [personId].
TestServer serverAs({String role = 'admin', int? personId}) {
  final server = TestServer();
  JsonMap user() => {...server.user, 'role': role, 'personId': personId};
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (path.endsWith('/auth/login')) {
      return Future.value(
        jsonResponse({
          'token': server.token,
          'expiresAt': '2027-01-01T00:00:00Z',
          'user': user(),
        }),
      );
    }
    if (path.endsWith('/snapshot') && !server.offline) {
      return Future.value(jsonResponse({...server.data, 'user': user()}));
    }
    return null;
  };
  return server;
}

JsonMap poll(
  String id,
  String title, {
  List<String> roleIds = const [],
  List<int> personIds = const [],
  String? choice,
  bool closed = false,
  String? closesAt,
}) => {
  'id': id,
  'title': title,
  'roleIds': roleIds,
  'personIds': personIds,
  'choice': choice,
  'closed': closed,
  'closesAt': closesAt,
  'options': [
    {'id': 'a', 'label': 'Ja', 'votes': choice == null ? 0 : 1},
    {'id': 'b', 'label': 'Nein', 'votes': 0},
  ],
};

Future<AppController> signedIn(
  WidgetTester tester,
  TestServer server, {
  Size size = const Size(420, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  server.data['capabilities'] = {'pushConfigured': true};
  final controller = server.controller();
  await signIn(controller);
  addTearDown(controller.dispose);
  return controller;
}

Widget app(Widget home) =>
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home);

/// A start page with a button that opens [screen], so back can be tested.
Widget launcher(Widget screen) => app(
  Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => screen),
          ),
          child: const Text('Öffnen'),
        ),
      ),
    ),
  ),
);

Future<void> goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('unread messages', () {
    const member = AppUser(
      id: 'm',
      name: 'Robin Spielmann',
      email: 'r@example.invalid',
      role: 'member',
      personId: 2,
    );
    const admin = AppUser(
      id: 'a',
      name: 'Alex Bühnenfreund',
      email: 'a@example.invalid',
      role: 'admin',
      personId: 1,
    );

    test('members count every unread message except their own', () {
      expect(messageUnreadFor(member, message('m1', 'Probe')), isTrue);
      expect(
        messageUnreadFor(member, message('m1', 'Probe', read: true)),
        isFalse,
      );
      expect(
        messageUnreadFor(
          member,
          message('m1', 'Probe', extra: {'authorId': 2}),
        ),
        isFalse,
      );
    });

    test('admins only count messages addressed to them', () {
      final toOthers = message(
        'm1',
        'Technik',
        extra: {
          'recipientIds': [2, 3],
        },
      );
      final toMe = message(
        'm2',
        'Alle',
        extra: {
          'recipientIds': [1, 2],
        },
      );
      expect(messageAddressedTo(admin, toOthers), isFalse);
      expect(messageUnreadFor(admin, toOthers), isFalse);
      expect(messageUnreadFor(admin, toMe), isTrue);
      // Without the reach the read flag alone decides.
      expect(messageUnreadFor(admin, message('m3', 'Alt')), isTrue);
    });

    test('authors and admins without a person never count as recipients', () {
      final own = message(
        'm1',
        'Eigene',
        extra: {
          'authorId': 1,
          'recipientIds': [1, 2],
        },
      );
      expect(messageUnreadFor(admin, own), isFalse);
      const unlinked = AppUser(
        id: 'x',
        name: 'Verwaltung',
        email: 'x@example.invalid',
        role: 'admin',
      );
      final toSomeone = message(
        'm2',
        'Hinweis',
        extra: {
          'recipientIds': [2],
        },
      );
      expect(messageUnreadFor(unlinked, toSomeone), isFalse);
    });
  });

  testWidgets('polls to vote skip polls meant for others, also for admins', (
    tester,
  ) async {
    final server = serverAs(personId: 1);
    server.data['polls'] = [
      poll('all', 'Für alle'),
      poll('acting', 'Schauspiel', roleIds: ['role-1']),
      poll('tech', 'Technik', roleIds: ['role-3']),
      poll('named', 'Persönlich', personIds: [1]),
      poll('voted', 'Erledigt', choice: 'a'),
      poll('closed', 'Vorbei', closed: true),
      poll('expired', 'Abgelaufen', closesAt: '2026-09-01T00:00:00Z'),
    ];
    final admin = await signedIn(tester, server);
    expect(pollsToVote(admin).map((p) => p.id), ['all', 'acting', 'named']);

    final memberServer = serverAs(role: 'member', personId: 3);
    memberServer.data['polls'] = [
      poll('tech', 'Technik', roleIds: ['role-3']),
    ];
    final member = await signedIn(tester, memberServer);
    expect(pollsToVote(member).map((p) => p.id), ['tech']);
  });

  testWidgets('the Mitteilungen tab switches between messages and polls', (
    tester,
  ) async {
    final server = TestServer();
    server.data['messages'] = [message('m1', 'Kostümprobe')];
    server.data['polls'] = [poll('p', 'Welche Bühne?')];
    final controller = await signedIn(
      tester,
      server,
      size: const Size(320, 900),
    );
    await tester.pumpWidget(
      app(Scaffold(body: CommunicationScreen(controller: controller))),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mitteilungen.'), findsOneWidget);
    expect(find.text('Kostümprobe'), findsOneWidget);
    expect(find.text('Welche Bühne?'), findsNothing);

    await tester.tap(find.text('Abstimmungen · 1 offen'));
    await tester.pumpAndSettle();
    expect(find.text('Mitteilungen.'), findsOneWidget);
    expect(find.text('1 offene Abstimmung für dich'), findsOneWidget);
    expect(find.text('Welche Bühne?'), findsOneWidget);
    expect(find.text('Noch nicht abgestimmt'), findsOneWidget);
    expect(find.text('Kostümprobe'), findsNothing);

    await tester.tap(find.text('Mitteilungen · 1'));
    await tester.pumpAndSettle();
    expect(find.text('Kostümprobe'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admins create messages, pushes and polls from one button', (
    tester,
  ) async {
    final controller = await signedIn(tester, TestServer());
    await tester.pumpWidget(
      app(Scaffold(body: CommunicationScreen(controller: controller))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('Schreiben'), findsNothing);
    await tester.tap(find.text('Neu'));
    await tester.pumpAndSettle();
    expect(find.text('Mitteilung'), findsOneWidget);
    expect(find.text('Push senden'), findsOneWidget);
    await tester.tap(find.text('Abstimmung'));
    await tester.pumpAndSettle();
    expect(find.byType(PollEditorScreen), findsOneWidget);
  });

  testWidgets('admins see messages to others greyed out and not unread', (
    tester,
  ) async {
    final server = serverAs(personId: 1);
    server.data['messages'] = [
      message(
        'm1',
        'Nur Technik',
        extra: {
          'recipientIds': [3],
          'readerIds': <int>[],
        },
      ),
    ];
    final controller = await signedIn(tester, server);
    await tester.pumpWidget(
      app(
        Scaffold(body: MessagesScreen(controller: controller, embedded: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(unreadMessageCount(controller), 0);
    expect(find.text('Nachrichten der Theaterleitung'), findsOneWidget);
    expect(find.text('Nicht an dich'), findsOneWidget);
    expect(find.byTooltip('Alle als gelesen markieren'), findsNothing);
  });

  testWidgets('leaving the composer with text asks before discarding', (
    tester,
  ) async {
    final controller = await signedIn(tester, TestServer());
    await tester.pumpWidget(
      launcher(MessageComposerScreen(controller: controller)),
    );
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Noch fehlt: Betreff, Nachricht'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Betreff'), 'Fest');
    await tester.pump();
    expect(find.text('Noch fehlt: Nachricht'), findsOneWidget);
    await goBack(tester);
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Weiter bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.byType(MessageComposerScreen), findsOneWidget);
    await goBack(tester);
    await tester.tap(find.text('Verwerfen'));
    await tester.pumpAndSettle();
    expect(find.byType(MessageComposerScreen), findsNothing);
  });

  testWidgets('a push draft continues as a message with its text', (
    tester,
  ) async {
    final server = TestServer();
    server.override = (request) => request.url.path.contains('/admin/push')
        ? Future.value(
            jsonResponse({'configured': true, 'devices': [], 'jobs': []}),
          )
        : null;
    final controller = await signedIn(tester, server);
    await tester.pumpWidget(launcher(PushAdminScreen(controller: controller)));
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Später');
    await tester.enterText(
      find.widgetWithText(TextField, 'Text'),
      'Probe beginnt 30 Minuten später.',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Lieber Mitteilung schreiben'));
    await tester.tap(find.text('Lieber Mitteilung schreiben'));
    await tester.pumpAndSettle();
    expect(find.byType(MessageComposerScreen), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Betreff'))
          .controller!
          .text,
      'Später',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Nachricht'))
          .controller!
          .text,
      'Probe beginnt 30 Minuten später.',
    );
    // The taken-over text still exists in the push draft.
    await goBack(tester);
    expect(find.text('Änderungen verwerfen?'), findsNothing);
    expect(find.byType(PushAdminScreen), findsOneWidget);
    // The push draft itself is guarded.
    await goBack(tester);
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
  });

  testWidgets('the poll editor guards input and confirms saving', (
    tester,
  ) async {
    final server = TestServer();
    final controller = await signedIn(tester, server);
    await tester.pumpWidget(launcher(PollEditorScreen(controller: controller)));
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Beschreibung (optional)'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Frage'),
      'Wann grillen wir?',
    );
    await tester.pump();
    await goBack(tester);
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Weiter bearbeiten'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Antwort 1'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Antwort 1'),
      'Freitag',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Antwort 2'),
      'Samstag',
    );
    final save = find.widgetWithText(FilledButton, 'Speichern');
    await tester.scrollUntilVisible(
      save,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'poll.save');
    expect(find.byType(PollEditorScreen), findsNothing);
    expect(find.text('Abstimmung gespeichert'), findsOneWidget);
  });

  testWidgets('the poll list puts unanswered polls first with one button', (
    tester,
  ) async {
    final server = TestServer();
    server.data['polls'] = [
      poll('voted', 'Schon erledigt', choice: 'a'),
      poll('later', 'Später fällig', closesAt: '2026-12-01T18:00:00Z'),
      poll('soon', 'Bald fällig', closesAt: '2026-10-01T18:00:00Z'),
    ];
    final controller = await signedIn(tester, server);
    await tester.pumpWidget(app(PollsScreen(controller: controller)));
    await tester.pumpAndSettle();
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('Bald fällig'), lessThan(top('Später fällig')));
    expect(top('Später fällig'), lessThan(top('Schon erledigt')));
    expect(find.text('Noch nicht abgestimmt'), findsNWidgets(2));
    expect(find.text('Abgestimmt'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('Neue Abstimmung'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('voting confirms the vote, also while offline', (tester) async {
    final server = TestServer();
    server.data['polls'] = [poll('p', 'Welches Essen?')];
    final controller = await signedIn(tester, server);
    await tester.pumpWidget(
      app(PollDetailScreen(controller: controller, pollId: 'p')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Du kannst deine Stimme bis zum Ende ändern.'),
      findsOneWidget,
    );
    expect(find.text('0 Stimmen'), findsNWidgets(3));
    await tester.tap(find.text('Ja'));
    await tester.pumpAndSettle();
    expect(find.text('Stimme gespeichert'), findsOneWidget);
    ScaffoldMessenger.of(
      tester.element(find.byType(PollDetailScreen)),
    ).removeCurrentSnackBar();
    server.offline = true;
    await tester.tap(find.text('Nein'));
    await tester.pumpAndSettle();
    expect(
      find.text('Stimme vorgemerkt – wird bei Verbindung gesendet'),
      findsOneWidget,
    );
  });

  testWidgets('admins end and reopen a poll from the app bar', (tester) async {
    final server = TestServer();
    server.data['polls'] = [poll('p', 'Welches Essen?')];
    final controller = await signedIn(tester, server);
    await tester.pumpWidget(
      app(PollDetailScreen(controller: controller, pollId: 'p')),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Abstimmung bearbeiten'), findsOneWidget);
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beenden'));
    await tester.pumpAndSettle();
    expect(find.text('Abstimmung beenden?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Beenden'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'poll.close',
      'id': 'p',
      'version': 1,
      'closed': true,
    });
    expect(find.text('Abstimmung beendet'), findsOneWidget);

    server.data['polls'] = [poll('p', 'Welches Essen?', closed: true)];
    await controller.refresh();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wieder öffnen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Die Frist wird entfernt.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Wieder öffnen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['closed'], false);
  });

  testWidgets('a missing poll shows an empty state', (tester) async {
    final controller = await signedIn(tester, TestServer());
    await tester.pumpWidget(
      app(PollDetailScreen(controller: controller, pollId: 'gone')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Abstimmung nicht verfügbar'), findsOneWidget);
    expect(find.byTooltip('Weitere Aktionen'), findsNothing);
  });
}
