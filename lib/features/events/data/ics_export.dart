import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/models.dart';

/// Domain of the event UIDs. The server's calendar feed
/// (server/src/calendar-feed.mjs) uses the same, so a calendar can recognise
/// an event that was both imported here and subscribed to.
const icsUidDomain = 'kolpingtheater.ramsen';

/// UID of an event, the same in this export and in the calendar feed.
String icsUid(String eventId) => '$eventId@$icsUidDomain';

/// SEQUENCE from the event version: the first version is revision 0, as in
/// the calendar feed.
int icsSequence(int version) => math.max(0, version - 1);

/// TEXT value: backslash, semicolon, comma and line breaks escaped, other
/// control characters dropped.
String icsText(String s) => s
    .replaceAll(RegExp(r'\r\n?'), '\n')
    .replaceAll(RegExp('[\u0000-\u0008\u000b-\u001f\u007f]'), '')
    .replaceAll('\\', '\\\\')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll('\n', '\\n');

String _icsStamp(DateTime date) =>
    DateFormat("yyyyMMdd'T'HHmmss'Z'").format(date.toUtc());

/// RFC 5545 line folding counts UTF-8 octets without splitting a Unicode
/// scalar; continuation lines start with a space.
String icsFold(String line) {
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
}

String calendarFile(TheaterEvent event, {DateTime? now}) {
  if (event.startsAt == null) throw ArgumentError('Der Termin hat kein Datum.');
  final lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Kolpingtheater Ramsen//Theater-App//DE',
    'CALSCALE:GREGORIAN',
    'BEGIN:VEVENT',
    'UID:${icsText(icsUid(event.id))}',
    'SEQUENCE:${icsSequence(event.version)}',
    'DTSTAMP:${_icsStamp(now ?? DateTime.now())}',
    'DTSTART:${_icsStamp(event.startsAt!)}',
    if (event.endsAt != null) 'DTEND:${_icsStamp(event.endsAt!)}',
    'SUMMARY:${icsText(event.title)}',
    if (event.place.trim().isNotEmpty)
      'LOCATION:${icsText(event.place.trim())}',
    if (event.description.isNotEmpty)
      'DESCRIPTION:${icsText(event.description)}',
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return '${lines.map(icsFold).join('\r\n')}\r\n';
}

const _umlauts = {
  'ä': 'ae',
  'ö': 'oe',
  'ü': 'ue',
  'Ä': 'Ae',
  'Ö': 'Oe',
  'Ü': 'Ue',
  'ß': 'ss',
};

/// A file name from the event title, safe on every platform: umlauts spelled
/// out, anything but letters, digits, `_` and `-` becomes a dash, at most 60
/// characters. An empty result falls back to `termin.ics`.
String calendarFileName(TheaterEvent event) {
  var name = event.title
      .replaceAllMapped(RegExp('[äöüÄÖÜß]'), (m) => _umlauts[m[0]]!)
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[-_]+|[-_]+$'), '');
  if (name.length > 60) {
    name = name.substring(0, 60).replaceAll(RegExp(r'[-_]+$'), '');
  }
  return '${name.isEmpty ? 'termin' : name}.ics';
}

Future<void> exportEvent(BuildContext context, TheaterEvent event) async {
  final box = context.findRenderObject() as RenderBox?;
  final name = calendarFileName(event);
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(
          Uint8List.fromList(utf8.encode(calendarFile(event))),
          mimeType: 'text/calendar',
          name: name,
        ),
      ],
      fileNameOverrides: [name],
      subject: event.title,
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}
