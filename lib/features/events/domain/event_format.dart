import 'package:intl/intl.dart';

import '../../../core/models.dart';
import 'rsvp_status.dart';

// A new DateFormat parses its pattern again; list items share these.
final _dayFormat = DateFormat('EEEE, d. MMMM', 'de');

String _hm(DateTime dt) {
  final h = dt.hour;
  final m = dt.minute;
  return '${h < 10 ? '0' : ''}$h:${m < 10 ? '0' : ''}$m';
}

String eventDate(TheaterEvent event) => event.startsAt == null
    ? 'Datum noch offen'
    : _dayFormat.format(event.startsAt!);

String eventTime(TheaterEvent event) => event.time.isNotEmpty
    ? event.time
    : event.startsAt == null
    ? 'Uhrzeit offen'
    : '${_hm(event.startsAt!)}${event.endsAt == null ? '' : '–${_hm(event.endsAt!)}'} Uhr';

/// The response as shown in badges and lists, in the shared vocabulary.
String statusText(String status) => RsvpStatus.fromWire(status).label;

/// The empty text for a calendar day, e.g. 'Am Montag, 12. Oktober ist
/// nichts geplant.'
String nothingPlannedOn(DateTime day) =>
    'Am ${_dayFormat.format(day)} ist nichts geplant.';
