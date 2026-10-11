import 'package:intl/intl.dart';

import '../../../core/models.dart';

String eventDate(TheaterEvent event) => event.startsAt == null
    ? 'Datum noch offen'
    : DateFormat('EEEE, d. MMMM', 'de').format(event.startsAt!);

String eventTime(TheaterEvent event) => event.time.isNotEmpty
    ? event.time
    : event.startsAt == null
    ? 'Uhrzeit offen'
    : '${DateFormat.Hm('de').format(event.startsAt!)}${event.endsAt == null ? '' : '–${DateFormat.Hm('de').format(event.endsAt!)}'} Uhr';

String statusText(String status) => switch (status) {
  'yes' => 'Dabei',
  'late' => 'Später',
  'no' => 'Abwesend',
  _ => 'Offen',
};
