/// Recurring events ("Serientermine"). The server creates the occurrences in
/// Europe/Berlin wall-clock time; this preview mirrors its rules in device
/// time, which matches for the theater's German devices.
library;

enum SeriesRhythm {
  week('week', 'Wöchentlich'),
  twoWeeks('2weeks', 'Alle 2 Wochen'),
  month('month', 'Monatlich');

  const SeriesRhythm(this.wire, this.label);

  /// Value of `repeat.every` in `event.save` and of `seriesRepeat.every`.
  final String wire;
  final String label;

  static SeriesRhythm? fromWire(String? wire) =>
      values.where((r) => r.wire == wire).firstOrNull;
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

const _weekdayNames = [
  'Montag',
  'Dienstag',
  'Mittwoch',
  'Donnerstag',
  'Freitag',
  'Samstag',
  'Sonntag',
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

DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
int _daysIn(DateTime month) => DateTime(month.year, month.month + 1, 0).day;

/// The day of the month a monthly series keeps: that of its last occurrence,
/// or on the last day of a shorter month the latest one among [starts].
int _monthDay(List<DateTime> starts) {
  final last = starts.reduce(_later);
  if (last.day != _daysIn(last)) return last.day;
  return starts.map((s) => s.day).fold(last.day, (a, b) => a > b ? a : b);
}

/// The rhythm of an existing series with the occurrence [starts], e.g.
/// "Jeden Mittwoch"; the weekday is that of its last occurrence.
String seriesRhythmLabel(SeriesRhythm rhythm, List<DateTime> starts) {
  final last = starts.reduce(_later);
  return switch (rhythm) {
    SeriesRhythm.week => 'Jeden ${_weekdayNames[last.weekday - 1]}',
    SeriesRhythm.twoWeeks => 'Alle 2 Wochen ${_weekdays[last.weekday - 1]}',
    SeriesRhythm.month => 'Monatlich am ${_monthDay(starts)}.',
  };
}

/// What a new "Wiederholen bis" day does to an existing series edited as a
/// whole: occurrences the server adds in the series rhythm, or removes after
/// that day. Mirrors the server's rules in device time.
class SeriesEndChange {
  const SeriesEndChange({
    this.added = const [],
    this.removed = const [],
    this.summary = '',
    this.problem,
  });

  /// Days of the new occurrences.
  final List<DateTime> added;

  /// Starts of the occurrences that go.
  final List<DateTime> removed;
  final String summary;

  /// Why the server would reject the day, if it would.
  final String? problem;
}

/// The effect of ending the series with the occurrence [starts] on [until],
/// edited from the occurrence starting at [anchor]. Started occurrences
/// (not after [now]) and [anchor] itself stay; an extension is limited to a
/// year and [maxSeriesEvents] new dates.
SeriesEndChange planSeriesEnd({
  required List<DateTime> starts,
  required DateTime anchor,
  required SeriesRhythm? rhythm,
  required DateTime until,
  required DateTime now,
}) {
  final end = _day(until), last = starts.reduce(_later), lastDay = _day(last);
  String date(DateTime d) => '${d.day}.${d.month}.';
  String dates(int n) => n == 1 ? '1 Termin' : '$n Termine';
  if (end == lastDay) return const SeriesEndChange();
  if (end.isBefore(lastDay)) {
    if (end.isBefore(_day(anchor))) {
      return const SeriesEndChange(
        problem: 'Das Serienende darf nicht vor diesem Termin liegen.',
      );
    }
    final removed = starts.where((s) => _day(s).isAfter(end)).toList()..sort();
    if (removed.any((s) => !s.isAfter(now))) {
      return const SeriesEndChange(
        problem:
            'Begonnene Termine bleiben erhalten. Bitte ein späteres '
            'Serienende wählen.',
      );
    }
    return SeriesEndChange(
      removed: removed,
      summary: 'Entfernt ${dates(removed.length)} nach dem ${date(end)}',
    );
  }
  if (rhythm == null) {
    return const SeriesEndChange(
      problem:
          'Der Rhythmus der Serie ist nicht bekannt, sie lässt sich nicht '
          'verlängern.',
    );
  }
  if (end.isAfter(DateTime(last.year + 1, last.month, last.day))) {
    return const SeriesEndChange(
      problem:
          'Eine Serie lässt sich auf einmal um höchstens ein Jahr '
          'verlängern.',
    );
  }
  final monthDay = _monthDay(starts), added = <DateTime>[];
  for (var k = 1; ; k++) {
    final DateTime next;
    if (rhythm == SeriesRhythm.month) {
      final month = DateTime(last.year, last.month + k);
      final days = _daysIn(month);
      next = DateTime(
        month.year,
        month.month,
        monthDay > days ? days : monthDay,
      );
    } else {
      final step = rhythm == SeriesRhythm.week ? 7 : 14;
      next = DateTime(last.year, last.month, last.day + k * step);
    }
    if (next.isAfter(end)) break;
    if (added.length == maxSeriesEvents) {
      return const SeriesEndChange(
        problem:
            'Eine Serie lässt sich auf einmal um höchstens $maxSeriesEvents '
            'Termine verlängern.',
      );
    }
    added.add(next);
  }
  if (added.isEmpty) {
    return const SeriesEndChange(
      problem:
          'Bis zum neuen Serienende kommt kein Termin hinzu. Bitte ein '
          'späteres Enddatum wählen.',
    );
  }
  return SeriesEndChange(
    added: added,
    summary: added.length == 1
        ? 'Fügt 1 Termin hinzu: ${date(added.single)}'
        : 'Fügt ${dates(added.length)} hinzu: ${date(added.first)} bis '
              '${date(added.last)}',
  );
}
