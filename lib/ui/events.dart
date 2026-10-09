export 'today.dart' show TodayScreen;
import '../core/event_types.dart';
import 'calendar.dart';
import 'app_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'dart:convert';

import '../core/app_controller.dart';
import '../core/models.dart';
import 'theme.dart';
import 'reader.dart';
import 'rehearsal_admin.dart';

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
Color statusColor(String status) => switch (status) {
  'yes' => StageTheme.green,
  'late' => const Color(0xFFA25B06),
  'no' => const Color(0xFFB34343),
  _ => const Color(0xFF657168),
};

class RsvpStatusBadge extends StatelessWidget {
  const RsvpStatusBadge({
    super.key,
    required this.status,
    this.expectedArrivalAt,
    this.locked = false,
    this.onDark = false,
  });

  final String status;
  final DateTime? expectedArrivalAt;
  final bool locked, onDark;

  @override
  Widget build(BuildContext context) {
    final arrival = status == 'late' && expectedArrivalAt != null
        ? DateFormat.Hm('de').format(expectedArrivalAt!.toLocal())
        : null;
    final label = [
      status == 'open' ? 'Rückmeldung offen' : statusText(status),
      if (status == 'late') arrival ?? 'Uhrzeit offen',
      if (locked) 'Rückmeldung geschlossen',
    ].join(' · ');
    final icon = switch (status) {
      'yes' => Icons.thumb_up_alt,
      'no' => Icons.thumb_down_alt,
      'late' => Icons.schedule,
      _ => Icons.help_outline,
    };
    final color = onDark || Theme.of(context).brightness == Brightness.dark
        ? switch (status) {
            'yes' => const Color(0xFFA8D6B6),
            'no' => const Color(0xFFFFB3AB),
            'late' => const Color(0xFFFFB18A),
            _ => const Color(0xFFBFC8C0),
          }
        : statusColor(status);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              if (arrival != null) ...[
                const SizedBox(width: 5),
                Text(
                  arrival,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (locked) ...[
                const SizedBox(width: 4),
                Icon(Icons.lock_outline, size: 12, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> runAction(
  BuildContext context,
  Future<void> Function() action, {
  String? message,
}) async {
  try {
    await action();
    if (context.mounted && message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }
}

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

  Widget _buildSchedule(BuildContext context, bool desktop) {
    final now = DateTime.now();
    final events =
        widget.controller.events.where((e) {
          final future =
              e.startsAt == null || (e.endsAt ?? e.startsAt!).isAfter(now);
          final filter = switch (_filter) {
            1 =>
              future &&
                  e.response == 'open' &&
                  widget.controller.canRespondTo(e),
            2 => future && const {'yes', 'late'}.contains(e.response),
            3 => !future,
            _ => future,
          };
          return _calendar ? eventOnDay(e, _day) : filter;
        }).toList()..sort(
          (a, b) => (a.startsAt ?? DateTime(9999)).compareTo(
            b.startsAt ?? DateTime(9999),
          ),
        );
    if (desktop) return _desktop(context, events);
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
                    ],
                  ),
                  const SizedBox(height: 18),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final largeText =
                          MediaQuery.textScalerOf(context).scale(14) > 20;
                      if (constraints.maxWidth < 360 || largeText) {
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final calendar in [false, true])
                              ChoiceChip(
                                avatar: Icon(
                                  calendar
                                      ? Icons.calendar_month_outlined
                                      : Icons.view_agenda_outlined,
                                  size: 18,
                                ),
                                label: Text(calendar ? 'Kalender' : 'Agenda'),
                                selected: _calendar == calendar,
                                onSelected: (_) =>
                                    setState(() => _calendar = calendar),
                              ),
                          ],
                        );
                      }
                      return SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('Agenda'),
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
                      );
                    },
                  ),
                  const SizedBox(height: 12),
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
                  ],
                  if (!_calendar) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < 4; i++)
                          ChoiceChip(
                            label: Text(
                              ['Kommend', 'Offen', 'Zugesagt', 'Vergangen'][i],
                            ),
                            selected: _filter == i,
                            onSelected: (_) => setState(() => _filter = i),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${['Kommend', 'Offen', 'Zugesagt', 'Vergangen'][_filter]} · ${events.length} ${events.length == 1 ? 'Termin' : 'Termine'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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

  Widget _desktop(BuildContext context, List<TheaterEvent> events) {
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
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (var i = 0; i < 4; i++)
                                ChoiceChip(
                                  label: Text(
                                    [
                                      'Kommend',
                                      'Offen',
                                      'Zugesagt',
                                      'Vergangen',
                                    ][i],
                                  ),
                                  selected: !_calendar && _filter == i,
                                  onSelected: (_) => setState(() {
                                    _filter = i;
                                    _calendar = false;
                                  }),
                                ),
                            ],
                          ),
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
                              child: Material(
                                color: selected?.id == event.id
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.primaryContainer
                                    : Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(14),
                                child: ListTile(
                                  key: ValueKey('schedule-event-${event.id}'),
                                  selected: selected?.id == event.id,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  title: Text(event.title),
                                  subtitle: Text(
                                    '${eventDate(event)}\n${eventTime(event)} · ${event.place}',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => setState(() {
                                    _selectedEventId = event.id;
                                    if (event.startsAt != null) {
                                      _day = event.startsAt!.toLocal();
                                    }
                                  }),
                                ),
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

void openEvent(BuildContext context, AppController controller, String id) =>
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EventDetailScreen(controller: controller, eventId: id),
      ),
    );

class EventCard extends StatelessWidget {
  const EventCard({super.key, required this.event, required this.controller});
  final TheaterEvent event;
  final AppController controller;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => openEvent(context, controller, event.id),
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  Text(
                    event.startsAt == null
                        ? '–'
                        : DateFormat('dd').format(event.startsAt!),
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  Text(
                    event.startsAt == null
                        ? 'OFFEN'
                        : DateFormat(
                            'EEE',
                            'de',
                          ).format(event.startsAt!).toUpperCase(),
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
                  Text(
                    event.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${eventTypeLabel(event.kind)} · ${eventTime(event)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    event.place,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            RsvpStatusBadge(
              status: event.response,
              expectedArrivalAt: event.expectedArrivalAt,
              locked: !controller.canRespondTo(event),
            ),
          ],
        ),
      ),
    ),
  );
}

