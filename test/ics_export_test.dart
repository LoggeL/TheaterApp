import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/events/data/ics_export.dart';

void main() {
  group('single event export', () {
    TheaterEvent event({
      String title = 'Probe',
      int version = 1,
      String place = 'Ramsen',
    }) => TheaterEvent(
      id: 'e-1',
      title: title,
      startsAt: DateTime.utc(2026, 10, 25, 17),
      endsAt: DateTime.utc(2026, 10, 25, 19),
      place: place,
      version: version,
    );

    test('uses the UID and SEQUENCE of the calendar feed', () {
      final ics = calendarFile(event(), now: DateTime.utc(2026));
      expect(ics, contains('\r\nUID:e-1@kolpingtheater.ramsen\r\n'));
      expect(ics, contains('\r\nSEQUENCE:0\r\n'));
      expect(
        calendarFile(event(version: 4), now: DateTime.utc(2026)),
        contains('\r\nSEQUENCE:3\r\n'),
      );
      expect(icsUid('x'), 'x@kolpingtheater.ramsen');
      expect(icsSequence(0), 0);
      expect(ics, isNot(contains('VALARM')));
    });

    test('leaves out an empty place and folds long lines safely', () {
      final ics = calendarFile(
        event(place: ' ', title: 'Ä🎭' * 40),
        now: DateTime.utc(2026),
      );
      expect(ics, isNot(contains('LOCATION')));
      for (final line in ics.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
      expect(ics.replaceAll('\r\n ', ''), contains('SUMMARY:${'Ä🎭' * 40}'));
      expect(icsText('a\\b;c,d\r\ne\u0007'), r'a\\b\;c\,d\ne');
    });

    test('the file is named after the title, safely', () {
      expect(
        calendarFileName(event(title: 'Probe, nächste; Szene/Bühne')),
        'Probe-naechste-Szene-Buehne.ics',
      );
      expect(
        calendarFileName(event(title: 'Aufführung: Der Krug (Premiere)')),
        'Auffuehrung-Der-Krug-Premiere.ics',
      );
      expect(calendarFileName(event(title: '../../etc')), 'etc.ics');
      expect(calendarFileName(event(title: '🎭 ')), 'termin.ics');
      final long = calendarFileName(event(title: 'Sehr lange Probe ' * 10));
      expect(long.length, lessThanOrEqualTo(64));
      expect(long, endsWith('.ics'));
      expect(long, isNot(contains('-.ics')));
    });
  });
}
