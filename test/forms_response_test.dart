import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/forms/ui/form_response_screen.dart';
import 'package:theater_app/features/forms/ui/form_submissions_screen.dart';
import 'package:theater_app/features/forms/ui/widgets/signature_pad.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

JsonMap _form({bool signature = false, List<JsonMap>? fields}) => {
  'id': 'template-1',
  'version': 2,
  'title': 'Anmeldung',
  'description': 'Bitte ausfüllen.',
  'signatureRequired': signature,
  'confirmationText': 'Ich bestätige diese Angaben.',
  'fields':
      fields ??
      [
        {'id': 'name', 'type': 'text', 'label': 'Teilnehmer', 'required': true},
      ],
};

Future<AppController> _open(WidgetTester tester, TestServer server) async {
  tester.view.physicalSize = const Size(600, 1700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  await signIn(controller);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: FormResponseScreen(controller: controller, messageId: 'message-1'),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('form-submit')));
  await tester.tap(find.byKey(const ValueKey('form-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('required values and explicit confirmation block submission', (
    tester,
  ) async {
    final server = TestServer();
    final sent = <JsonMap>[];
    server.override = (request) {
      if (request.url.path.endsWith('/forms/messages/message-1/')) {
        return Future.value(
          jsonResponse({
            'form': _form(),
            'mySubmission': null,
            'submissionGeneration': 0,
            'addressedToMe': true,
          }),
        );
      }
      if (request.url.path.endsWith('/actions/')) {
        sent.add(jsonMap(jsonDecode(request.body)));
        return Future.value(jsonResponse({'ok': true}));
      }
      return null;
    };
    await _open(tester, server);
    await _submit(tester);
    expect(sent, isEmpty);
    expect(find.text('Bitte ausfüllen.'), findsNWidgets(2));
    expect(find.text('Bitte die Bestätigung ankreuzen.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('form-field-name')),
      'Mia',
    );
    await _submit(tester);
    expect(sent, isEmpty);
  });

  testWidgets(
    'failed online send retains input and retry key; editing changes key',
    (tester) async {
      final server = TestServer();
      final sent = <JsonMap>[];
      final keys = <String?>[];
      server.override = (request) {
        if (request.url.path.endsWith('/forms/messages/message-1/')) {
          return Future.value(
            jsonResponse({
              'form': _form(),
              'mySubmission': null,
              'submissionGeneration': 0,
              'addressedToMe': true,
            }),
          );
        }
        if (request.url.path.endsWith('/actions/')) {
          sent.add(jsonMap(jsonDecode(request.body)));
          keys.add(request.headers['Idempotency-Key']);
          return Future.value(
            jsonResponse({'error': 'Testweise nicht erreichbar'}, 503),
          );
        }
        return null;
      };
      final controller = await _open(tester, server);
      await tester.enterText(
        find.byKey(const ValueKey('form-field-name')),
        'Mia',
      );
      await tester.tap(find.byKey(const ValueKey('form-confirmation')));
      await _submit(tester);
      expect(find.text('Mia'), findsOneWidget);
      expect(find.text('Testweise nicht erreichbar'), findsOneWidget);
      expect(controller.pendingCount, 0);
      await _submit(tester);
      expect(keys[0], isNotNull);
      expect(keys[1], keys[0]);
      await tester.enterText(
        find.byKey(const ValueKey('form-field-name')),
        'Mia Muster',
      );
      await _submit(tester);
      expect(keys[2], isNot(keys[1]));
      expect(jsonMap(sent.last['answers'])['name'], 'Mia Muster');
      expect(sent.last['formVersion'], 2);
      expect(sent.last['submissionGeneration'], 0);
      expect(sent.last['action'], 'form.submit');
      expect(controller.pendingCount, 0);
    },
  );

  testWidgets(
    'signed submission becomes immutable server receipt and clears on logout',
    (tester) async {
      final server = TestServer();
      final form = _form(signature: true);
      JsonMap? saved;
      final sent = <JsonMap>[];
      server.override = (request) {
        if (request.url.path.endsWith('/forms/messages/message-1/')) {
          return Future.value(
            jsonResponse({
              'form': form,
              'mySubmission': saved,
              'submissionGeneration': 0,
              'addressedToMe': true,
            }),
          );
        }
        if (request.url.path.endsWith('/actions/')) {
          final payload = jsonMap(jsonDecode(request.body));
          sent.add(payload);
          saved = {
            'id': 'receipt-1',
            'receiptId': 'receipt-instance-1',
            'messageId': 'message-1',
            'form': {...form, 'title': 'Gespeicherte Anmeldung'},
            'answers': payload['answers'],
            'signature': payload['signature'],
            'signerName': payload['signerName'],
            'personName': 'Mia Muster',
            'submittedAt': '2026-10-25T12:00:00Z',
            'confirmationText': form['confirmationText'],
          };
          return Future.value(jsonResponse({'ok': true, 'id': 'receipt-1'}));
        }
        return null;
      };
      final controller = await _open(tester, server);
      await tester.enterText(
        find.byKey(const ValueKey('form-field-name')),
        'Private Angabe',
      );
      await tester.enterText(
        find.byKey(const ValueKey('form-signer-name')),
        'Mia Muster',
      );
      await tester.tap(find.byKey(const ValueKey('form-confirmation')));
      await _submit(tester);
      expect(sent, isEmpty);
      expect(find.text('Bitte im Feld unterschreiben.'), findsOneWidget);
      final pad = find.byKey(const ValueKey('signature-pad'));
      await tester.ensureVisible(pad);
      await tester.dragFrom(
        tester.getTopLeft(pad) + const Offset(30, 30),
        const Offset(120, 55),
      );
      await _submit(tester);
      expect(sent, hasLength(1));
      final strokes = jsonList(jsonMap(sent.single['signature'])['strokes']);
      expect(strokes, isNotEmpty);
      expect(jsonList(strokes.first).length, greaterThanOrEqualTo(2));
      expect(find.text('Gespeicherte Anmeldung'), findsOneWidget);
      expect(find.text('Abgegeben'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Private Angabe'), findsOneWidget);
      expect(controller.pendingCount, 0);
      await controller.logout();
      await tester.pumpAndSettle();
      expect(find.text('Private Angabe'), findsNothing);
      expect(find.byType(SignaturePreview), findsNothing);
      expect(
        find.text('Bitte das Formular mit deinem Konto erneut öffnen.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('an admin who is not a recipient cannot submit', (tester) async {
    final server = TestServer();
    server.override = (request) =>
        request.url.path.endsWith('/forms/messages/message-1/')
        ? Future.value(
            jsonResponse({
              'form': _form(),
              'mySubmission': null,
              'submissionGeneration': 0,
              'addressedToMe': false,
            }),
          )
        : null;
    await _open(tester, server);
    expect(find.byKey(const ValueKey('form-submit')), findsNothing);
    expect(find.byKey(const ValueKey('form-confirmation')), findsNothing);
    final input = tester.widget<TextFormField>(
      find.byKey(const ValueKey('form-field-name')),
    );
    expect(input.enabled, isFalse);
  });

  testWidgets(
    'a stale offline snapshot does not block a fresh online submission',
    (tester) async {
      final server = TestServer();
      final form = _form();
      JsonMap? receipt;
      JsonMap? sent;
      server.override = (request) {
        if (request.url.path.endsWith('/forms/messages/message-1/')) {
          return Future.value(
            jsonResponse({
              'form': form,
              'mySubmission': receipt,
              'submissionGeneration': 0,
              'addressedToMe': true,
            }),
          );
        }
        if (request.url.path.endsWith('/actions/')) {
          sent = jsonMap(jsonDecode(request.body));
          receipt = {
            'id': 'message-1:1',
            'receiptId': 'fresh-receipt',
            'messageId': 'message-1',
            'personName': 'Mia',
            'personId': 1,
            'submittedAt': '2026-10-25T12:00:00Z',
            'form': form,
            'answers': sent!['answers'],
            'confirmationText': form['confirmationText'],
          };
          return Future.value(jsonResponse({'ok': true, 'id': 'message-1:1'}));
        }
        return null;
      };
      final controller = await _open(tester, server);
      server.offline = true;
      await controller.refresh();
      expect(controller.isOffline, isTrue);
      server.offline = false;
      await tester.pumpWidget(
        MaterialApp(
          home: FormResponseScreen(
            key: const ValueKey('fresh-screen'),
            controller: controller,
            messageId: 'message-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.isOffline, isTrue);
      await tester.enterText(
        find.byKey(const ValueKey('form-field-name')),
        'Mia',
      );
      await tester.tap(find.byKey(const ValueKey('form-confirmation')));
      await _submit(tester);
      expect(sent?['action'], 'form.submit');
      expect(find.text('Abgegeben'), findsOneWidget);
      expect(controller.pendingCount, 0);
    },
  );

  test('signature ignores taps and stays bounded at stroke limit', () {
    final signature = SignatureController();
    addTearDown(signature.dispose);
    signature.start(const Offset(.1, .1));
    signature.end();
    expect(signature.isEmpty, isTrue);
    expect(signature.isValid, isFalse);
    for (var i = 0; i < SignatureController.maxStrokes; i++) {
      signature.start(const Offset(.1, .1));
      signature.add(const Offset(.2, .3));
      signature.end();
    }
    expect(signature.isValid, isTrue);
    expect(signature.atLimit, isTrue);
    final before = jsonEncode(signature.toJson);
    signature.start(const Offset(.5, .1));
    signature.add(const Offset(.8, .3));
    signature.end();
    expect(jsonEncode(signature.toJson), before);
    signature.clear();
    expect(signature.isValid, isFalse);
    expect(signature.toJson['strokes'], isEmpty);
  });

  testWidgets('expired form shows deletion date and cannot be submitted', (
    tester,
  ) async {
    final server = TestServer();
    server.override = (request) =>
        request.url.path.endsWith('/forms/messages/message-1/')
        ? Future.value(
            jsonResponse({
              'form': {..._form(signature: true), 'deleteAfter': '2026-10-25'},
              'closed': true,
              'submissionGeneration': 0,
              'addressedToMe': true,
              'mySubmission': null,
            }),
          )
        : null;
    await _open(tester, server);
    expect(
      find.text('Antworten werden am 25.10.2026 gelöscht.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Dieses Formular ist geschlossen. Die Aufbewahrungsfrist ist abgelaufen.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('form-submit')), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(server.actionBodies, isEmpty);
  });

  testWidgets('long questions wrap completely on a phone above their controls', (
    tester,
  ) async {
    const health =
        'Welche gesundheitlichen Besonderheiten, Allergien oder Medikamente müssen die verantwortlichen Personen beim Probenwochenende beachten?';
    const group =
        'Darf die teilnehmende Person bei Ausflügen in einer Kleingruppe ohne Begleitung einer verantwortlichen Person unterwegs sein?';
    final server = TestServer();
    server.override = (request) =>
        request.url.path.endsWith('/forms/messages/message-1/')
        ? Future.value(
            jsonResponse({
              'form': _form(
                signature: true,
                fields: [
                  {'id': 'health', 'type': 'multiline', 'label': health},
                  {
                    'id': 'group',
                    'type': 'choice',
                    'label': group,
                    'options': ['Ja', 'Nein'],
                  },
                ],
              ),
              'submissionGeneration': 0,
              'addressedToMe': true,
              'mySubmission': null,
            }),
          )
        : null;
    await _open(tester, server);
    tester.view.physicalSize = const Size(430, 1700);
    await tester.pumpAndSettle();
    for (final label in [health, group]) {
      final finder = find.text(label);
      expect(finder, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(finder);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.getSize(finder).height, greaterThan(35));
    }
    final signer = find.text('Name der unterschreibenden Person *');
    expect(
      tester.renderObject<RenderParagraph>(signer).didExceedMaxLines,
      isFalse,
    );
    expect(find.byKey(const ValueKey('form-field-health')), findsOneWidget);
    expect(find.byKey(const ValueKey('form-field-group')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'own withdrawal retries same receipt and clears it only after confirmation',
    (tester) async {
      final server = TestServer();
      final form = {..._form(), 'deleteAfter': '2027-03-01'};
      var generation = 0;
      JsonMap? receipt = {
        'id': 'message-1:member-1',
        'receiptId': 'receipt-instance-1',
        'messageId': 'message-1',
        'personId': 1,
        'personName': 'Mia Muster',
        'submittedAt': '2026-10-25T12:00:00Z',
        'form': form,
        'answers': {'name': 'Private Angabe'},
        'confirmationText': form['confirmationText'],
      };
      final sent = <JsonMap>[];
      final keys = <String?>[];
      server.override = (request) {
        if (request.url.path.endsWith('/forms/messages/message-1/')) {
          return Future.value(
            jsonResponse({
              'form': form,
              'mySubmission': receipt,
              'submissionGeneration': generation,
              'addressedToMe': true,
            }),
          );
        }
        if (request.url.path.endsWith('/actions/')) {
          sent.add(jsonMap(jsonDecode(request.body)));
          keys.add(request.headers['Idempotency-Key']);
          if (sent.last['action'] == 'form.submit') {
            receipt = {
              'id': 'message-1:member-1',
              'receiptId': 'receipt-instance-2',
              'messageId': 'message-1',
              'personId': 1,
              'personName': 'Mia Muster',
              'submittedAt': '2026-10-25T13:00:00Z',
              'form': form,
              'answers': sent.last['answers'],
              'confirmationText': form['confirmationText'],
            };
            return Future.value(
              jsonResponse({'ok': true, 'id': 'message-1:member-1'}),
            );
          }
          if (sent.length == 1) {
            return Future.value(
              jsonResponse({'error': 'Bitte erneut versuchen'}, 503),
            );
          }
          receipt = null;
          generation++;
          return Future.value(jsonResponse({'ok': true, 'withdrawn': true}));
        }
        return null;
      };
      final controller = await _open(tester, server);
      expect(
        find.text('Antworten werden am 01.03.2027 gelöscht.'),
        findsOneWidget,
      );
      Future<void> delete() async {
        final button = find.widgetWithText(TextButton, 'Abgabe löschen');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Abgabe löschen'));
        await tester.pumpAndSettle();
      }

      await delete();
      expect(find.text('Private Angabe'), findsOneWidget);
      expect(find.text('Bitte erneut versuchen'), findsOneWidget);
      await delete();
      expect(keys, hasLength(2));
      expect(keys.first, isNotNull);
      expect(keys.last, keys.first);
      expect(sent.last, {
        'action': 'form.withdraw',
        'messageId': 'message-1',
        'submittedAt': '2026-10-25T12:00:00Z',
        'receiptId': 'receipt-instance-1',
      });
      expect(find.text('Private Angabe'), findsNothing);
      expect(find.byKey(const ValueKey('form-submit')), findsOneWidget);
      expect(find.text('Abgabe gelöscht.'), findsOneWidget);
      expect(controller.pendingCount, 0);
      await tester.enterText(
        find.byKey(const ValueKey('form-field-name')),
        'Neue Angaben',
      );
      await tester.tap(find.byKey(const ValueKey('form-confirmation')));
      await _submit(tester);
      expect(sent.last['action'], 'form.submit');
      expect(sent.last['submissionGeneration'], 1);
      expect(find.text('Neue Angaben'), findsOneWidget);
    },
  );

  testWidgets(
    'admin deletion identifies the person and refreshes the submission list',
    (tester) async {
      final server = TestServer();
      final form = _form();
      final receipt = <String, dynamic>{
        'id': 'message-1:42',
        'receiptId': 'receipt-instance-42',
        'messageId': 'message-1',
        'personId': 42,
        'personName': 'Mia Muster',
        'submittedAt': '2026-10-25T12:00:00Z',
        'form': form,
        'answers': {'name': 'Private Angabe'},
        'confirmationText': form['confirmationText'],
      };
      bool deleted = false;
      JsonMap? sent;
      server.override = (request) {
        if (request.url.path.endsWith(
          '/forms/messages/message-1/submissions/',
        )) {
          return Future.value(
            jsonResponse({
              'submissions': deleted ? [] : [receipt],
            }),
          );
        }
        if (request.url.path.endsWith('/actions/')) {
          sent = jsonMap(jsonDecode(request.body));
          deleted = true;
          return Future.value(jsonResponse({'ok': true, 'withdrawn': true}));
        }
        return null;
      };
      tester.view.physicalSize = const Size(600, 1700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = server.controller();
      await signIn(controller);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: FormSubmissionsScreen(
            controller: controller,
            messageId: 'message-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mia Muster'));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(TextButton, 'Abgabe löschen');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Abgabe löschen'));
      await tester.pumpAndSettle();
      expect(sent?['personId'], 42);
      expect(sent?['receiptId'], 'receipt-instance-42');
      expect(find.text('0 abgegeben'), findsOneWidget);
      expect(find.text('Private Angabe'), findsNothing);
      expect(controller.pendingCount, 0);
    },
  );
}
