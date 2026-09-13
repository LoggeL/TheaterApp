import 'polls.dart';
import 'responsive.dart';
import '../core/event_types.dart';
import 'calendar.dart';
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
import 'messages.dart';

String eventDate(TheaterEvent event) => event.startsAt == null
    ? 'Datum noch offen'
    : DateFormat('EEEE, d. MMMM', 'de').format(event.startsAt!);
String eventTime(TheaterEvent event) => event.time.isNotEmpty
    ? event.time
    : event.startsAt == null
    ? 'Uhrzeit offen'
    : '${DateFormat.Hm('de').format(event.startsAt!)}${event.endsAt == null ? '' : '–${DateFormat.Hm('de').format(event.endsAt!)}'} Uhr';
String statusText(String status) => switch (status) {
  'yes' => 'Du bist dabei',
  'late' => 'Du kommst später',
  'no' => 'Du hast abgesagt',
  _ => 'Rückmeldung offen',
};
Color statusColor(String status) => switch (status) {
  'yes' => StageTheme.green,
  'late' => const Color(0xFFA25B06),
  'no' => const Color(0xFFB34343),
  _ => const Color(0xFF657168),
};

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

class TodayScreen extends StatelessWidget {
  const TodayScreen({
    super.key,
    required this.controller,
    required this.onPlan,
    required this.onScripts,
  });
  final AppController controller;
  final VoidCallback onPlan, onScripts;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final upcoming =
        controller.events
            .where(
              (e) =>
                  e.startsAt == null || (e.endsAt ?? e.startsAt!).isAfter(now),
            )
            .toList()
          ..sort(
            (a, b) => (a.startsAt ?? DateTime(9999)).compareTo(
              b.startsAt ?? DateTime(9999),
            ),
          );
    final next = upcoming.isEmpty ? null : upcoming.first;
    final unanswered = upcoming.where((e) => e.needsResponse).length;
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Text(
            'Hallo, ${controller.user?.firstName ?? 'Ensemble'}.',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          Text(
            DateFormat('EEEE, d. MMMM', 'de').format(now),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 26),
          if (next != null)
            _NextRehearsal(event: next, controller: controller)
          else
            const Card(
              child: EmptyState(
                icon: Icons.event_available_outlined,
                title: 'Keine anstehenden Termine',
                message: 'Aktuell stehen keine kommenden Termine an.',
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _QuickTile(
                  icon: Icons.mark_email_unread_outlined,
                  value: '$unanswered',
                  label: 'Rückmeldungen offen',
                  onTap: onPlan,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _QuickTile(
                  icon: Icons.auto_stories_outlined,
                  value: '${controller.productions.length}',
                  label: 'Drehbücher für dich',
                  onTap: onScripts,
                ),
              ),
            ],
          ),
          if (controller.polls.any((p) => !p.isClosed)) ...[
            const SectionTitle('Abstimmungen'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.poll_outlined),
                title: Text(
                  controller.polls.firstWhere((p) => !p.isClosed).title,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PollsScreen(controller: controller),
                  ),
                ),
              ),
            ),
          ],
          SectionTitle(
            'Dein Drehbuch',
            trailing: TextButton(
              onPressed: onScripts,
              child: const Text('Alle ansehen'),
            ),
          ),
          if (controller.productions.isEmpty)
            const Card(
              child: EmptyState(
                icon: Icons.menu_book_outlined,
                title: 'Noch kein Stück hinterlegt',
                message:
                    'Sobald eure Drehbuchquelle angebunden ist, findest du hier eure Produktionen.',
              ),
            )
          else
            _ScriptShortcut(
              production: controller.productions.first,
              controller: controller,
            ),
          SectionTitle(
            'Als Nächstes',
            trailing: TextButton(
              onPressed: onPlan,
              child: const Text('Zum Plan'),
            ),
          ),
          ...upcoming
              .skip(1)
              .take(3)
              .map(
                (event) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: EventCard(event: event, controller: controller),
                ),
              ),
          if (upcoming.length <= 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'Weitere Termine erscheinen hier, sobald sie geplant sind.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (controller.messages.isNotEmpty) ...[
            const SectionTitle('Mitteilungen'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(textValue(controller.messages.first['title'])),
                subtitle: Text(
                  textValue(controller.messages.first['body']),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MessagesScreen(controller: controller),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NextRehearsal extends StatelessWidget {
  const _NextRehearsal({required this.event, required this.controller});
  final TheaterEvent event;
  final AppController controller;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(23),
    decoration: BoxDecoration(
      color: StageTheme.ink,
      borderRadius: BorderRadius.circular(28),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Eyebrow('Dein nächster Termin', color: Color(0xFFFFB18A)),
            ),
            if (event.startsAt != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  DateFormat('dd.MM.').format(event.startsAt!),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 21),
        Text(
          event.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 27,
            height: 1.16,
            letterSpacing: -.6,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 20),
        _HeroMeta(Icons.schedule, eventTime(event)),
        const SizedBox(height: 9),
        _HeroMeta(
          Icons.location_on_outlined,
          event.place.isEmpty ? 'Ort folgt' : event.place,
        ),
        const SizedBox(height: 20),
        StatePill(
          statusText(event.response),
          color: event.response == 'yes'
              ? const Color(0xFFA8D6B6)
              : event.response == 'no'
              ? const Color(0xFFFFB3AB)
              : const Color(0xFFFFB18A),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: StageTheme.orange,
              foregroundColor: Colors.white,
            ),
            onPressed: () => openEvent(context, controller, event.id),
            icon: const Icon(Icons.arrow_forward, size: 19),
            label: const Text('Termin ansehen'),
          ),
        ),
      ],
    ),
  );
}

