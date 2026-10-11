import 'package:intl/intl.dart';

import '../../../core/models.dart';
import 'rsvp_status.dart';

String eventDate(TheaterEvent event) => event.startsAt == null
    ? 'Datum noch offen'
    : DateFormat('EEEE, d. MMMM', 'de').format(event.startsAt!);

String eventTime(TheaterEvent event) => event.time.isNotEmpty
    ? event.time
    : event.startsAt == null
    ? 'Uhrzeit offen'
    : '${DateFormat.Hm('de').format(event.startsAt!)}${event.endsAt == null ? '' : '–${DateFormat.Hm('de').format(event.endsAt!)}'} Uhr';

/// The response as shown in badges and lists, in the shared vocabulary.
String statusText(String status) => RsvpStatus.fromWire(status).label;

/// The empty text for a calendar day, e.g. 'Am Montag, 12. Oktober ist
/// nichts geplant.'
String nothingPlannedOn(DateTime day) =>
    'Am ${DateFormat('EEEE, d. MMMM', 'de').format(day)} ist nichts geplant.';
