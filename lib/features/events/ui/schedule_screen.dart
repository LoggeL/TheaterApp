import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../domain/event_dates.dart';
import '../domain/event_format.dart';
import '../domain/event_types.dart';
import 'event_card.dart';
import 'event_detail_screen.dart';
import 'event_style.dart';
import 'rehearsal_calendar.dart';
import 'rsvp/rsvp_status_badge.dart';

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  int _filter = 0;
  bool _calendar = false;
  DateTime _day = DateTime.now();
  String? _selectedEventId;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) => _buildSchedule(
        context,
        constraints.maxWidth >= 1000 &&
            MediaQuery.textScalerOf(context).scale(14) <= 21,
      ),
    ),
  );

  static const _filters = ['Kommend', 'Offen', 'Zugesagt', 'Vergangen'];

  bool _matches(TheaterEvent e, int filter, DateTime now) {
    final future = e.startsAt == null || (e.endsAt ?? e.startsAt!).isAfter(now);
    return switch (filter) {
      1 => future && e.response == 'open' && widget.controller.canRespondTo(e),
      2 => future && const {'yes', 'late'}.contains(e.response),
      3 => !future,
      _ => future,
    };
  }

  int _count(int filter, DateTime now) =>
      widget.controller.events.where((e) => _matches(e, filter, now)).length;

  /// Filter chips with counts: one swipeable line on phones, wrapping with
  /// large text so every option stays reachable.
  Widget _filterChips(BuildContext context, DateTime now, {bool wrap = false}) {
    final chips = [
      for (var i = 0; i < _filters.length; i++)
        ChoiceChip(
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(_filters[i], overflow: TextOverflow.ellipsis),
              ),
              if (i < 3 && _count(i, now) > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_count(i, now)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
          selected: !_calendar && _filter == i,
          onSelected: (_) => setState(() {
            _filter = i;
            _calendar = false;
          }),
        ),
    ];
    if (wrap) return Wrap(spacing: 8, runSpacing: 8, children: chips);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        children: [
          for (final (i, c) in chips.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            c,
          ],
        ],
      ),
    );
  }

  Widget _viewToggle() => SegmentedButton<bool>(
    showSelectedIcon: false,
    segments: const [
      ButtonSegment(
        value: false,
        tooltip: 'Agenda',
        icon: Icon(Icons.view_agenda_outlined),
      ),
      ButtonSegment(
        value: true,
        tooltip: 'Kalender',
        icon: Icon(Icons.calendar_month_outlined),
      ),
    ],
    selected: {_calendar},
    onSelectionChanged: (value) => setState(() => _calendar = value.first),
  );

  Widget _buildSchedule(BuildContext context, bool desktop) {
    final now = DateTime.now();
    final events =
        widget.controller.events.where((e) {
          return _calendar ? eventOnDay(e, _day) : _matches(e, _filter, now);
        }).toList()..sort(
          (a, b) => (a.startsAt ?? DateTime(9999)).compareTo(
            b.startsAt ?? DateTime(9999),
          ),
        );
    final nextId = widget.controller.events
        .where((e) => e.startsAt != null && !eventIsPast(e, now))
        .fold<TheaterEvent?>(
          null,
          (next, e) =>
              next == null || e.startsAt!.isBefore(next.startsAt!) ? e : next,
        )
        ?.id;
    if (desktop) return _desktop(context, events, nextId);
    return RefreshIndicator(
      onRefresh: widget.controller.refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Dein Probenplan.',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ),
                      const SizedBox(width: 12),
                      _viewToggle(),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_calendar) ...[
                    RehearsalCalendar(
                      selected: _day,
                      onSelected: (day) => setState(() => _day = day),
                      events: widget.controller.events,
                    ),
                    Text(
                      DateFormat.yMMMMEEEEd('de').format(_day),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ] else
                    _filterChips(
                      context,
                      now,
                      wrap: MediaQuery.textScalerOf(context).scale(14) > 20,
                    ),
                ],
              ),
            ),
          ),
          if (events.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.event_available_outlined,
                title: 'Hier ist alles ruhig.',
                message: 'Für diese Auswahl gibt es keine Termine.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              sliver: SliverList.builder(
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final event = events[index];
                  final month = event.startsAt == null
                      ? 'Datum offen'
                      : DateFormat.yMMMM('de').format(event.startsAt!);
                  final previousMonth =
                      index == 0 || events[index - 1].startsAt == null
                      ? ''
                      : DateFormat.yMMMM(
                          'de',
                        ).format(events[index - 1].startsAt!);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (index == 0 || month != previousMonth)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(3, 12, 0, 14),
                          child: Eyebrow(month),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 13),
                        child: EventCard(
                          event: event,
                          controller: widget.controller,
                          isNext: event.id == nextId,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 26)),
        ],
      ),
    );
  }

  Widget _desktop(
    BuildContext context,
    List<TheaterEvent> events,
    String? nextId,
  ) {
    final selected =
        events.where((event) => event.id == _selectedEventId).firstOrNull ??
        events.firstOrNull;
    if (_selectedEventId == null && !_calendar && selected?.startsAt != null) {
      _day = selected!.startsAt!.toLocal();
    }
    // Keep identity across controller refreshes, including replacement objects.
    _selectedEventId = selected?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Text(
            'Dein Probenplan.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 350,
                  child: Card(
                    child: RefreshIndicator(
                      onRefresh: widget.controller.refresh,
                      child: ListView(
                        key: const PageStorageKey('schedule-agenda'),
                        primary: false,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(14),
                        children: [
                          RehearsalCalendar(
                            selected: _day,
                            onSelected: (day) => setState(() {
                              _day = day;
                              _calendar = true;
                              _selectedEventId = null;
                            }),
                            events: widget.controller.events,
                          ),
                          const Divider(height: 24),
                          _filterChips(context, DateTime.now(), wrap: true),
                          const SizedBox(height: 18),
                          Text(
                            _calendar
                                ? DateFormat.yMMMMEEEEd('de').format(_day)
                                : 'Termine · ${events.length}',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 12),
                          if (events.isEmpty)
                            const EmptyState(
                              icon: Icons.event_available_outlined,
                              title: 'Hier ist alles ruhig.',
                              message:
                                  'Für diese Auswahl gibt es keine Termine.',
                            ),
                          for (final event in events)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _AgendaTile(
                                key: ValueKey('schedule-event-${event.id}'),
                                event: event,
                                controller: widget.controller,
                                selected: selected?.id == event.id,
                                isNext: event.id == nextId,
                                onTap: () => setState(() {
                                  _selectedEventId = event.id;
                                  if (event.startsAt != null) {
                                    _day = event.startsAt!.toLocal();
                                  }
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: selected == null
                        ? const EmptyState(
                            icon: Icons.event_available_outlined,
                            title: 'Kein Termin ausgewählt',
                            message: 'Wähle einen anderen Tag oder Filter.',
                          )
                        : EventDetailContent(
                            key: ValueKey(selected.id),
                            controller: widget.controller,
                            event: selected,
                            embedded: true,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact desktop agenda entry next to the inline event details.
class _AgendaTile extends StatelessWidget {
  const _AgendaTile({
    super.key,
    required this.event,
    required this.controller,
    required this.selected,
    required this.isNext,
    required this.onTap,
  });
  final TheaterEvent event;
  final AppController controller;
  final bool selected, isNext;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final past = eventIsPast(event, now);
    final marker = eventMarker(event, now, isNext: isNext);
    final prominent = !past && isProminentKind(event.kind);
    final accent = past ? scheme.onSurfaceVariant : eventAccent(context, event);
    final pending =
        !past && event.response == 'open' && controller.canRespondTo(event);
    final tile = Material(
      color: selected
          ? scheme.primaryContainer
          : prominent
          ? Color.alphaBlend(accent.withValues(alpha: .08), scheme.surface)
          : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: marker != null && !selected
            ? BorderSide(color: scheme.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: ListTile(
        selected: selected,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.only(left: 12, right: 12),
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Tooltip(
            message: eventTypeLabel(event.kind),
            child: Icon(eventKindIcon(event.kind), size: 20, color: accent),
          ),
        ),
        title: Text(event.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${eventDate(event)}\n${eventTime(event)} · ${event.place}'),
            if (marker != null) ...[
              const SizedBox(height: 6),
              EventMarker(marker),
            ],
          ],
        ),
        trailing: pending
            ? RsvpStatusBadge(status: event.response, emphasizeOpen: true)
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
    return past ? Opacity(opacity: .62, child: tile) : tile;
  }
}
