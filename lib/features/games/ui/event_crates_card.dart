import 'package:intl/intl.dart';

import '../data/wardrobe_api.dart';

final _day = DateFormat('EEE d. MMMM', 'de');

/// "Probe Akt 2 · Sa. 31. Oktober": which event a Termin-Kiste came from.
String eventCrateEvent(EventCrate e) => [
  if (e.title.isNotEmpty) e.title,
  if (e.startsAt case final start?) _day.format(start),
].join(' · ');

/// "Termin-Kiste · Probe Akt 2 · Sa. 31. Oktober", or just "Termin-Kiste".
String eventCrateTitle(EventCrate? e) {
  final event = e == null ? '' : eventCrateEvent(e);
  return event.isEmpty ? 'Termin-Kiste' : 'Termin-Kiste · $event';
}
