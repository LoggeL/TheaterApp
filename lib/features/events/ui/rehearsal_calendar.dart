import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/models.dart';
import '../domain/event_dates.dart';
import 'event_style.dart';

class RehearsalCalendar extends StatefulWidget {
  const RehearsalCalendar({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.events,
    this.displayedMonth,
    this.onMonthChanged,
    this.today,
  });
  final DateTime selected;
  final ValueChanged<DateTime> onSelected;
  final List<TheaterEvent> events;

  /// The month on screen. Without it the calendar pages on its own and
  /// follows [selected] whenever that moves to another month.
  final DateTime? displayedMonth;

  /// Called when the member pages to another month. Paging never changes
  /// the selected day.
  final ValueChanged<DateTime>? onMonthChanged;

  /// The current day, normally `controller.now`; defaults to the device time.
  final DateTime? today;
  @override
  State<RehearsalCalendar> createState() => _RehearsalCalendarState();
}

class _RehearsalCalendarState extends State<RehearsalCalendar> {
  static final _monthFormat = DateFormat.yMMMM('de');
  static final _daySemanticsFormat = DateFormat.yMMMMEEEEd('de');

  late DateTime _month = _monthOf(widget.displayedMonth ?? widget.selected);

  static DateTime _monthOf(DateTime day) => DateTime(day.year, day.month);

  static int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  /// Buckets [events] by local calendar day key for the 42-day grid in one
  /// O(events) pass instead of scanning all events 42 times per build.
  static Map<int, List<TheaterEvent>> _bucketEvents(
    List<TheaterEvent> events,
    List<DateTime> days,
  ) {
    if (events.isEmpty || days.isEmpty) return const {};
    final first = days.first;
    final last = days.last;
    final gridStart = DateTime(first.year, first.month, first.day);
    final gridEnd = DateTime(last.year, last.month, last.day + 1);
    final buckets = <int, List<TheaterEvent>>{};
    for (final e in events) {
      final start = e.startsAt?.toLocal();
      if (start == null || !start.isBefore(gridEnd)) continue;
      final end = e.endsAt?.toLocal();
      final effectiveEnd = end != null && end.isAfter(start) ? end : null;
      if (effectiveEnd != null) {
        if (!effectiveEnd.isAfter(gridStart)) continue;
      } else if (start.isBefore(gridStart)) {
        continue;
      }
      var cursor = start.isBefore(gridStart)
          ? gridStart
          : DateTime(start.year, start.month, start.day);
      final lastMoment = effectiveEnd ?? start;
      while (cursor.isBefore(gridEnd)) {
        final next = DateTime(cursor.year, cursor.month, cursor.day + 1);
        final hits = effectiveEnd != null
            ? start.isBefore(next) && effectiveEnd.isAfter(cursor)
            : start.isBefore(next) && !start.isBefore(cursor);
        if (hits) (buckets[_dayKey(cursor)] ??= <TheaterEvent>[]).add(e);
        if (!lastMoment.isAfter(next)) break;
        cursor = next;
      }
    }
    return buckets;
  }

