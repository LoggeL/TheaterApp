import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/platform/pwa_install.dart';
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

TestServer _server({bool feature = true}) {
  final server = TestServer();
  server.data['capabilities'] = {
    if (feature) 'features': ['feedback'],
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

JsonMap _entry(
  String id, {
  String message = 'Bitte einen dunklen Modus für die Probe.',
  String category = 'idea',
  String status = 'new',
  int version = 1,
  String name = 'Kim Beispiel',
}) => {
  'id': id,
  'message': message,
  'category': category,
  'status': status,
  'createdAt': fixedNow
      .subtract(const Duration(hours: 2))
      .toUtc()
      .toIso8601String(),
  'updatedAt': fixedNow.toUtc().toIso8601String(),
  'version': version,
  'appVersion': '0.7.0',
  'platform': 'android',
  'author': {'uid': 'kim', 'personId': 7, 'name': name},
};

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

  testWidgets('admins read feedback and mark it as done or open again', (
    tester,
  ) async {
    final server = _server();
    final entries = [
      _entry('2', message: 'Die Szenenliste lädt nicht.', category: 'bug'),
      _entry('1', status: 'done', version: 3, name: 'Alex'),
    ];
    final updates = <(String, JsonMap)>[];
    server.override = (request) {
      final path = _path(request);
      if (request.method == 'GET' && path.endsWith('/admin/feedback')) {
        return Future.value(jsonResponse({'feedback': entries}));
      }
      if (request.method == 'PUT' && path.contains('/admin/feedback/')) {
        final id = path.split('/').last;
        final body = jsonMap(jsonDecode(request.body));
        updates.add((id, body));
        final entry = entries.firstWhere((e) => e['id'] == id);
        entry['status'] = body['status'];
        entry['version'] = intValue(entry['version']) + 1;
        return Future.value(jsonResponse({'feedback': entry}));
      }
      return null;
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    _size(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: FeedbackAdminScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // Open feedback first, with author, kind, version and platform.
    expect(find.text('Offen (1)'), findsOneWidget);
    expect(find.text('Erledigt (1)'), findsOneWidget);
    expect(find.text('Die Szenenliste lädt nicht.'), findsOneWidget);
    expect(find.textContaining('Kim Beispiel · '), findsOneWidget);
    expect(find.text('Version 0.7.0 · Android'), findsOneWidget);
    expect(find.text('Fehler'), findsOneWidget);
    expect(find.text('Alex'), findsNothing);

    await tester.tap(find.text('Als erledigt markieren'));
    await tester.pumpAndSettle();
    expect(updates.single.$1, '2');
    expect(updates.single.$2, {'status': 'done', 'version': 1});
    expect(find.text('Als erledigt markiert.'), findsOneWidget);
    expect(find.text('Alles erledigt'), findsOneWidget);

    await tester.tap(find.text('Alle (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Wieder öffnen'), findsNWidgets(2));
    await tester.tap(find.text('Wieder öffnen').last);
    await tester.pumpAndSettle();
    expect(updates.last.$1, '1');
    expect(updates.last.$2, {'status': 'new', 'version': 3});
    expect(find.text('Offen (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a version conflict reloads the list', (tester) async {
    final server = _server();
    var loads = 0;
    server.override = (request) {
      final path = _path(request);
      if (request.method == 'GET' && path.endsWith('/admin/feedback')) {
        loads++;
        return Future.value(
          jsonResponse({
            'feedback': [
              _entry('1', status: loads > 1 ? 'done' : 'new', version: loads),
            ],
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
    _size(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: FeedbackAdminScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Als erledigt markieren'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(
      find.text(
        'Dieses Feedback wurde inzwischen geändert. Die Liste wurde neu geladen.',
      ),
      findsOneWidget,
    );
    expect(find.text('Erledigt (1)'), findsOneWidget);
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
    _size(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: FeedbackAdminScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Feedback nicht geladen'), findsOneWidget);
    expect(find.text('Server nicht erreichbar.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Erneut versuchen'));
    await tester.pumpAndSettle();
    expect(find.text('Noch kein Feedback'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
