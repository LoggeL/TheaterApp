import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/models.dart';

/// Builds either a saved receipt or an explicitly unsubmitted draft.
/// A receipt always uses the schema and values recorded by the server.
Future<Uint8List> buildFormPdf({
  required JsonMap form,
  JsonMap? submission,
  JsonMap answers = const {},
  String signerName = '',
  JsonMap signature = const {},
}) async {
  final saved = submission != null;
  final schema = saved ? jsonMap(submission['form']) : form;
  final values = saved ? jsonMap(submission['answers']) : answers;
  final signer = saved ? textValue(submission['signerName']) : signerName;
  final drawing = saved ? jsonMap(submission['signature']) : signature;
  final title = textValue(schema['title'], 'Formular');
  final regular = pw.Font.ttf(
    await rootBundle.load('assets/fonts/DejaVuSans.ttf'),
  );
  final bold = pw.Font.ttf(
    await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'),
  );
  final pdf = pw.Document(
    title: title,
    author: 'Kolpingtheater Ramsen',
    subject: saved ? 'Abgegebenes Formular' : 'Formular, nicht abgegeben',
    theme: pw.ThemeData.withFont(
      base: regular,
      bold: bold,
      italic: regular,
      boldItalic: bold,
    ),
  );
  final submittedAt = saved ? textValue(submission['submittedAt']) : '';
  final deleteAfter = DateTime.tryParse(textValue(schema['deleteAfter']));
  final confirmation = saved
      ? textValue(submission['confirmationText'])
      : textValue(schema['confirmationText']);
  final closing = <pw.Widget>[
    if (confirmation.isNotEmpty) ...[
      pw.SizedBox(height: 22),
      _text(saved ? 'Bestätigte Erklärung' : 'Bestätigung', bold: true),
      pw.SizedBox(height: 5),
      _text(confirmation),
    ],
    if (schema['signatureRequired'] == true || signer.isNotEmpty) ...[
      pw.SizedBox(height: 22),
      _text('Unterschrift', bold: true),
      _text('Name: ${signer.isEmpty ? '________________________' : signer}'),
      pw.SizedBox(height: 8),
      _signature(drawing),
      if (!saved) _text('Ort, Datum: ________________________', fontSize: 10),
    ],
  ];
  pdf.addPage(
    pw.MultiPage(
      maxPages: 500,
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      header: (context) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 12),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title,
              maxLines: 2,
              overflow: pw.TextOverflow.clip,
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 3),
            pw.Text(
              saved
                  ? 'Beleg ${textValue(submission['receiptId'] ?? submission['id'])}'
                  : 'Formular ${textValue(schema['id'])} · Version ${intValue(schema['version'])}',
              maxLines: 2,
              overflow: pw.TextOverflow.clip,
              style: const pw.TextStyle(fontSize: 8),
            ),
          ],
        ),
      ),
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            saved ? 'Abgegebene Fassung' : 'Nicht abgegeben',
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
      ),
      build: (_) => [
        _text(title, fontSize: 20, bold: true),
        pw.SizedBox(height: 12),
        _text(
          saved ? 'Abgegebenes Formular' : 'Nicht abgegeben',
          fontSize: 12,
          bold: true,
        ),
        if (!saved)
          _text(
            'Diese PDF-Kopie wurde noch nicht online abgegeben. '
            'Du kannst sie ausdrucken und handschriftlich ausfüllen.',
          ),
        pw.SizedBox(height: 12),
        if (saved) ...[
          _text('Abgegeben von: ${textValue(submission['personName'])}'),
          _text('Abgabezeit (UTC): $submittedAt'),
          _text(
            'Abgabe-ID: ${textValue(submission['receiptId'] ?? submission['id'])}',
            fontSize: 9,
          ),
        ],
        _text(
          'Formular-ID: ${textValue(schema['id'])} · '
          'Version ${intValue(schema['version'])}',
          fontSize: 9,
        ),
        if (textValue(schema['deleteAfter']).isNotEmpty)
          _text(
            'Antworten werden am ${deleteAfter == null ? textValue(schema['deleteAfter']) : DateFormat('dd.MM.yyyy').format(deleteAfter)} gelöscht.',
          ),
        if (textValue(schema['description']).isNotEmpty) ...[
          pw.SizedBox(height: 18),
          _text(textValue(schema['description'])),
        ],
        for (final raw in jsonList(schema['fields'])) ...[
          pw.SizedBox(height: 18),
          _text(
            '${textValue(jsonMap(raw)['label'])}'
            '${jsonMap(raw)['required'] == true ? ' (Pflichtfeld)' : ''}',
            bold: true,
          ),
          pw.SizedBox(height: 5),
          ..._answer(jsonMap(raw), values, saved: saved),
        ],
        // Keep ordinary confirmations beside the signature they accompany.
        // Long declarations remain spanning text and can use multiple pages.
        if (confirmation.length <= 700 &&
            '\n'.allMatches(confirmation).length <= 8)
          pw.Container(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: closing,
            ),
          )
        else
          ...closing,
      ],
    ),
  );
  return pdf.save();
}

