import 'package:flutter/material.dart';

import '../core/event_types.dart';
import '../core/models.dart';
import 'calendar.dart';
import 'theme.dart';

/// Performances and dress rehearsals are what the ensemble works towards.
bool isProminentKind(String kind) => kind == 'performance' || kind == 'dress';

IconData eventKindIcon(String kind) => switch (kind) {
  'rehearsal' => Icons.theater_comedy_outlined,
  'readthrough' => Icons.menu_book_outlined,
  'technical' => Icons.lightbulb_outline,
  'costume' => Icons.checkroom_outlined,
  'dress' => Icons.auto_awesome_outlined,
  'performance' => Icons.local_activity_outlined,
  'meeting' => Icons.forum_outlined,
  'workshop' => Icons.school_outlined,
  'setup' => Icons.construction_outlined,
  'teardown' => Icons.inventory_2_outlined,
  'social' => Icons.celebration_outlined,
  _ => Icons.event_outlined,
};

/// Accent per event family, tuned for text contrast on light and dark cards.
Color eventKindColor(String kind, {bool dark = false}) => switch (kind) {
  'performance' => dark ? const Color(0xFFFFA584) : const Color(0xFFB83E16),
  'dress' => dark ? const Color(0xFFC9B8F0) : StageTheme.violet,
  'rehearsal' ||
  'readthrough' ||
  'technical' ||
  'costume' => dark ? const Color(0xFF9ED6B6) : StageTheme.green,
  _ => dark ? const Color(0xFFBFC8C0) : const Color(0xFF657168),
};

Color eventAccent(BuildContext context, TheaterEvent event) => eventKindColor(
  event.kind,
  dark: Theme.of(context).brightness == Brightness.dark,
);

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

/// Filled label in the brand accent, set apart from the tinted [StatePill]s.
class EventMarker extends StatelessWidget {
  const EventMarker(this.label, {super.key, this.onDark = false});
  final String label;
  final bool onDark;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = onDark ? StageTheme.orange : scheme.primary;
    final foreground = onDark ? Colors.white : scheme.onPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(50),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: foreground,
          fontSize: 10,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Event type as a coloured pill with its icon.
class EventKindPill extends StatelessWidget {
  const EventKindPill(this.kind, {super.key});
  final String kind;
  @override
  Widget build(BuildContext context) => StatePill(
    eventTypeLabel(kind),
    color: eventKindColor(
      kind,
      dark: Theme.of(context).brightness == Brightness.dark,
    ),
    icon: eventKindIcon(kind),
  );
}

/// Colour of an own response: yes, late, no; anything else counts as open.
Color responseColor(String status, {bool dark = false}) => switch (status) {
  'yes' => dark ? const Color(0xFFA8D6B6) : StageTheme.green,
  'late' => dark ? const Color(0xFFFFB18A) : const Color(0xFFA25B06),
  'no' => dark ? const Color(0xFFFFB3AB) : const Color(0xFFB34343),
  _ => dark ? const Color(0xFFBFC8C0) : const Color(0xFF657168),
};
bool hasResponse(String status) => const ['yes', 'late', 'no'].contains(status);
