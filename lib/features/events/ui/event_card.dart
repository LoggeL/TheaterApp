import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/navigation.dart';
import '../domain/event_dates.dart';
import '../domain/event_format.dart';
import '../domain/event_types.dart';
import 'event_detail_screen.dart';
import 'event_style.dart';
import 'rsvp/rsvp_status_badge.dart';

// Created once: building a DateFormat parses its pattern.
final _dayOfMonth = DateFormat('dd'), _weekday = DateFormat('EEE', 'de');

void openEvent(BuildContext context, AppController controller, String id) =>
    openPage(context, EventDetailScreen(controller: controller, eventId: id));

class EventCard extends StatelessWidget {
  const EventCard({
    super.key,
    required this.event,
    required this.controller,
    this.isNext = false,
  });
  final TheaterEvent event;
  final AppController controller;

  /// Marks the chronologically next event of the whole plan.
  final bool isNext;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = controller.now;
    final past = eventIsPast(event, now);
    final marker = eventMarker(event, now, isNext: isNext);
    final prominent = !past && isProminentKind(event.kind);
    final accent = past ? scheme.onSurfaceVariant : eventAccent(context, event);
    final surface = theme.cardTheme.color ?? scheme.surfaceContainerLow;
    final card = Card(
      color: prominent
          ? Color.alphaBlend(accent.withValues(alpha: .07), surface)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: marker != null
            ? BorderSide(color: scheme.primary, width: 2)
            : prominent
            ? BorderSide(color: accent.withValues(alpha: .35))
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => openEvent(context, controller, event.id),
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      Text(
                        event.startsAt == null
                            ? '–'
                            : _dayOfMonth.format(event.startsAt!),
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                          color: accent,
                        ),
                      ),
                      Text(
                        event.startsAt == null
                            ? 'OFFEN'
                            : _weekday.format(event.startsAt!).toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (marker != null || prominent) ...[
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (marker != null) EventMarker(marker),
                            if (prominent) EventKindPill(event.kind),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        event.title,
                        style: prominent
                            ? theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              )
                            : theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            eventKindIcon(event.kind),
                            size: 14,
                            color: accent,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              '${eventTypeLabel(event.kind)} · ${eventTime(event)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(event.place, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!event.addressedToMe)
                  const NotInvitedPill()
                else
                  RsvpStatusBadge(
                    status: displayResponse(event),
                    expectedArrivalAt: event.expectedArrivalAt,
                    locked: responsesClosed(controller, event),
                    emphasizeOpen: !past && !event.fromSlotPool,
                    // The words need room the title cannot spare on small
                    // phones.
                    showLabel: constraints.maxWidth >= 270,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // Past events stay readable but step back behind what is still ahead.
    return past ? Opacity(opacity: .62, child: card) : card;
  }
}
