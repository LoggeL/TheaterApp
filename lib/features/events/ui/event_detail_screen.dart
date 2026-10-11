import 'package:flutter/material.dart';

import '../../../app/shell/app_navigation.dart';
import '../../../app/shell/app_section.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../rehearsal/ui/attendance_screen.dart';
import '../../rehearsal/ui/responses_screen.dart';
import '../../rehearsal/ui/scene_planner_screen.dart';
import '../../scripts/ui/script_reader_screen.dart';
import '../../slots/ui/slot_event_notice.dart';
import '../data/ics_export.dart';
import '../domain/event_dates.dart';
import '../domain/event_format.dart';
import 'event_style.dart';
import 'rsvp/rsvp_panel.dart';

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
          selectedIndex: AppSection.schedule.index,
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
        selectedIndex: AppSection.schedule.index,
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
          const Eyebrow('Kolpingtheater Ramsen'),
          const SizedBox(height: 12),
          Text(
            event.title,
            style: embedded
                ? Theme.of(context).textTheme.headlineMedium
                : Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          Builder(
            builder: (context) {
              final now = DateTime.now();
              final marker = eventMarker(event, now);
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  EventKindPill(event.kind),
                  if (marker != null) EventMarker(marker),
                  if (event.inSeries)
                    Tooltip(
                      message: 'Serientermin',
                      child: StatePill(
                        'Serie',
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        icon: Icons.repeat,
                      ),
                    ),
                  if (eventIsPast(event, now))
                    StatePill(
                      'Vorbei',
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      icon: Icons.history,
                    ),
                ],
              );
            },
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
                  if (event.roleIds.isNotEmpty ||
                      event.personIds.isNotEmpty) ...[
                    SizedBox(height: embedded ? 10 : 17),
                    _DetailMeta(
                      Icons.group_outlined,
                      'Für ${controller.audienceLabel(event.roleIds, event.personIds, event.productionIds)}',
                    ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: embedded ? 16 : 24),
          if (event.fromSlotPool)
            SlotEventNotice(controller: controller, event: event)
          else
            RsvpPanel(
              key: ValueKey(event.id),
              controller: controller,
              event: event,
              compact: embedded,
            ),
          if (event.declineReason.isNotEmpty && !event.fromSlotPool)
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
                onTap: () => openPage(
                  context,
                  ScriptReaderScreen(
                    controller: controller,
                    productionId: event.productionId!,
                    initialSceneId: event.sceneIds.firstOrNull,
                  ),
                ),
              ),
            ),
          ],
          if (controller.user?.isAdmin == true) ...[
            const SectionTitle('Probenleitung'),
            OutlinedButton.icon(
              onPressed: () => openPage(
                context,
                ResponsesAdminScreen(controller: controller, event: event),
              ),
              icon: const Icon(Icons.people_outline),
              label: const Text('Rückmeldungen ansehen'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => openPage(
                context,
                AttendanceEditorScreen(controller: controller, event: event),
              ),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Anwesenheit erfassen'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => openPage(
                context,
                ScenePlannerScreen(controller: controller, event: event),
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
