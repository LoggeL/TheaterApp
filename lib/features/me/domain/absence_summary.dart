import 'package:intl/intl.dart';

import '../../absences/domain/absence.dart';

/// One line about the member's current or next absence for Mein Bereich.
/// Absences are whole days; `to` is the last absent day.
String absenceSummary(List<Absence> absences, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  final upcoming = absences.where((a) => !day(a.to).isBefore(today)).toList()
    ..sort((a, b) => a.from.compareTo(b.from));
  if (upcoming.isEmpty) return 'Keine Abwesenheit geplant';
  final next = upcoming.first;
  final format = DateFormat('dd.MM.');
  final from = day(next.from), to = day(next.to);
  if (!from.isAfter(today)) {
    return to == today ? 'Heute abwesend' : 'Abwesend bis ${format.format(to)}';
  }
  final range = from == to
      ? format.format(from)
      : '${format.format(from)}–${format.format(to)}';
  final more = upcoming.length - 1;
  return more == 0 ? 'Nächste: $range' : 'Nächste: $range · $more weitere';
}
