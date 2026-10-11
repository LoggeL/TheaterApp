import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../domain/cue_category.dart';
import '../domain/reader_entries.dart';
import '../domain/script_document.dart';

/// Builds a printable A4 script from [entries] and hands it to the system
/// print or share dialog. [footer] names the selected roles; [isOwn] marks
/// the cues printed in bold.
Future<void> exportScriptPdf({
  required String title,
  required List<ReaderEntry> entries,
  required String footer,
  required bool Function(ScriptCue cue) isOwn,
}) async {
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/DejaVuSans.ttf'),
  );
  final boldFont = pw.Font.ttf(
    await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'),
  );
  final pdf = pw.Document(
    title: title,
    author: 'Kolpingtheater Ramsen',
    theme: pw.ThemeData.withFont(
      base: font,
      bold: boldFont,
      italic: font,
      boldItalic: boldFont,
    ),
  );
  pdf.addPage(
    pw.MultiPage(
      maxPages: 500,
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      header: (context) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 14),
        child: pw.Text(
          title,
          style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
        ),
      ),
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(footer, style: const pw.TextStyle(fontSize: 9)),
          pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
      ),
      build: (context) => [
        for (final entry in entries)
          if (entry.scene != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 20, bottom: 10),
              child: pw.Text(
                entry.scene!.title,
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            )
          else ...[
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 10, bottom: 3),
              child: pw.Text(
                entry.cue!.role.isEmpty
                    ? cueCategoryInfo(entry.cue!.kind).label
                    : entry.cue!.role,
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Text(
              entry.cue!.text,
              style: pw.TextStyle(
                fontSize: 11,
                lineSpacing: 3,
                fontStyle: entry.cue!.kind == 'direction'
                    ? pw.FontStyle.italic
                    : pw.FontStyle.normal,
                fontWeight: isOwn(entry.cue!)
                    ? pw.FontWeight.bold
                    : pw.FontWeight.normal,
              ),
            ),
          ],
      ],
    ),
  );
  await Printing.layoutPdf(
    onLayout: (_) => pdf.save(),
    name: '${title.replaceAll(RegExp(r'[^a-zA-Z0-9äöüÄÖÜß_-]'), '_')}.pdf',
  );
}
