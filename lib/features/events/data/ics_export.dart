import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/models.dart';

String _icsEscape(String s) => s
    .replaceAll('\\', '\\\\')
    .replaceAll('\n', '\\n')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll('\r', '');

String _icsStamp(DateTime date) =>
    DateFormat("yyyyMMdd'T'HHmmss'Z'").format(date.toUtc());

/// RFC 5545 line folding counts UTF-8 octets without splitting a Unicode scalar.
String calendarFile(TheaterEvent event, {DateTime? now}) {
  if (event.startsAt == null) throw ArgumentError('Der Termin hat kein Datum.');
  final lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Kolpingtheater Ramsen//Theater-App//DE',
    'CALSCALE:GREGORIAN',
    'BEGIN:VEVENT',
    'UID:${_icsEscape(event.id)}@kolpingtheater.ramsen',
    'DTSTAMP:${_icsStamp(now ?? DateTime.now())}',
    'DTSTART:${_icsStamp(event.startsAt!)}',
    if (event.endsAt != null) 'DTEND:${_icsStamp(event.endsAt!)}',
    'SUMMARY:${_icsEscape(event.title)}',
    'LOCATION:${_icsEscape(event.place)}',
    if (event.description.isNotEmpty)
      'DESCRIPTION:${_icsEscape(event.description)}',
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return '${lines.map((line) {
    final result = StringBuffer();
    var octets = 0;
    for (final rune in line.runes) {
      final char = String.fromCharCode(rune);
      final bytes = utf8.encode(char).length;
      if (octets + bytes > 75) {
        result.write('\r\n ');
        octets = 1;
      }
      result.write(char);
      octets += bytes;
    }
    return result.toString();
  }).join('\r\n')}\r\n';
}

Future<void> exportEvent(BuildContext context, TheaterEvent event) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(
          Uint8List.fromList(utf8.encode(calendarFile(event))),
          mimeType: 'text/calendar',
          name: 'probe.ics',
        ),
      ],
      fileNameOverrides: const ['probe.ics'],
      subject: event.title,
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}