class _HeroMeta extends StatelessWidget {
  const _HeroMeta(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: const Color(0xFFBFC8C0), size: 17),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          label,
          style: const TextStyle(color: Color(0xFFDAE0D9), fontSize: 13),
        ),
      ),
    ],
  );
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.icon,
    required this.value,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String value, label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const Spacer(),
                Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ScriptShortcut extends StatelessWidget {
  const _ScriptShortcut({required this.production, required this.controller});
  final Production production;
  final AppController controller;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ScriptReaderScreen(
            controller: controller,
            productionId: production.id,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFEBE4D9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.auto_stories_outlined,
                size: 28,
                color: StageTheme.ink,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    production.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 7),
                  Text(
                    controller.scripts.containsKey(production.id)
                        ? 'Offline bereit · Weiterlesen'
                        : 'Öffnen & offline speichern',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward, size: 20),
          ],
        ),
      ),
    ),
  );
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
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final events =
        widget.controller.events.where((e) {
          final future =
              e.startsAt == null || (e.endsAt ?? e.startsAt!).isAfter(now);
          final filter = switch (_filter) {
            1 => future && e.needsResponse,
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
                  SegmentedButton<bool>(
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
                  if (!_calendar)
                    SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (var i = 0; i < 4; i++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(
                                  [
                                    'Kommend',
                                    'Offen',
                                    'Zugesagt',
                                    'Vergangen',
                                  ][i],
                                ),
                                selected: _filter == i,
                                onSelected: (_) => setState(() => _filter = i),
                              ),
                            ),
                        ],
                      ),
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
                  const SizedBox(height: 11),
                  StatePill(
                    event.locked
                        ? 'Rückmeldung geschlossen'
                        : statusText(event.response),
                    color: event.locked
                        ? StageTheme.violet
                        : statusColor(event.response),
                  ),
                ],
              ),
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
        return Scaffold(
          appBar: AppBar(),
          body: const EmptyState(
            icon: Icons.event_busy,
            title: 'Termin nicht verfügbar',
            message:
                'Der Termin wurde entfernt oder ist für dein Konto nicht sichtbar.',
          ),
        );
      }
      final event = matches.first;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Termin'),
          actions: [
            IconButton(
              tooltip: 'Kalenderdatei teilen',
              onPressed: event.startsAt == null
                  ? null
                  : () => runAction(context, () => exportEvent(context, event)),
              icon: const Icon(Icons.ios_share),
            ),
          ],
        ),
        body: ListView(
          padding: pagePadding(context, top: 16, bottom: 36),
          children: [
            Eyebrow(
              event.group.isEmpty ? 'Kolpingtheater Ramsen' : event.group,
            ),
            const SizedBox(height: 12),
            Text(event.title, style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 8),
            Text(
              eventTypeLabel(event.kind),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (event.description.isNotEmpty) ...[
              const SizedBox(height: 20),
              SelectableText(event.description),
            ],
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(19),
                child: Column(
                  children: [
                    _DetailMeta(
                      Icons.calendar_today_outlined,
                      eventDate(event),
                    ),
                    const SizedBox(height: 17),
                    _DetailMeta(Icons.schedule, eventTime(event)),
                    const SizedBox(height: 17),
                    _DetailMeta(
                      Icons.location_on_outlined,
                      event.place.isEmpty
                          ? 'Ort wird noch bekannt gegeben'
                          : event.place,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            RsvpPanel(controller: controller, event: event),
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
                    builder: (_) => ScenePlannerScreen(
                      controller: controller,
                      event: event,
                    ),
                  ),
                ),
                icon: const Icon(Icons.link),
                label: const Text('Szenen planen'),
              ),
            ],
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: event.startsAt == null
                  ? null
                  : () => runAction(context, () => exportEvent(context, event)),
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('Für den Kalender exportieren'),
            ),
          ],
        ),
      );
    },
  );
}

class RsvpPanel extends StatefulWidget {
  const RsvpPanel({super.key, required this.controller, required this.event});
  final AppController controller;
  final TheaterEvent event;
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
    final color = statusColor(status);
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
          onTap: _busy || widget.event.locked ? null : action,
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
    final pending = widget.controller.outbox.any(
      (a) =>
          !a.failed &&
          a.payload['action'] == 'attendance' &&
          a.payload['eventId'] == e.id,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Bist du dabei?', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        _choice(
          'yes',
          'Bin dabei',
          Icons.check_circle_outline,
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
          Icons.close,
          () => _decline(context, widget.controller, e),
        ),
        if (e.locked)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text('Rückmeldungen sind geschlossen.'),
          ),
        if (_editingLate && !e.locked) ...[
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
        if (!_editingLate && e.response != 'open' && !e.locked)
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
