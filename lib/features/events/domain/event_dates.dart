import '../../../core/models.dart';

List<DateTime> calendarDays(DateTime month) {
  final first = DateTime(month.year, month.month);
  return List.generate(
    42,
    (i) => DateTime(first.year, first.month, 1 - (first.weekday - 1) + i),
  );
}

bool eventOnDay(TheaterEvent event, DateTime day) {
  final start = event.startsAt?.toLocal();
  if (start == null) return false;
  final midnight = DateTime(day.year, day.month, day.day),
      next = DateTime(day.year, day.month, day.day + 1);
  final end = event.endsAt?.toLocal();
  return start.isBefore(next) &&
      (end != null && end.isAfter(start)
          ? end.isAfter(midnight)
          : !start.isBefore(midnight));
}

bool eventIsPast(TheaterEvent event, DateTime now) {
  final start = event.startsAt;
  return start != null && !(event.endsAt ?? start).isAfter(now);
}

bool eventIsRunning(TheaterEvent event, DateTime now) {
  final start = event.startsAt;
  return start != null &&
      !start.isAfter(now) &&
      (event.endsAt ?? start).isAfter(now);
}

/// Short highlight label for events that deserve attention right now.
String? eventMarker(TheaterEvent event, DateTime now, {bool isNext = false}) {
  if (eventIsPast(event, now)) return null;
  if (eventIsRunning(event, now)) return 'Läuft gerade';
  if (eventOnDay(event, now)) return 'Heute';
  return isNext ? 'Als Nächstes' : null;
}
