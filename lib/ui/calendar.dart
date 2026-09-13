import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/models.dart';

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
          builder: (context, constraints) => GridView.count(
            crossAxisCount: 7,
            childAspectRatio:
                constraints.maxWidth /
                7 /
                (constraints.maxWidth >= 700 ? 96 : 52),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final day in calendarDays(selected))
                Builder(
                  builder: (context) {
                    final count = events
                        .where((e) => eventOnDay(e, day))
                        .length;
                    final chosen = DateUtils.isSameDay(day, selected),
                        today = DateUtils.isSameDay(day, DateTime.now());
                    final foreground = chosen
                        ? scheme.onPrimary
                        : day.month == selected.month
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant.withValues(alpha: .55);
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
                            color: chosen ? scheme.primary : null,
                            borderRadius: BorderRadius.circular(14),
                            border: today && !chosen
                                ? Border.all(color: scheme.primary)
                                : null,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '${day.day}',
                                style: TextStyle(
                                  color: foreground,
                                  fontWeight: chosen || today
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              if (constraints.maxWidth >= 700)
                                for (final event
                                    in events
                                        .where((e) => eventOnDay(e, day))
                                        .take(2))
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    child: Text(
                                      event.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: foreground,
                                      ),
                                    ),
                                  ),
                              const SizedBox(height: 3),
                              SizedBox(
                                height: 5,
                                child: count == 0
                                    ? null
                                    : Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: List.generate(
                                          count.clamp(1, 3),
                                          (_) => Container(
                                            width: 4,
                                            height: 4,
                                            margin: const EdgeInsets.symmetric(
                                              horizontal: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              color: foreground,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        ),
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
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => onSelected(DateTime.now()),
            child: const Text('Heute'),
          ),
        ),
      ],
    );
  }
}
