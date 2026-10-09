import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/messages.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

JsonMap message(
  String id,
  String title, {
  bool read = false,
  String createdAt = '2026-09-12T08:00:00Z',
  JsonMap extra = const {},
}) => {
  'id': id,
  'title': title,
  'body': 'Text zu $title',
  'audience': 'all',
  'roleIds': <String>[],
  'productionIds': <String>[],
  'recipientPersonIds': <int>[],
  'authorId': 4,
  'authorName': 'Kim Kulisse',
  'createdAt': createdAt,
  'read': read,
  ...extra,
};

Future<(TestServer, dynamic)> setUpController(
  WidgetTester tester, {
  List<JsonMap> messages = const [],
}) async {
  tester.view.physicalSize = const Size(420, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = TestServer();
  server.data['messages'] = messages;
  server.data['capabilities'] = {'pushConfigured': true};
  final controller = server.controller();
  await signIn(controller);
  return (server, controller);
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('message times read relative to now', () {
    final now = DateTime(2026, 9, 12, 12);
    expect(messageTime(DateTime(2026, 9, 12, 8, 5), now), 'Heute, 08:05');
    expect(messageTime(DateTime(2026, 9, 11, 20), now), 'Gestern, 20:00');
    expect(messageTime(DateTime(2026, 9, 8, 9), now), 'Dienstag, 09:00');
    expect(messageTime(DateTime(2026, 7, 1, 9), now), '1. Juli');
    expect(messageTime(DateTime(2025, 7, 1, 9), now), '1. Juli 2025');
  });

  testWidgets(
    'the messages tab groups by date, filters unread and marks all read',
    (tester) async {
      final (server, controller) = await setUpController(
        tester,
        messages: [
          message('m1', 'Kostümprobe'),
          message(
            'm2',
            'Sommerfest',
            read: true,
            createdAt: '2026-08-01T10:00:00Z',
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(
            body: MessagesScreen(controller: controller, embedded: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mitteilungen.'), findsOneWidget);
      expect(find.text('1 ungelesene Mitteilung'), findsOneWidget);
      expect(find.text('HEUTE'), findsOneWidget);
      expect(find.text('FRÜHER'), findsOneWidget);
      await tester.tap(find.text('Ungelesen · 1'));
      await tester.pumpAndSettle();
      expect(find.text('Kostümprobe'), findsOneWidget);
      expect(find.text('Sommerfest'), findsNothing);
      await tester.tap(find.byTooltip('Alle als gelesen markieren'));
      await tester.pumpAndSettle();
      expect(
        server.actionBodies.map((b) => b['action']),
        contains('message.readAll'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('admins see the read status, remind the rest and open links', (
    tester,
  ) async {
    final m = message(
      'm1',
      'Anmeldung',
      read: true,
      extra: {
        'link': 'https://example.com/formular',
        'linkLabel': 'Zum Formular',
        'recipientIds': [1, 2, 3],
        'readerIds': [1],
      },
    );
    final (server, controller) = await setUpController(tester, messages: [m]);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: MessageDetailScreen(controller: controller, message: m),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Zum Formular'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('1 von 3 gelesen'), findsOneWidget);
    expect(find.text('Robin Spielmann, Toni Lichtblick'), findsOneWidget);
    await tester.ensureVisible(find.text('2 Personen per Push erinnern'));
    await tester.tap(find.text('2 Personen per Push erinnern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {'action': 'message.remind', 'id': 'm1'});
  });

  testWidgets('the composer validates links and sends roles with the link', (
    tester,
  ) async {
    final (server, controller) = await setUpController(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: MessageComposerScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Betreff'), 'Fest');
    await tester.enterText(
      find.widgetWithText(TextField, 'Nachricht'),
      'Bitte eintragen',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Link (optional)'),
      'example.com',
    );
    await tester.pump();
    expect(
      find.text('Bitte einen vollständigen Link mit https:// angeben.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Link (optional)'),
      'https://example.com/fest',
    );
    await tester.pump();
    expect(find.text('Erreicht alle 5 aktiven Personen.'), findsOneWidget);
    await tester.tap(find.text('Auswahl'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Technik'));
    await tester.tap(find.widgetWithText(FilterChip, 'Technik'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Erreicht 1 Person: Technik'), findsOneWidget);
    await tester.ensureVisible(find.text('Mitteilung veröffentlichen'));
    await tester.tap(find.text('Mitteilung veröffentlichen'));
    await tester.pumpAndSettle();
    final sent = server.actionBodies.last;
    expect(sent['action'], 'message.send');
    expect(sent['link'], 'https://example.com/fest');
    expect(sent['audience'], 'selected');
    expect(sent['roleIds'], ['role-3']);
  });

  testWidgets('admins send a custom push after confirming the reach', (
    tester,
  ) async {
    final (server, controller) = await setUpController(tester);
    server.override = (request) => request.url.path.contains('/admin/push')
        ? Future.value(
            jsonResponse({
              'configured': true,
              'devices': [{}, {}],
              'jobs': [
                {
                  'title': 'Probe fällt aus',
                  'status': 'accepted_by_provider',
                  'manual': true,
                  'createdAt': '2026-09-12T09:00:00Z',
                  'recipientPersonIds': [1, 2],
                  'accepted': 3,
                },
              ],
            }),
          )
        : null;
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: PushAdminScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Später');
    await tester.enterText(
      find.widgetWithText(TextField, 'Text'),
      'Probe beginnt 30 Minuten später.',
    );
    await tester.pump();
    // Field and lock-screen preview.
    expect(find.text('Probe beginnt 30 Minuten später.'), findsNWidgets(2));
    final send = find.widgetWithText(FilledButton, 'Push senden');
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('Push an 5 Personen senden?'), findsOneWidget);
    await tester.tap(find.text('Senden'));
    await tester.pumpAndSettle();
    final sent = server.actionBodies.last;
    expect(sent['action'], 'push.send');
    expect(sent['title'], 'Später');
    expect(sent['audience'], 'all');
    await tester.scrollUntilVisible(
      find.text('Probe fällt aus'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.textContaining(
        'Eigener Push · Zugestellt an Versanddienst · an 2 Personen · 3 Geräte',
      ),
      findsOneWidget,
    );
  });
}
