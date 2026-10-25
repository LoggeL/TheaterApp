import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/forms/data/form_pdf_exporter.dart';

JsonMap _form({String title = 'Anmeldung', List<JsonMap>? fields}) => {
  'id': 'form-1',
  'version': 2,
  'title': title,
  'description': 'Bitte die Angaben ausfüllen.',
  'confirmationText': 'Ich bestätige meine Angaben.',
  'signatureRequired': true,
  'fields':
      fields ??
      [
        {'id': 'name', 'type': 'text', 'label': 'Name', 'required': true},
        {
          'id': 'meal',
          'type': 'choice',
          'label': 'Essen',
          'required': true,
          'options': ['Vegetarisch', 'Vegan'],
        },
        {'id': 'yes', 'type': 'checkbox', 'label': 'Zusage'},
        {'id': 'note', 'type': 'multiline', 'label': 'Hinweise'},
      ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('blank export is a PDF explicitly marked as not submitted', () async {
    final bytes = await buildFormPdf(form: _form());
    final content = latin1.decode(bytes);
    expect(content, startsWith('%PDF-'));
    expect(content, contains('%%EOF'));
    expect(content, contains('Formular, nicht abgegeben'));
    expect(bytes.length, greaterThan(1000));
  });

  test(
    'receipt uses the recorded form and distinguishes it from a draft',
    () async {
      final bytes = await buildFormPdf(
        form: _form(title: 'Edited template'),
        answers: {'name': 'Unsaved draft'},
        submission: {
          'id': 'submission-1',
          'form': _form(title: 'Recorded form'),
          'personName': 'Mia Muster',
          'submittedAt': '2026-10-25T12:00:00.000Z',
          'confirmationText': 'Ich bestätige meine Angaben.',
          'answers': {'name': 'Mia Muster', 'meal': 'Vegan', 'yes': false},
          'signerName': 'Mia Muster',
          'signature': {
            'strokes': [
              [
                [0.1, 0.3],
                [0.3, 0.7],
                [0.6, 0.2],
              ],
              [
                [0.5, 0.5],
                [0.9, 0.5],
              ],
            ],
          },
        },
      );
      final content = latin1.decode(bytes);
      expect(content, contains('Recorded form'));
      expect(content, isNot(contains('Edited template')));
      expect(content, contains('Abgegebenes Formular'));
      expect(content, isNot(contains('Formular, nicht abgegeben')));
    },
  );

  test(
    'long multiline values and descriptions paginate without overflow',
    () async {
      final fields = [
        for (var i = 0; i < 30; i++)
          {'id': 'field-$i', 'type': 'multiline', 'label': 'Hinweis $i'},
      ];
      final form = _form(fields: fields);
      form['description'] = List.filled(
        150,
        'Ausführliche Beschreibung.',
      ).join('\n');
      final bytes = await buildFormPdf(
        form: form,
        answers: {
          for (var i = 0; i < fields.length; i++)
            'field-$i': List.filled(160, 'Mehrzeilige Angaben.').join('\n'),
        },
      );
      final content = latin1.decode(bytes);
      expect(content, contains('%%EOF'));
      expect(
        RegExp(r'/Type\s*/Page\b').allMatches(content).length,
        greaterThan(3),
      );
    },
  );
}