class EventDetailScreen extends StatelessWidget {
  const EventDetailScreen({
    super.key,
    required this.controller,
    required this.eventId,
  });
  final AppController controller;
  final String eventId;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final matches = controller.events.where((e) => e.id == eventId);
      if (matches.isEmpty) {
        return DesktopRouteFrame(
          controller: controller,
          selectedIndex: 1,
          child: Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.event_busy,
              title: 'Termin nicht verfügbar',
              message:
                  'Der Termin wurde entfernt oder ist für dein Konto nicht sichtbar.',
            ),
          ),
        );
      }
      final event = matches.first;
      return DesktopRouteFrame(
        controller: controller,
        selectedIndex: 1,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Termin'),
            actions: [
              IconButton(
                tooltip: 'Kalenderdatei teilen',
                onPressed: event.startsAt == null
                    ? null
                    : () =>
                          runAction(context, () => exportEvent(context, event)),
                icon: const Icon(Icons.ios_share),
              ),
            ],
          ),
          body: EventDetailContent(controller: controller, event: event),
        ),
      );
    },
  );
}

/// The same event controls used by the route and desktop selection.
class EventDetailContent extends StatelessWidget {
  const EventDetailContent({
    super.key,
    required this.controller,
    required this.event,
    this.embedded = false,
  });
  final AppController controller;
  final TheaterEvent event;
  final bool embedded;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = constraints.maxWidth > 840
          ? (constraints.maxWidth - 840) / 2 + 24
          : 24.0;
      return ListView(
        primary: false,
        padding: EdgeInsets.fromLTRB(side, 16, side, 36),
        children: [
          Eyebrow(event.group.isEmpty ? 'Kolpingtheater Ramsen' : event.group),
          const SizedBox(height: 12),
          Text(
            event.title,
            style: embedded
                ? Theme.of(context).textTheme.headlineMedium
                : Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          Text(
            eventTypeLabel(event.kind),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          if (event.description.isNotEmpty) ...[
            const SizedBox(height: 20),
            SelectableText(event.description),
          ],
          SizedBox(height: embedded ? 16 : 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(19),
              child: Column(
                children: [
                  _DetailMeta(Icons.calendar_today_outlined, eventDate(event)),
                  SizedBox(height: embedded ? 10 : 17),
                  _DetailMeta(Icons.schedule, eventTime(event)),
                  SizedBox(height: embedded ? 10 : 17),
                  _DetailMeta(
                    Icons.location_on_outlined,
                    event.place.isEmpty
                        ? 'Ort wird noch bekannt gegeben'
                        : event.place,
                  ),
                  if (event.roleIds.isNotEmpty) ...[
                    SizedBox(height: embedded ? 10 : 17),
                    _DetailMeta(
                      Icons.group_outlined,
                      'Für ${controller.audienceLabel(event.roleIds)}',
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: embedded ? 16 : 24),
          RsvpPanel(
            key: ValueKey(event.id),
            controller: controller,
            event: event,
            compact: embedded,
          ),
          if (event.declineReason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Dein Absagegrund: ${event.declineReason}'),
            ),
          if (controller.pendingCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '${controller.pendingCount} Änderung(en) warten auf Übertragung.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (event.productionId != null) ...[
            const SectionTitle('Für diese Probe'),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(18),
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('Zum Drehbuch'),
                subtitle: Text(
                  event.sceneIds.isEmpty
                      ? 'Die verknüpfte Produktion öffnen'
                      : 'Szenen ${event.sceneIds.join(', ')}',
                ),
                trailing: const Icon(Icons.arrow_forward),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ScriptReaderScreen(
                      controller: controller,
                      productionId: event.productionId!,
                      initialSceneId: event.sceneIds.firstOrNull,
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (controller.user?.isAdmin == true) ...[
            const SectionTitle('Probenleitung'),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ResponsesAdminScreen(
                    controller: controller,
                    event: event,
                  ),
                ),
              ),
              icon: const Icon(Icons.people_outline),
              label: const Text('Rückmeldungen ansehen'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AttendanceEditorScreen(
                    controller: controller,
                    event: event,
                  ),
                ),
              ),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Anwesenheit erfassen'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ScenePlannerScreen(controller: controller, event: event),
                ),
              ),
              icon: const Icon(Icons.link),
              label: const Text('Szenen planen'),
            ),
          ],
          SizedBox(height: embedded ? 16 : 24),
          OutlinedButton.icon(
            onPressed: event.startsAt == null
                ? null
                : () => runAction(context, () => exportEvent(context, event)),
            icon: const Icon(Icons.calendar_month_outlined),
            label: const Text('Für den Kalender exportieren'),
          ),
        ],
      );
    },
  );
}

