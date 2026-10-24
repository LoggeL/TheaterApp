import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
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

/// The Termin-Kisten waiting in the wardrobe (`runnerEventCrates`): one per
/// event the person was at (recorded, or adopted from the own commitment),
/// only for them. Each names its event and opens with the usual unboxing.
class EventCratesCard extends StatelessWidget {
  const EventCratesCard({super.key, required this.crates, this.onOpen});
  final List<EventCrate> crates;

  /// Opens the Termin-Kiste of one event; null while something else runs.
  final ValueChanged<EventCrate>? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = crates.length;
    return Card(
      key: const ValueKey('runner-event-crates'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Badge(
                  isLabelVisible: n > 0,
                  label: Text('$n'),
                  child: const Icon(
                    Icons.event_available,
                    color: StageTheme.orange,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n == 1
                            ? '1 Termin-Kiste bereit'
                            : '$n Termin-Kisten bereit',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        'Danke fürs Dabeisein! Für jeden Termin, bei dem du da warst, gibt es eine Kiste – nur für dich.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final e in crates)
              ListTile(
                key: ValueKey('event-crate-${e.eventId}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.inventory_2_outlined),
                title: const Text('Termin-Kiste'),
                subtitle: Text(eventCrateEvent(e)),
                trailing: FilledButton.tonal(
                  onPressed: onOpen == null ? null : () => onOpen!(e),
                  child: const Text('Öffnen'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
