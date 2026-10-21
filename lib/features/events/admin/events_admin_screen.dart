import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/account_permissions.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../domain/event_dates.dart';
import '../domain/event_format.dart';
import '../ui/event_card.dart';
import '../ui/rehearsal_calendar.dart';
import 'event_editor_screen.dart';

class EventsAdminScreen extends StatefulWidget {
  const EventsAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<EventsAdminScreen> createState() => _EventsAdminScreenState();
}

class _EventsAdminScreenState extends State<EventsAdminScreen> {
  bool _calendar = false, _showPast = false;
  late DateTime _day = DateUtils.dateOnly(widget.controller.now);

  /// Cards with a heading whenever the month changes.
  List<Widget> _months(
    BuildContext context,
    List<TheaterEvent> events, {
    bool past = false,
  }) {
    String? month;
    return [
      for (final e in events) ...[
        if (_monthLabel(e) != month) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Eyebrow(
              month = _monthLabel(e),
              color: past
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : null,
            ),
          ),
        ],
        past
            ? Opacity(opacity: .6, child: _event(context, e))
            : _event(context, e),
      ],
    ];
  }

  String _monthLabel(TheaterEvent e) => e.startsAt == null
      ? 'Ohne Datum'
      : DateFormat('MMMM yyyy', 'de').format(e.startsAt!.toLocal());

  Widget _event(BuildContext context, TheaterEvent e) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      child: ListTile(
        title: Row(
          children: [
            Flexible(child: Text(e.title)),
            if (e.inSeries)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: 'Serientermin',
                  child: Icon(Icons.repeat, size: 16),
                ),
              ),
          ],
        ),
        subtitle: Text(
          '${eventDate(e)} · ${eventTime(e)}'
          '${e.fromSlotPool ? ' · Terminfinder' : ''}',
        ),
        // Slot pool events follow their bookings and are edited in the pool.
        trailing: IconButton(
          tooltip: e.fromSlotPool
              ? 'Im Terminfinder öffnen'
              : 'Termin bearbeiten',
          onPressed: () => editEvent(context, widget.controller, e),
          icon: Icon(
            e.fromSlotPool ? Icons.edit_calendar_outlined : Icons.edit_outlined,
          ),
        ),
        onTap: () => openEvent(context, widget.controller, e.id),
      ),
    ),
  );

  int _byStart(TheaterEvent a, TheaterEvent b) =>
      (a.startsAt ?? DateTime(9999)).compareTo(b.startsAt ?? DateTime(9999));

  @override
  Widget build(BuildContext context) => Scaffold(
    // The one way to create an event; in the calendar on the selected day.
    floatingActionButton: widget.controller.user?.canManageEvents == true
        ? FloatingActionButton.extended(
            onPressed: () => openPage(
              context,
              EventEditorScreen(
                controller: widget.controller,
                initialDay: _calendar ? _day : null,
              ),
            ),
            icon: const Icon(Icons.add),
            label: Text(
              _calendar
                  ? 'Termin am ${DateFormat('d. MMMM', 'de').format(_day)} anlegen'
                  : 'Termin anlegen',
            ),
          )
        : null,
    body: AdminPage(
      controller: widget.controller,
      permission: eventsPermission,
      title: 'Termine verwalten',
      children: (context) {
        final day = widget.controller.events
            .where((e) => eventOnDay(e, _day))
            .toList();
        final now = widget.controller.now;
        final upcoming = [
          for (final e in widget.controller.events)
            if (!eventIsPast(e, now)) e,
        ]..sort(_byStart);
        // The most recent past events first.
        final past = [
          for (final e in widget.controller.events)
            if (eventIsPast(e, now)) e,
        ]..sort((a, b) => _byStart(b, a));
        return [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('Liste'),
                icon: Icon(Icons.view_agenda_outlined),
              ),
              ButtonSegment(
                value: true,
                label: Text('Kalender'),
                icon: Icon(Icons.calendar_month_outlined),
              ),
            ],
            selected: {_calendar},
            onSelectionChanged: (value) =>
                setState(() => _calendar = value.first),
          ),
          const SizedBox(height: 16),
          if (_calendar) ...[
            RehearsalCalendar(
              selected: _day,
              onSelected: (value) => setState(() => _day = value),
              events: widget.controller.events,
              today: now,
            ),
            const SizedBox(height: 12),
            Text(
              DateFormat.yMMMMEEEEd('de').format(_day),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (day.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  nothingPlannedOn(_day),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            for (final e in day) _event(context, e),
          ] else ...[
            SectionTitle('Kommend (${upcoming.length})'),
            if (upcoming.isEmpty)
              Text(
                'Keine kommenden Termine.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ..._months(context, upcoming),
            if (past.isNotEmpty) ...[
              SectionTitle(
                'Vergangen (${past.length})',
                trailing: TextButton(
                  onPressed: () => setState(() => _showPast = !_showPast),
                  child: Text(_showPast ? 'Ausblenden' : 'Einblenden'),
                ),
              ),
              if (_showPast) ..._months(context, past, past: true),
            ],
          ],
          // Room for the button so it never covers the last entry.
          const SizedBox(height: 72),
        ];
      },
    ),
  );
}