class RsvpPanel extends StatefulWidget {
  const RsvpPanel({
    super.key,
    required this.controller,
    required this.event,
    this.compact = false,
  });
  final AppController controller;
  final TheaterEvent event;
  final bool compact;
  @override
  State<RsvpPanel> createState() => _RsvpPanelState();
}

class _RsvpPanelState extends State<RsvpPanel> {
  bool _editingLate = false, _busy = false;
  DateTime? _arrival;
  Future<void> _save(String status) async {
    setState(() => _busy = true);
    try {
      await widget.controller.respond(
        widget.event.id,
        status,
        expectedArrivalAt: status == 'late' ? _arrival : null,
      );
      if (mounted) setState(() => _editingLate = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime() async {
    final e = widget.event, start = widget.event.startsAt;
    if (start == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _arrival ?? start.add(const Duration(minutes: 30)),
      ),
    );
    if (time == null || !mounted) return;
    var arrival = DateTime(
      start.year,
      start.month,
      start.day,
      time.hour,
      time.minute,
    );
    if (!arrival.isAfter(start) &&
        e.endsAt != null &&
        dateOnly(e.endsAt!) != dateOnly(start)) {
      arrival = arrival.add(const Duration(days: 1));
    }
    setState(() => _arrival = arrival);
  }

  Widget _choice(
    String status,
    String label,
    IconData icon,
    VoidCallback action,
  ) {
    final selected = _editingLate
        ? status == 'late'
        : widget.event.response == status;
    final enabled =
        !_busy &&
        (status == 'no'
            ? widget.controller.canDecline(widget.event)
            : widget.controller.canRespondTo(widget.event));
    final color = statusColor(status);
    if (widget.compact) {
      return Semantics(
        selected: selected,
        child: OutlinedButton.icon(
          onPressed: enabled ? action : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            backgroundColor: selected ? color.withValues(alpha: .11) : null,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: Icon(icon, size: 18),
          label: Text(label),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? color.withValues(alpha: .11)
            : Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected
                ? color.withValues(alpha: .45)
                : Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: .5),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? action : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? color
                      : Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final canRespond = widget.controller.canRespondTo(e);
    final canDecline = widget.controller.canDecline(e);
    final pending = widget.controller.outbox.any(
      (a) =>
          !a.failed &&
          a.payload['action'] == 'attendance' &&
          a.payload['eventId'] == e.id,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          canRespond ? 'Bist du dabei?' : 'Deine Rückmeldung',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        if (canRespond)
          if (widget.compact)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _choice(
                  'yes',
                  'Bin dabei',
                  Icons.thumb_up_alt_outlined,
                  () => _save('yes'),
                ),
                _choice(
                  'late',
                  'Komme später',
                  Icons.schedule,
                  () => setState(() {
                    _editingLate = true;
                    _arrival = e.expectedArrivalAt;
                  }),
                ),
                _choice(
                  'no',
                  'Kann nicht',
                  Icons.thumb_down_alt_outlined,
                  () => _decline(context, widget.controller, e),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _choice(
                  'yes',
                  'Bin dabei',
                  Icons.thumb_up_alt_outlined,
                  () => _save('yes'),
                ),
                _choice(
                  'late',
                  'Komme später',
                  Icons.schedule,
                  () => setState(() {
                    _editingLate = true;
                    _arrival = e.expectedArrivalAt;
                  }),
                ),
                _choice(
                  'no',
                  'Kann nicht',
                  Icons.thumb_down_alt_outlined,
                  () => _decline(context, widget.controller, e),
                ),
              ],
            )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: RsvpStatusBadge(
              status: e.response,
              expectedArrivalAt: e.expectedArrivalAt,
              locked: true,
            ),
          ),
        if (!canRespond)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              e.locked
                  ? 'Rückmeldungen sind geschlossen.'
                  : 'Der Termin ist vorbei. Rückmeldungen sind geschlossen.',
            ),
          ),
        if (canRespond && !canDecline)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Ab einer Stunde vor Beginn ist keine Absage mehr möglich. '
              'Bitte melde dich direkt bei der Probenleitung.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_editingLate && canRespond) ...[
          const SizedBox(height: 12),
          const Text('Voraussichtlich da ab'),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(
                _arrival == null
                    ? 'Uhrzeit optional'
                    : '${DateFormat.Hm('de').format(_arrival!)} Uhr',
              ),
              onTap: _pickTime,
              trailing: _arrival == null
                  ? const Icon(Icons.edit_outlined)
                  : IconButton(
                      tooltip: 'Uhrzeit entfernen',
                      onPressed: () => setState(() => _arrival = null),
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : () => _save('late'),
            child: const Text('Späterkommen speichern'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() => _editingLate = false),
            child: const Text('Abbrechen'),
          ),
        ] else if (e.response == 'late') ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFFFFE9BF).withValues(alpha: .35),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.schedule, color: Color(0xFFA25B06), size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.expectedArrivalAt == null
                            ? 'Später · Uhrzeit offen'
                            : 'Voraussichtlich ${DateFormat.Hm('de').format(e.expectedArrivalAt!)} Uhr',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        pending
                            ? 'Auf diesem Gerät vorgemerkt'
                            : 'Rückmeldung gespeichert',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ] else if (e.response != 'open')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              pending
                  ? 'Auf diesem Gerät vorgemerkt'
                  : 'Rückmeldung gespeichert',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (!_editingLate && e.response != 'open' && canDecline)
          TextButton(
            onPressed: _busy ? null : () => _save('open'),
            child: const Text('Rückmeldung zurücknehmen'),
          ),
      ],
    );
  }
}

