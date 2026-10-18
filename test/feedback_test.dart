import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/deep_links.dart';
import 'package:theater_app/app/platform/pwa_install.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/app/shell/app_section.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/app_version.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/admin/admin.dart';
import 'package:theater_app/features/feedback/feedback.dart';
import 'package:theater_app/features/me/me.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

TestServer _server({bool feature = true, bool tickets = true}) {
  final server = TestServer();
  server.data['capabilities'] = {
    if (feature) 'features': ['feedback', if (tickets) 'feedbackTickets'],
  };
  return server;
}

void _size(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpMyArea(WidgetTester tester, AppController controller) async {
  _size(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: Scaffold(
        body: MyAreaScreen(
          controller: controller,
          devices: DeviceServices(
            controller,
            onTarget: (_) {},
            onForegroundMessage: (_) {},
          ),
          installation: PwaInstallation(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _at(Duration ago) => fixedNow.subtract(ago).toUtc().toIso8601String();

JsonMap _message(
  String id,
  String text, {
  bool admin = false,
  String name = 'Kim Beispiel',
  Duration ago = const Duration(hours: 2),
}) => {
  'id': id,
  'from': admin ? 'admin' : 'member',
  'text': text,
  'at': _at(ago),
  'author': {'personId': admin ? 1 : 7, 'name': name},
};

/// A ticket as the server sends it; [legacy] leaves out the conversation
/// like servers before the tickets.
JsonMap _entry(
  String id, {
  String message = 'Bitte einen dunklen Modus für die Probe.',
  String category = 'idea',
  String status = 'open',
  int version = 1,
  String name = 'Kim Beispiel',
  List<JsonMap>? answers,
  int unread = 0,
  bool legacy = false,
}) => {
  'id': id,
  'message': message,
  'category': category,
  'status': status,
  'createdAt': _at(const Duration(hours: 2)),
  'updatedAt': fixedNow.toUtc().toIso8601String(),
  'version': version,
  'appVersion': '0.7.0',
  'platform': 'android',
  'author': {'uid': 'kim', 'personId': 7, 'name': name},
  if (!legacy) ...{
    'messages': [_message('$id-0', message, name: name), ...?answers],
    'lastActivityAt': _at(const Duration(hours: 1)),
    'unread': unread,
    'closedBy': status == 'closed' ? {'role': 'admin', 'name': 'Robin'} : null,
  },
};

Future<void> _pump(WidgetTester tester, Widget page) async {
  _size(tester);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: page),
  );
  await tester.pumpAndSettle();
}

ButtonStyleButton _button(WidgetTester tester, String label) =>
    tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('the form is offered only when the server supports it', (
    tester,
  ) async {
    final without = _server(feature: false).controller();
    addTearDown(without.dispose);
    await signIn(without);
    await _pumpMyArea(tester, without);
    expect(find.text('Feedback geben'), findsNothing);

    final demo = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
      clock: () => fixedNow,
    );
    addTearDown(demo.dispose);
    await demo.startDemo();
    await _pumpMyArea(tester, demo);
    expect(find.text('Feedback geben'), findsNothing);

    final controller = _server().controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await _pumpMyArea(tester, controller);
    expect(find.text('Feedback geben'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('members send feedback with category, version and platform', (
    tester,
  ) async {
    final server = _server();
    final sent = <JsonMap>[];
    final reply = Completer<http.Response>();
    server.override = (request) {
      if (request.method == 'POST' && _path(request).endsWith('/feedback')) {
        sent.add(jsonMap(jsonDecode(request.body)));
        return reply.future;
      }
      return null;
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await _pumpMyArea(tester, controller);

    await tester.tap(find.text('Feedback geben'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackFormScreen), findsOneWidget);
    FilledButton sendButton() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Feedback senden'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    // Nothing to send yet.
    expect(sendButton().onPressed, isNull);

    await tester.tap(find.text('Fehler'));
    await tester.enterText(
      find.byKey(const ValueKey('feedback-message')),
      '  Der Kalender springt beim Wischen zurück.  ',
    );
    await tester.pump();
    await tester.tap(find.text('Feedback senden'));
    await tester.pump();
    expect(find.text('Wird gesendet …'), findsOneWidget);
    expect(sent.single, {
      'message': 'Der Kalender springt beim Wischen zurück.',
      'category': 'bug',
      'appVersion': appVersion,
      'platform': 'android',
    });

    reply.complete(jsonResponse({'ok': true, 'id': 'fb-1'}));
    await tester.pumpAndSettle();
    expect(find.text('Danke für dein Feedback!'), findsOneWidget);
    // The sent text is no unsaved input: leaving does not ask.
    await tester.tap(find.text('Fertig'));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackFormScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a rejected submission keeps the text and shows the reason', (
    tester,
  ) async {
    final server = _server();
    server.override = (request) =>
        request.method == 'POST' && _path(request).endsWith('/feedback')
        ? Future.value(
            jsonResponse({
              'error':
                  'Du hast gerade schon viel Feedback gesendet. '
                  'Bitte versuche es später erneut.',
            }, 429),
          )
        : null;
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    _size(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: FeedbackFormScreen(controller: controller),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('feedback-message')),
      'Mehr Platz für Notizen.',
    );
    await tester.pump();
    await tester.tap(find.text('Feedback senden'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Du hast gerade schon viel Feedback gesendet. '
        'Bitte versuche es später erneut.',
      ),
      findsOneWidget,
    );
    expect(find.text('Mehr Platz für Notizen.'), findsOneWidget);
    expect(find.text('Danke für dein Feedback!'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the admin hub links the feedback list only with the feature', (
    tester,
  ) async {
    _size(tester);
    for (final feature in [false, true]) {
      final controller = _server(feature: feature).controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: ManagementScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Ideen und Fehlermeldungen der Mitglieder'),
        feature ? findsOneWidget : findsNothing,
      );
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('admins see tickets by status and kind, new ones marked', (
    tester,
  ) async {
    final server = _server();
    final entries = [
      _entry('3', message: 'Die Szenenliste lädt nicht.', category: 'bug'),
      _entry(
        '2',
        message: 'Kalender im Querformat?',
        name: 'Alex',
        answers: [
          _message('2-1', 'Danke, notiert.', admin: true, name: 'Robin'),
          _message('2-2', 'Und auf dem Tablet?', name: 'Alex'),
        ],
      ),
      _entry(
        '1',
        message: 'Mehr Farben',
        status: 'answered',
        answers: [_message('1-1', 'Gute Idee!', admin: true, name: 'Robin')],
      ),
      _entry(
        '0',
        message: 'Erledigtes',
        category: 'other',
        status: 'closed',
        answers: [_message('0-1', 'Erledigt.', admin: true, name: 'Robin')],
      ),
    ];
    server.override = (request) =>
        request.method == 'GET' && _path(request).endsWith('/admin/feedback')
        ? Future.value(jsonResponse({'feedback': entries}))
        : null;
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await _pump(tester, FeedbackAdminScreen(controller: controller));

    // Open tickets first: a new one and one waiting for an answer again.
    expect(find.text('Offen (2)'), findsOneWidget);
    expect(find.text('Wartet auf Rückmeldung (1)'), findsOneWidget);
    expect(find.text('Geschlossen (1)'), findsOneWidget);
    expect(find.text('Alle (4)'), findsOneWidget);
    expect(
      find.text('1 neues Feedback ist noch unbeantwortet.'),
      findsOneWidget,
    );
    expect(find.text('Neu'), findsOneWidget);
    expect(find.text('Wartet auf Antwort'), findsOneWidget);
    expect(find.text('Die Szenenliste lädt nicht.'), findsOneWidget);
    expect(find.text('Zuletzt: Und auf dem Tablet?'), findsOneWidget);
    expect(
      find.textContaining('3 Nachrichten · Antwort von Robin'),
      findsOneWidget,
    );
    expect(find.text('Mehr Farben'), findsNothing);

    await tester.tap(find.widgetWithText(FilterChip, 'Fehler'));
    await tester.pumpAndSettle();
    expect(find.text('Offen (1)'), findsOneWidget);
    expect(find.text('Kalender im Querformat?'), findsNothing);

    await tester.tap(find.text('Alle Arten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wartet auf Rückmeldung (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Mehr Farben'), findsOneWidget);
    expect(find.text('Die Szenenliste lädt nicht.'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('admins answer a ticket and may close it only afterwards', (
    tester,
  ) async {
    final server = _server();
    var ticket = _entry('7', message: 'Die Szenenliste lädt nicht.');
    final requests = <(String, String, JsonMap)>[];
    server.override = (request) {
      final path = _path(request);
      if (!path.contains('/admin/feedback')) return null;
      final body = request.body.isEmpty
          ? <String, Object?>{}
          : jsonMap(jsonDecode(request.body));
      requests.add((request.method, path.split('/v1').last, body));
      if (request.method == 'POST') {
        ticket = _entry(
          '7',
          message: 'Die Szenenliste lädt nicht.',
          status: 'answered',
          version: 2,
          answers: [
            _message(
              '7-1',
              textValue(body['text']),
              admin: true,
              name: 'Robin',
            ),
          ],
        );
      } else if (request.method == 'PUT') {
        ticket = {
          ...ticket,
          'status': 'closed',
          'version': 3,
          'closedBy': {'role': 'admin', 'name': 'Robin'},
        };
      }
      return Future.value(jsonResponse({'feedback': ticket}));
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await _pump(
      tester,
      FeedbackTicketScreen(controller: controller, ticketId: '7', admin: true),
    );

    expect(find.text('Die Szenenliste lädt nicht.'), findsOneWidget);
    expect(find.text('Version 0.7.0 · Android'), findsOneWidget);
    expect(_button(tester, 'Feedback schließen').onPressed, isNull);
    expect(
      find.text(
        'Schließen geht erst, nachdem die Theaterleitung geantwortet hat.',
      ),
      findsOneWidget,
    );
    expect(_button(tester, 'Antworten').onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('feedback-reply')),
      '  Ist behoben, bitte neu laden.  ',
    );
    await tester.pump();
    await tester.tap(find.text('Antworten'));
    await tester.pumpAndSettle();
    expect(requests.last.$1, 'POST');
    expect(requests.last.$2, '/admin/feedback/7/messages');
    expect(requests.last.$3, {'text': 'Ist behoben, bitte neu laden.'});
    expect(find.text('Antwort gesendet.'), findsOneWidget);
    // Admins see which of them answered.
    expect(find.textContaining('Robin · '), findsOneWidget);
    expect(find.text('Wartet auf Rückmeldung'), findsOneWidget);

    await tester.tap(find.text('Feedback schließen'));
    await tester.pumpAndSettle();
    expect(requests.last.$1, 'PUT');
    expect(requests.last.$3, {'status': 'closed', 'version': 2});
    expect(find.text('Geschlossen'), findsOneWidget);
    expect(find.textContaining('Geschlossen von Robin'), findsOneWidget);
    expect(find.text('Wieder öffnen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a version conflict while closing reloads the ticket', (
    tester,
  ) async {
    final server = _server();
    var loads = 0;
    server.override = (request) {
      final path = _path(request);
      if (request.method == 'GET' && path.endsWith('/admin/feedback/1')) {
        loads++;
        return Future.value(
          jsonResponse({
            'feedback': _entry(
              '1',
              status: 'answered',
              version: loads,
              answers: [_message('1-1', 'Antwort', admin: true)],
            ),
          }),
        );
      }
      if (request.method == 'PUT') {
        return Future.value(
          jsonResponse({
            'error': 'Das Feedback wurde inzwischen geändert.',
            'code': 'version_conflict',
          }, 409),
        );
      }
      return null;
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await _pump(
      tester,
      FeedbackTicketScreen(controller: controller, ticketId: '1', admin: true),
    );
    await tester.tap(find.text('Feedback schließen'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(
      find.text(
        'Dieses Feedback wurde inzwischen geändert. Es wurde neu geladen.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed first load offers a retry', (tester) async {
    final server = _server();
    var fail = true;
    server.override = (request) => _path(request).endsWith('/admin/feedback')
        ? Future.value(
            fail
                ? jsonResponse({'error': 'Server nicht erreichbar.'}, 503)
                : jsonResponse({'feedback': <JsonMap>[]}),
          )
        : null;
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await _pump(tester, FeedbackAdminScreen(controller: controller));
    expect(find.text('Feedback nicht geladen'), findsOneWidget);
    expect(find.text('Server nicht erreichbar.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Erneut versuchen'));
    await tester.pumpAndSettle();
    expect(find.text('Noch kein Feedback'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('members follow their tickets and see new answers marked', (
    tester,
  ) async {
    final server = _server();
    var answered = _entry(
      '5',
      message: 'Die Probe am Montag fehlt.',
      category: 'bug',
      status: 'answered',
      version: 2,
      unread: 1,
      answers: [
        _message(
          '5-1',
          'Danke, ist korrigiert.',
          admin: true,
          name: 'Robin',
          ago: const Duration(hours: 1),
        ),
      ],
    );
    final waiting = _entry('4', message: 'Mehr Platz für Notizen.');
    final requests = <(String, String, JsonMap)>[];
    server.override = (request) {
      final path = _path(request).split('/v1').last;
      if (!path.startsWith('/feedback')) return null;
      final body = request.body.isEmpty
          ? <String, Object?>{}
          : jsonMap(jsonDecode(request.body));
      requests.add((request.method, path, body));
      if (path == '/feedback') {
        return Future.value(
          jsonResponse({
            'tickets': [answered, waiting],
            'unread': intValue(answered['unread']) > 0 ? 1 : 0,
          }),
        );
      }
      if (path == '/feedback/5/read') {
        answered = {...answered, 'unread': 0};
      } else if (path == '/feedback/5/messages') {
        answered = {
          ...answered,
          'status': 'open',
          'version': 3,
          'messages': [
            ...jsonList(answered['messages']),
            _message('5-2', textValue(body['text']), ago: Duration.zero),
          ],
        };
      } else if (path == '/feedback/4') {
        return Future.value(jsonResponse({'ticket': waiting}));
      }
      return Future.value(jsonResponse({'ticket': answered}));
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await _pump(tester, FeedbackFormScreen(controller: controller));

    // The form leads to the own tickets and shows the unread answer.
    expect(find.text('1 neue Antwort der Theaterleitung'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-feedback-link')));
    await tester.pumpAndSettle();
    expect(find.byType(MyFeedbackScreen), findsOneWidget);
    expect(find.text('Neue Antwort'), findsOneWidget);
    expect(find.text('Beantwortet'), findsOneWidget);
    expect(find.text('Antwort: Danke, ist korrigiert.'), findsOneWidget);
    expect(find.text('Offen'), findsOneWidget);

    // A waiting ticket cannot be closed yet, and the page says why.
    await tester.tap(find.text('Mehr Platz für Notizen.'));
    await tester.pumpAndSettle();
    expect(_button(tester, 'Erledigt, schließen').onPressed, isNull);
    expect(
      find.text('Schließen geht, sobald die Theaterleitung geantwortet hat.'),
      findsOneWidget,
    );
    expect(requests.where((r) => r.$2 == '/feedback/4/read'), isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Opening the answered ticket marks the answer as read.
    await tester.tap(find.text('Die Probe am Montag fehlt.'));
    await tester.pumpAndSettle();
    expect(
      requests.any((r) => r.$1 == 'PUT' && r.$2 == '/feedback/5/read'),
      isTrue,
    );
    expect(find.textContaining('Theaterleitung · Robin · '), findsOneWidget);
    expect(find.textContaining('Du · '), findsOneWidget);
    expect(_button(tester, 'Erledigt, schließen').onPressed, isNotNull);

    await tester.enterText(
      find.byKey(const ValueKey('feedback-reply')),
      'Super, danke!',
    );
    await tester.pump();
    await tester.tap(find.text('Nachricht senden'));
    await tester.pumpAndSettle();
    expect(requests.last.$2, '/feedback/5/messages');
    expect(requests.last.$3, {'text': 'Super, danke!'});
    expect(find.text('Super, danke!'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Neue Antwort'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an older server keeps feedback working and explains the rest', (
    tester,
  ) async {
    final server = _server(tickets: false);
    final updates = <JsonMap>[];
    server.override = (request) {
      final path = _path(request);
      if (request.method == 'GET' && path.endsWith('/admin/feedback')) {
        return Future.value(
          jsonResponse({
            'feedback': [_entry('1', status: 'new', legacy: true)],
          }),
        );
      }
      if (request.method == 'PUT' && path.endsWith('/admin/feedback/1')) {
        updates.add(jsonMap(jsonDecode(request.body)));
        return Future.value(
          jsonResponse({
            'feedback': _entry('1', status: 'done', version: 2, legacy: true),
          }),
        );
      }
      if (path.contains('/feedback')) {
        return Future.value(jsonResponse({'error': 'not found'}, 404));
      }
      return null;
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);

    await _pump(tester, FeedbackFormScreen(controller: controller));
    expect(
      find.text(
        'Antworten der Theaterleitung gibt es nach dem nächsten Server-Update.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('my-feedback-link')));
    await tester.pumpAndSettle();
    expect(find.text('Noch nicht verfügbar'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, FeedbackAdminScreen(controller: controller));
    expect(find.text('Neu'), findsOneWidget);
    await tester.tap(find.text('Bitte einen dunklen Modus für die Probe.'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feedback-reply')), findsNothing);
    expect(
      find.text(
        'Antworten auf Feedback gibt es nach dem nächsten Server-Update.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Feedback schließen'));
    await tester.pumpAndSettle();
    expect(updates.single, {'status': 'done', 'version': 1});
    expect(find.text('Geschlossen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('feedback pushes open the matching ticket view', (tester) async {
    expect(AppTarget.fromData({'feedbackId': 'f1'})?.kind, 'feedback');
    expect(
      AppTarget.fromData({'adminFeedbackId': 'f1'})?.kind,
      'admin-feedback',
    );
    expect(
      AppTarget.fromUri(Uri.parse('theaterapp://app/admin-feedback/f1'))?.id,
      'f1',
    );
    final server = _server();
    server.override = (request) => _path(request).contains('/feedback/f1')
        ? Future.value(
            jsonResponse({'feedback': _entry('f1'), 'ticket': _entry('f1')}),
          )
        : null;
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    _size(tester);
    final navigator = GlobalKey<NavigatorState>();
    final messenger = GlobalKey<ScaffoldMessengerState>();
    final selection = ValueNotifier(AppSection.today.index);
    addTearDown(selection.dispose);
    await tester.pumpWidget(
      AppNavigationScope(
        selection: selection,
        controller: controller,
        child: MaterialApp(
          navigatorKey: navigator,
          scaffoldMessengerKey: messenger,
          home: const Scaffold(body: Text('Start')),
        ),
      ),
    );
    final router = DeepLinkRouter(
      controller: controller,
      navigator: navigator,
      messenger: messenger,
      isMounted: () => true,
    );
    for (final (data, admin, section) in [
      ({'adminFeedbackId': 'f1'}, true, AppSection.admin),
      ({'feedbackId': 'f1'}, false, AppSection.me),
    ]) {
      router.handle(AppTarget.fromData(data)!);
      await tester.pumpAndSettle();
      final page = tester.widget<FeedbackTicketScreen>(
        find.byType(FeedbackTicketScreen),
      );
      expect((page.ticketId, page.admin), ('f1', admin));
      expect(selection.value, section.index);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
