import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/models.dart';
import 'event_style.dart';

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

class RehearsalCalendar extends StatelessWidget {
  const RehearsalCalendar({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.events,
  });
  final DateTime selected;
  final ValueChanged<DateTime> onSelected;
  final List<TheaterEvent> events;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Vorheriger Monat',
              onPressed: () =>
                  onSelected(DateTime(selected.year, selected.month - 1)),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                DateFormat.yMMMM('de').format(selected),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Nächster Monat',
              onPressed: () =>
                  onSelected(DateTime(selected.year, selected.month + 1)),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Row(
          children: [
            for (final day in ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    day,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final textScaler = MediaQuery.textScalerOf(context);
            final wide = constraints.maxWidth >= 700;
            final height =
                (26 +
                        textScaler.scale(14) * 1.5 +
                        (wide ? textScaler.scale(11) * 3 + 8 : 0))
                    .clamp(wide ? 96.0 : 52.0, double.infinity);
            return GridView.count(
              crossAxisCount: 7,
              childAspectRatio: constraints.maxWidth / 7 / height,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final day in calendarDays(selected))
                  Builder(
                    builder: (context) {
                      final dayEvents = events
                          .where((e) => eventOnDay(e, day))
                          .toList();
                      final count = dayEvents.length;
                      final now = DateTime.now();
                      final chosen = DateUtils.isSameDay(day, selected),
                          today = DateUtils.isSameDay(day, now),
                          past = DateTime(
                            day.year,
                            day.month,
                            day.day,
                          ).isBefore(DateTime(now.year, now.month, now.day));
                      final dark =
                          Theme.of(context).brightness == Brightness.dark;
                      // Performances and dress rehearsals tint their day.
                      final highlight = past
                          ? null
                          : dayEvents
                                .where((e) => isProminentKind(e.kind))
                                .firstOrNull;
                      // Marks show the own response; open ones stay hollow.
                      Color dotColor(TheaterEvent event) => responseColor(
                        event.response,
                        dark: dark,
                      ).withValues(alpha: past ? .5 : 1);
                      BoxDecoration dot(TheaterEvent event) {
                        final answered = hasResponse(event.response);
                        return BoxDecoration(
                          color: answered ? dotColor(event) : null,
                          shape: BoxShape.circle,
                          border: !answered || chosen
                              ? Border.all(
                                  color: chosen
                                      ? scheme.onPrimary
                                      : dotColor(event),
                                  width: 1,
                                )
                              : null,
                        );
                      }

                      final foreground = chosen
                          ? scheme.onPrimary
                          : day.month != selected.month
                          ? scheme.onSurfaceVariant.withValues(alpha: .55)
                          : past
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface;
                      return Semantics(
                        button: true,
                        selected: chosen,
                        label:
                            '${DateFormat.yMMMMEEEEd('de').format(day)}, $count Termine',
                        excludeSemantics: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => onSelected(day),
                          child: Container(
                            margin: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: chosen
                                  ? scheme.primary
                                  : today
                                  ? scheme.primary.withValues(alpha: .1)
                                  : highlight != null
                                  ? eventKindColor(
                                      highlight.kind,
                                      dark: dark,
                                    ).withValues(alpha: .12)
                                  : null,
                              borderRadius: BorderRadius.circular(14),
                              border: today && !chosen
                                  ? Border.all(color: scheme.primary, width: 2)
                                  : null,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    '${day.day}',
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: 14,
                                      fontWeight: chosen || today
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (constraints.maxWidth >= 700)
                                  for (final event in dayEvents.take(2))
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 3,
                                            height: 11,
                                            decoration: BoxDecoration(
                                              color: dotColor(event),
                                              borderRadius:
                                                  BorderRadius.circular(2),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              event.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: foreground,
                                                fontWeight:
                                                    isProminentKind(event.kind)
                                                    ? FontWeight.w700
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                const SizedBox(height: 3),
                                SizedBox(
                                  height: 6,
                                  child: count == 0
                                      ? null
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            for (final event in dayEvents.take(
                                              3,
                                            ))
                                              Container(
                                                width: 6,
                                                height: 6,
                                                margin:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 1,
                                                    ),
                                                decoration: dot(event),
                                              ),
                                          ],
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            );
          },
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const _ResponseLegend(),
            TextButton(
              onPressed: () => onSelected(DateTime.now()),
              child: const Text('Heute'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Explains the response colours of the calendar marks.
class _ResponseLegend extends StatelessWidget {
  const _ResponseLegend();
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final (status, label) in const [
          ('yes', 'Zugesagt'),
          ('late', 'Später'),
          ('no', 'Abgesagt'),
          ('open', 'Offen'),
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: hasResponse(status)
                      ? responseColor(status, dark: dark)
                      : null,
                  shape: BoxShape.circle,
                  border: hasResponse(status)
                      ? null
                      : Border.all(color: responseColor(status, dark: dark)),
                ),
              ),
              const SizedBox(width: 5),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
      ],
    );
  }
}