class _DetailMeta extends StatelessWidget {
  const _DetailMeta(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 21, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 14),
      Expanded(
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    ],
  );
}

Future<void> _decline(
  BuildContext context,
  AppController controller,
  TheaterEvent event,
) async {
  final reason = TextEditingController(text: event.declineReason);
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        4,
        24,
        MediaQuery.viewInsetsOf(ctx).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dieses Mal ohne dich.',
            style: Theme.of(ctx).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Ein kurzer Grund hilft bei der Probenplanung. Die Angabe ist freiwillig.',
          ),
          const SizedBox(height: 18),
          TextField(
            controller: reason,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Absagegrund (optional)',
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx, reason.text.trim()),
              child: const Text('Absagen'),
            ),
          ),
        ],
      ),
    ),
  );
  if (result != null && context.mounted) {
    await runAction(
      context,
      () => controller.respond(event.id, 'no', reason: result),
    );
  }
  // Let the closing sheet finish using its controller before disposal.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  reason.dispose();
}

String _icsEscape(String s) => s
    .replaceAll('\\', '\\\\')
    .replaceAll('\n', '\\n')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll('\r', '');
String _icsStamp(DateTime date) =>
    DateFormat("yyyyMMdd'T'HHmmss'Z'").format(date.toUtc());

