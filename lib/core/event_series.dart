/// Recurring events ("Serientermine"). The server creates the occurrences in
/// Europe/Berlin wall-clock time; this preview mirrors its rules in device
/// time, which matches for the theater's German devices.
library;

enum SeriesRhythm {
  week('week', 'Wöchentlich'),
  twoWeeks('2weeks', 'Alle 2 Wochen'),
  month('month', 'Monatlich');

  const SeriesRhythm(this.wire, this.label);

  /// Value of `repeat.every` in `event.save`.
  final String wire;
  final String label;
}

/// Matches `maxSeriesEvents` on the server.
const maxSeriesEvents = 52;

const _weekdays = [
  'montags',
  'dienstags',
  'mittwochs',
  'donnerstags',
  'freitags',
  'samstags',
  'sonntags',
];

String _two(int n) => n.toString().padLeft(2, '0');
String _time(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// `YYYY-MM-DD` of a calendar day, as sent in `repeat.until`.
String seriesUntilValue(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${_two(day.month)}-${_two(day.day)}';

class SeriesPlan {
  const SeriesPlan(this.starts, this.summary, [this.problem]);

  /// Start of each occurrence, keeping the wall-clock time.
  final List<DateTime> starts;
  final String summary;

  /// Why the server would reject the series, if it would.
  final String? problem;
}

/// Occurrences from [start] up to and including the day [until].
SeriesPlan planSeries(
  DateTime start,
  DateTime end,
  SeriesRhythm rhythm,
  DateTime until,
) {
  final last = _day(until), first = _day(start);
  if (last.isBefore(first)) {
    return const SeriesPlan(
      [],
      '',
      'Das Serienende liegt vor dem ersten Termin.',
    );
  }
  if (last.isAfter(DateTime(start.year + 1, start.month, start.day))) {
    return const SeriesPlan(
      [],
      '',
      'Eine Terminserie darf höchstens ein Jahr umfassen.',
    );
  }
  final starts = <DateTime>[];
  for (var k = 0; starts.length <= maxSeriesEvents; k++) {
    final DateTime next;
    if (rhythm == SeriesRhythm.month) {
      final month = DateTime(start.year, start.month + k);
      final days = DateTime(month.year, month.month + 1, 0).day;
      next = DateTime(
        month.year,
        month.month,
        start.day > days ? days : start.day,
        start.hour,
        start.minute,
      );
    } else {
      final step = rhythm == SeriesRhythm.week ? 7 : 14;
      next = DateTime(
        start.year,
        start.month,
        start.day + k * step,
        start.hour,
        start.minute,
      );
    }
    if (_day(next).isAfter(last)) break;
    starts.add(next);
  }
  if (starts.length > maxSeriesEvents) {
    return SeriesPlan(
      starts,
      '',
      'Eine Terminserie darf höchstens $maxSeriesEvents Termine umfassen.',
    );
  }
  if (starts.length < 2) {
    return SeriesPlan(
      starts,
      '',
      'Bis zum Serienende ergibt sich nur ein Termin. '
          'Bitte ein späteres Enddatum wählen.',
    );
  }
  final times = '${_time(start)}–${_time(end)}';
  final weekday = _weekdays[start.weekday - 1];
  final rhythmText = switch (rhythm) {
    SeriesRhythm.week => '$weekday $times',
    SeriesRhythm.twoWeeks => 'alle 2 Wochen $weekday $times',
    SeriesRhythm.month => 'monatlich am ${start.day}., $times',
  };
  final sameYear = starts.first.year == starts.last.year;
  String date(DateTime d) =>
      '${d.day}.${d.month}.${sameYear ? '' : d.year.toString()}';
  return SeriesPlan(
    starts,
    'Erstellt ${starts.length} Termine: $rhythmText, '
    '${date(starts.first)} bis ${date(starts.last)}',
  );
}
