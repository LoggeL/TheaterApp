import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/forms/domain/form_presets.dart';
import 'package:theater_app/features/forms/ui/form_editor_screen.dart';
import 'package:theater_app/features/messages/ui/message_composer_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

JsonMap _template() => {
  'id': 'form-rehearsal',
  'version': 4,
  'title': 'Anmeldung zur Probe',
  'description': 'Bitte trage dich ein.',
  'fields': [
    {
      'id': 'participant',
      'type': 'text',
      'label': 'Name der teilnehmenden Person',
      'required': true,
    },
  ],
  'signatureRequired': false,
  'confirmationText': 'Ich bestätige die Angaben in diesem Formular.',
  'archived': false,
};

Future<(TestServer, AppController)> _setup(WidgetTester tester) async {
  tester.view.physicalSize = const Size(460, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = TestServer();
  server.data['capabilities'] = {
    'pushConfigured': false,
    'features': ['forms'],
  };
  server.override = (request) {
    if (request.url.path.endsWith('/forms/templates/')) {
      return Future.value(
        jsonResponse({
          'templates': [_template()],
        }),
      );
    }
    return null;
  };
  final controller = server.controller();
  await signIn(controller);
  addTearDown(controller.dispose);
  return (server, controller);
}

Future<void> _show(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: screen),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectForm(WidgetTester tester) async {
  final picker = find.text('Formular auswählen');
  await tester.ensureVisible(picker);
  await tester.tap(picker);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Anmeldung zur Probe'));
  await tester.pumpAndSettle();
}

void main() {
  test('the rehearsal preset starts fresh without personal answers', () {
    final first = rehearsalWeekendPreset();
    final second = rehearsalWeekendPreset();
    final originalLabel = jsonList(second['fields']).first['label'];
    first['title'] = 'Eigene Anmeldung';
    jsonList(first['fields']).first['label'] = 'Andere Frage';

    expect(second['title'], 'Anmeldung zur Probenfreizeit');
    expect(jsonList(second['fields']).first['label'], originalLabel);
    expect(second['description'], isEmpty);
    expect(second['signatureRequired'], isTrue);
    expect(second['deleteAfter'], isNull);
    expect(
      jsonList(second['fields']).map((field) => field['id']),
      unorderedEquals([
        'participant_name',
        'health_details',
        'health_consent',
        'age_at_event',
        'small_groups',
        'emergency_contact',
        'travel',
        'notes',
      ]),
    );
    final health = jsonMap(
      jsonList(
        second['fields'],
      ).firstWhere((field) => field['id'] == 'health_details'),
    );
    final consent = jsonMap(
      jsonList(
        second['fields'],
      ).firstWhere((field) => field['id'] == 'health_consent'),
    );
    expect(health['type'], 'multiline');
    expect(health['required'], isFalse);
    expect(consent['type'], 'checkbox');
    expect(consent['required'], isTrue);
    expect(second.containsKey('answers'), isFalse);
    expect(second.containsKey('signature'), isFalse);
    expect(jsonEncode(second), isNot(contains('2026')));
  });

  testWidgets('the rehearsal starter requires current event details', (
    tester,
  ) async {
    final (server, controller) = await _setup(tester);
    final inherited = server.override;
    server.override = (request) {
      if (request.url.path.endsWith('/actions/')) {
        final body = jsonMap(jsonDecode(request.body));
        if (body['action'] == 'form.save') {
          server.actionBodies.add(body);
          return Future.value(
            jsonResponse({
              'ok': true,
              'template': {...body, 'id': 'new-rehearsal', 'version': 1},
            }),
          );
        }
      }
      return inherited?.call(request);
    };
    await _show(
      tester,
      FormEditorScreen(
        controller: controller,
        initialDefinition: {
          ...rehearsalWeekendPreset(),
          'deleteAfter': '2026-10-10',
        },
        requireDescription: true,
        requireDeleteAfter: true,
      ),
    );
    final save = find.text('Formular speichern');
    await tester.scrollUntilVisible(
      save,
      450,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.actionBodies, isEmpty);
    // Let the validation SnackBar leave the bottom action area before retrying.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    final details = find.widgetWithText(
      TextFormField,
      'Datum, Ort und Teilnahmebedingungen',
    );
    await tester.scrollUntilVisible(
      details,
      -450,
      scrollable: find.byType(Scrollable).first,
    );
    const description =
        '10. bis 12. März im Gemeindehaus. Teilnahmebeitrag: 20 Euro.';
    await tester.enterText(details, description);
    final title = find.widgetWithText(TextFormField, 'Formularname');
    await tester.scrollUntilVisible(
      title,
      -450,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(title, 'Unsere nächste Probenfreizeit');
    await tester.scrollUntilVisible(
      save,
      450,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();

    final sent = server.actionBodies.single;
    expect(sent['action'], 'form.save');
    expect(sent['title'], 'Unsere nächste Probenfreizeit');
    expect(sent['description'], description);
    expect(sent['signatureRequired'], isTrue);
    expect(sent['deleteAfter'], '2026-10-10');
    expect(jsonList(sent['fields']), hasLength(8));
    expect(sent.containsKey('id'), isFalse);
    expect(sent.containsKey('version'), isFalse);
    expect(sent.containsKey('answers'), isFalse);
    expect(sent.containsKey('signature'), isFalse);
    expect(sent['description'], isNot(contains('2026')));
    expect(controller.outbox, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rehearsal starter cannot save without a deletion date', (
    tester,
  ) async {
    final (server, controller) = await _setup(tester);
    await _show(
      tester,
      FormEditorScreen(
        controller: controller,
        initialDefinition: {
          ...rehearsalWeekendPreset(),
          'description': '10. bis 12. März im Gemeindehaus.',
        },
        requireDescription: true,
        requireDeleteAfter: true,
      ),
    );
    final save = find.text('Formular speichern');
    await tester.scrollUntilVisible(
      save,
      450,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(server.actionBodies, isEmpty);
    expect(controller.outbox, isEmpty);
    expect(find.byType(FormEditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty template cannot be saved', (tester) async {
    final (server, controller) = await _setup(tester);
    await _show(tester, FormEditorScreen(controller: controller));
    final save = find.text('Formular speichern');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.actionBodies, isEmpty);
    expect(controller.pendingCount, 0);
    expect(find.byType(FormEditorScreen), findsOneWidget);
  });

  testWidgets('editing a template sends its revision and stable field IDs', (
    tester,
  ) async {
    final (server, controller) = await _setup(tester);
    final inherited = server.override;
    server.override = (request) {
      if (request.url.path.endsWith('/actions/')) {
        final body = jsonMap(jsonDecode(request.body));
        if (body['action'] == 'form.save') {
          server.actionBodies.add(body);
          return Future.value(
            jsonResponse({
              'ok': true,
              'id': 'form-rehearsal',
              'template': {..._template(), ...body, 'version': 5},
            }),
          );
        }
      }
      return inherited?.call(request);
    };
    await _show(
      tester,
      FormEditorScreen(controller: controller, template: _template()),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Formularname'),
      'Anmeldung zum Wochenende',
    );
    final save = find.text('Formular speichern');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final sent = server.actionBodies.single;
    expect(sent['action'], 'form.save');
    expect(sent['id'], 'form-rehearsal');
    expect(sent['version'], 4);
    expect(sent['title'], 'Anmeldung zum Wochenende');
    expect(jsonMap(jsonList(sent['fields']).single)['id'], 'participant');
    expect(controller.pendingCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the composer sends the selected form and its revision', (
    tester,
  ) async {
    final (server, controller) = await _setup(tester);
    await _show(tester, MessageComposerScreen(controller: controller));
    await tester.enterText(find.widgetWithText(TextField, 'Betreff'), 'Probe');
    await tester.enterText(
      find.widgetWithText(TextField, 'Nachricht'),
      'Bitte meldet euch an.',
    );
    await _selectForm(tester);
    final publish = find.text('Mitteilung veröffentlichen');
    await tester.ensureVisible(publish);
    await tester.tap(publish);
    await tester.pumpAndSettle();
    final sent = server.actionBodies.singleWhere(
      (body) => body['action'] == 'message.send',
    );
    expect(sent['formId'], 'form-rehearsal');
    expect(sent['formVersion'], 4);
    expect(sent['title'], 'Probe');
    expect(controller.pendingCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retrying an unchanged template save reuses its request key', (
    tester,
  ) async {
    final (server, controller) = await _setup(tester);
    final inherited = server.override;
    server.override = (request) {
      if (request.url.path.endsWith('/actions/')) {
        final body = jsonMap(jsonDecode(request.body));
        if (body['action'] == 'form.save') {
          server.actionBodies.add(body);
          server.actionKeys.add(request.headers['Idempotency-Key']!);
          if (server.actionKeys.length == 1) {
            return Future<http.Response>.error(
              http.ClientException('response lost'),
            );
          }
          return Future.value(
            jsonResponse({
              'ok': true,
              'id': 'form-rehearsal',
              'template': {..._template(), ...body, 'version': 5},
            }),
          );
        }
      }
      return inherited?.call(request);
    };
    await _show(
      tester,
      FormEditorScreen(controller: controller, template: _template()),
    );
    final title = find.widgetWithText(TextFormField, 'Formularname');
    await tester.enterText(title, 'Anmeldung zum Wochenende');
    final save = find.text('Formular speichern');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(server.actionKeys, hasLength(1));
    expect(controller.outbox, isEmpty);
    expect(find.byType(FormEditorScreen), findsOneWidget);
    await tester.ensureVisible(title);
    expect(
      tester.widget<TextFormField>(title).controller!.text,
      'Anmeldung zum Wochenende',
    );

    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.actionKeys, hasLength(2));
    expect(server.actionKeys.first, isNotEmpty);
    expect(server.actionKeys.toSet(), hasLength(1));
    expect(server.actionBodies[1], server.actionBodies[0]);
    expect(controller.outbox, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed form message remains editable and never queues', (
    tester,
  ) async {
    final (server, controller) = await _setup(tester);
    await _show(tester, MessageComposerScreen(controller: controller));
    await tester.enterText(find.widgetWithText(TextField, 'Betreff'), 'Probe');
    await tester.enterText(
      find.widgetWithText(TextField, 'Nachricht'),
      'Bitte meldet euch an.',
    );
    await _selectForm(tester);
    server.offline = true;
    final publish = find.text('Mitteilung veröffentlichen');
    await tester.ensureVisible(publish);
    await tester.tap(publish);
    await tester.pumpAndSettle();
    expect(controller.pendingCount, 0);
    expect(controller.outbox, isEmpty);
    expect(find.byType(MessageComposerScreen), findsOneWidget);
    expect(find.text('Anmeldung zur Probe'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(TextField, 'Betreff'));
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Betreff'))
          .controller!
          .text,
      'Probe',
    );
    expect(tester.takeException(), isNull);
  });
}