/// RFC 5545 line folding counts UTF-8 octets without splitting a Unicode scalar.
String calendarFile(TheaterEvent event, {DateTime? now}) {
  if (event.startsAt == null) throw ArgumentError('Der Termin hat kein Datum.');
  final lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Kolpingtheater Ramsen//Theater-App//DE',
    'CALSCALE:GREGORIAN',
    'BEGIN:VEVENT',
    'UID:${_icsEscape(event.id)}@kolpingtheater.ramsen',
    'DTSTAMP:${_icsStamp(now ?? DateTime.now())}',
    'DTSTART:${_icsStamp(event.startsAt!)}',
    if (event.endsAt != null) 'DTEND:${_icsStamp(event.endsAt!)}',
    'SUMMARY:${_icsEscape(event.title)}',
    'LOCATION:${_icsEscape(event.place)}',
    if (event.description.isNotEmpty)
      'DESCRIPTION:${_icsEscape(event.description)}',
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return '${lines.map((line) {
    final result = StringBuffer();
    var octets = 0;
    for (final rune in line.runes) {
      final char = String.fromCharCode(rune);
      final bytes = utf8.encode(char).length;
      if (octets + bytes > 75) {
        result.write('\r\n ');
        octets = 1;
      }
      result.write(char);
      octets += bytes;
    }
    return result.toString();
  }).join('\r\n')}\r\n';
}

Future<void> exportEvent(BuildContext context, TheaterEvent event) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(
          Uint8List.fromList(utf8.encode(calendarFile(event))),
          mimeType: 'text/calendar',
          name: 'probe.ics',
        ),
      ],
      fileNameOverrides: const ['probe.ics'],
      subject: event.title,
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}

class EventScriptLinkScreen extends StatefulWidget {
  const EventScriptLinkScreen({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  State<EventScriptLinkScreen> createState() => _EventScriptLinkScreenState();
}

class _EventScriptLinkScreenState extends State<EventScriptLinkScreen> {
  String? _production;
  final _scenes = <String>{};
  bool _loading = false, _saving = false;
  @override
  void initState() {
    super.initState();
    _production = widget.event.productionId;
    _scenes.addAll(widget.event.sceneIds);
    if (_production != null) Future.microtask(() => _load(_production!));
  }

  Future<void> _load(String id) async {
    setState(() => _loading = true);
    await widget.controller.loadScript(id);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.controller.linkEventScript(
        widget.event.id,
        _production,
        _scenes.toList(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.controller.scripts[_production];
    return Scaffold(
      appBar: AppBar(title: const Text('Drehbuch zur Probe')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            widget.event.title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Ordne die Produktion und die geprobten Szenen zu. Mitglieder können sie anschließend direkt aus dem Termin öffnen.',
          ),
          const SizedBox(height: 22),
          DropdownButtonFormField<String>(
            initialValue:
                widget.controller.productions.any((p) => p.id == _production)
                ? _production
                : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Produktion'),
            items: widget.controller.productions
                .map(
                  (p) => DropdownMenuItem(
                    value: p.id,
                    child: Text(p.title, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: _saving
                ? null
                : (id) {
                    setState(() {
                      _production = id;
                      _scenes.clear();
                    });
                    if (id != null) _load(id);
                  },
          ),
          const SizedBox(height: 14),
          if (_loading) const LinearProgressIndicator(),
          if (doc != null) ...[
            const SectionTitle('Szenen für diese Probe'),
            const Text(
              'Ohne Auswahl wird das vollständige Drehbuch verknüpft.',
            ),
            const SizedBox(height: 10),
            ...doc.scenes.map(
              (scene) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(scene.title),
                value: _scenes.contains(scene.id),
                onChanged: _saving
                    ? null
                    : (checked) => setState(() {
                        if (checked == true) {
                          _scenes.add(scene.id);
                        } else {
                          _scenes.remove(scene.id);
                        }
                      }),
              ),
            ),
          ],
          if (!_loading && _production != null && doc == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text(
                'Das Drehbuch konnte nicht geladen werden. Versuche es mit einer Verbindung zum Server erneut.',
              ),
            ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed:
                _saving || _loading || (_production != null && doc == null)
                ? null
                : _save,
            child: Text(_saving ? 'Wird gespeichert …' : 'Zuordnung speichern'),
          ),
          if (widget.event.productionId != null)
            TextButton(
              onPressed: _saving
                  ? null
                  : () {
                      setState(() {
                        _production = null;
                        _scenes.clear();
                      });
                      _save();
                    },
              child: const Text('Zuordnung entfernen'),
            ),
        ],
      ),
    );
  }
}