  @override
  void didUpdateWidget(RehearsalCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.displayedMonth != null) {
      _month = _monthOf(widget.displayedMonth!);
    } else if (_monthOf(widget.selected) != _monthOf(oldWidget.selected)) {
      _month = _monthOf(widget.selected);
    }
  }

  void _show(DateTime month) {
    month = _monthOf(month);
    if (month == _month) return;
    setState(() => _month = month);
    widget.onMonthChanged?.call(month);
  }

  void _page(int delta) => _show(DateTime(_month.year, _month.month + delta));

  /// Selecting a day also brings its month on screen.
  void _select(DateTime day) {
    _show(day);
    widget.onSelected(day);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final selected = widget.selected, events = widget.events;
    final now = widget.today ?? DateTime.now();
    final todayDay = DateTime(now.year, now.month, now.day);
    final days = calendarDays(_month);
    final byDay = _bucketEvents(events, days);
    return RepaintBoundary(
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Vorheriger Monat',
                onPressed: () => _page(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  _monthFormat.format(_month),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Nächster Monat',
                onPressed: () => _page(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Row(
            children: [
              for (final day in const ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      day,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall,
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

              Widget buildCell(DateTime day) {
                final dayEvents = byDay[_dayKey(day)] ?? const <TheaterEvent>[];
                final count = dayEvents.length;
                final chosen = DateUtils.isSameDay(day, selected),
                    today = DateUtils.isSameDay(day, now),
                    past = DateTime(day.year, day.month, day.day).isBefore(
                      todayDay,
                    );
                // Performances and dress rehearsals tint their day.
                TheaterEvent? highlight;
                if (!past) {
                  for (final e in dayEvents) {
                    if (isProminentKind(e.kind)) {
                      highlight = e;
                      break;
                    }
                  }
                }
                // Marks show the own response; open ones stay hollow,
                // an implicit yes ("Eingeplant") is a lighter yes.
                Color dotColor(TheaterEvent event) =>
                    responseColor(
                      displayResponse(event),
                      dark: dark,
                    ).withValues(
                      alpha: (past ? .5 : 1) * (event.implicitYes ? .6 : 1),
                    );
                BoxDecoration dot(TheaterEvent event) {
                  final answered =
                      hasResponse(event.response) || event.implicitYes;
                  return BoxDecoration(
                    color: answered ? dotColor(event) : null,
                    shape: BoxShape.circle,
                    border: !answered || chosen
                        ? Border.all(
                            color: chosen ? scheme.onPrimary : dotColor(event),
                            width: 1,
                          )
                        : null,
                  );
                }

                final foreground = chosen
                    ? scheme.onPrimary
                    : day.month != _month.month
                    ? scheme.onSurfaceVariant.withValues(alpha: .55)
                    : past
                    ? scheme.onSurfaceVariant
                    : scheme.onSurface;
                return SizedBox(
                  height: height,
                  child: Semantics(
                    button: true,
                    selected: chosen,
                    label:
                        '${_daySemanticsFormat.format(day)}, '
                        '${count == 1 ? '1 Termin' : '$count Termine'}',
                    excludeSemantics: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => _select(day),
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          // Days with events stand out from empty ones;
                          // performances tint stronger in their colour.
                          color: chosen
                              ? scheme.primary
                              : highlight != null
                              ? eventKindColor(
                                  highlight.kind,
                                  dark: dark,
                                ).withValues(alpha: .22)
                              : count > 0
                              ? scheme.primary.withValues(
                                  alpha: past ? .05 : (dark ? .16 : .1),
                                )
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
                                  fontWeight:
                                      chosen || today || (count > 0 && !past)
                                      ? FontWeight.w800
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                            if (wide)
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
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
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
                                            fontWeight: isProminentKind(
                                              event.kind,
                                            )
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
                              height: 7,
                              child: count == 0
                                  ? null
                                  : Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        for (final event in dayEvents.take(3))
                                          Container(
                                            width: 7,
                                            height: 7,
                                            margin: const EdgeInsets.symmetric(
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
                  ),
                );
              }

              return Column(
                children: [
                  for (var week = 0; week < 6; week++)
                    Row(
                      children: [
                        for (var dow = 0; dow < 7; dow++)
                          Expanded(child: buildCell(days[week * 7 + dow])),
                      ],
                    ),
                ],
              );
            },
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ResponseLegend(planned: widget.events.any((e) => e.autoAccept)),
              TextButton(
                onPressed: () => _select(now),
                child: const Text('Heute'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Explains the response colours of the calendar marks.
class _ResponseLegend extends StatelessWidget {
  const _ResponseLegend({this.planned = false});

  /// Whether events where everyone counts as attending are shown, and with
  /// them the "Eingeplant" mark.
  final bool planned;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final (status, label) in [
          ('yes', 'Zugesagt'),
          if (planned) ('auto', 'Eingeplant'),
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
                  color: status == 'auto'
                      ? responseColor(status, dark: dark).withValues(alpha: .6)
                      : hasResponse(status)
                      ? responseColor(status, dark: dark)
                      : null,
                  shape: BoxShape.circle,
                  border: hasResponse(status) || status == 'auto'
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