/// Keeps long descriptions and answers as spanning widgets, so they can
/// continue on the next page instead of being enclosed in an unbreakable row.
pw.Widget _text(String value, {double fontSize = 11, bool bold = false}) =>
    pw.Text(
      value,
      overflow: pw.TextOverflow.span,
      style: pw.TextStyle(
        fontSize: fontSize,
        lineSpacing: 3,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    );

List<pw.Widget> _answer(JsonMap field, JsonMap values, {required bool saved}) {
  final id = textValue(field['id']);
  final present = values.containsKey(id);
  final value = values[id];
  if (field['type'] == 'checkbox' && present) {
    return [_text(value == true ? 'Ja, bestätigt' : 'Nein')];
  }
  if (present && value != null && textValue(value).isNotEmpty) {
    return [_text(textValue(value))];
  }
  if (saved) return [_text('Keine Angabe')];
  if (field['type'] == 'choice') {
    return [
      for (final option in jsonList(field['options']))
        _text('☐ ${textValue(option)}'),
    ];
  }
  if (field['type'] == 'checkbox') return [_text('☐ Bestätigt')];
  return [
    pw.SizedBox(height: field['type'] == 'multiline' ? 56 : 20),
    pw.Divider(color: PdfColors.grey500, thickness: .5),
  ];
}

pw.Widget _signature(JsonMap drawing) => pw.Container(
  width: 300,
  height: 110,
  decoration: pw.BoxDecoration(
    border: pw.Border.all(color: PdfColors.grey500, width: .5),
  ),
  child: pw.CustomPaint(
    size: const PdfPoint(300, 110),
    painter: (canvas, size) {
      canvas
        ..setColor(PdfColors.black)
        ..setLineWidth(1.4);
      for (final rawStroke in jsonList(drawing['strokes'])) {
        final points = jsonList(rawStroke)
            .where(
              (p) => p is List && p.length == 2 && p.every((v) => v is num),
            )
            .map(
              (p) => PdfPoint(
                (p[0] as num).toDouble().clamp(0, 1) * size.x,
                (1 - (p[1] as num).toDouble().clamp(0, 1)) * size.y,
              ),
            )
            .toList();
        if (points.length < 2) continue;
        canvas.moveTo(points.first.x, points.first.y);
        for (final point in points.skip(1)) {
          canvas.lineTo(point.x, point.y);
        }
        canvas.strokePath();
      }
    },
  ),
);

Future<void> exportFormPdf({
  required JsonMap form,
  JsonMap? submission,
  JsonMap answers = const {},
  String signerName = '',
  JsonMap signature = const {},
}) async {
  final bytes = await buildFormPdf(
    form: form,
    submission: submission,
    answers: answers,
    signerName: signerName,
    signature: signature,
  );
  final schema = submission == null ? form : jsonMap(submission['form']);
  final name = textValue(
    schema['title'],
    'Formular',
  ).replaceAll(RegExp(r'[^a-zA-Z0-9äöüÄÖÜß_-]'), '_');
  await Printing.layoutPdf(onLayout: (_) async => bytes, name: '$name.pdf');
}
