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
import '../admin/event_editor_screen.dart';
import '../data/ics_export.dart';
import '../domain/event_dates.dart';
import '../domain/event_format.dart';
import 'event_place.dart';
import 'event_style.dart';
import 'rsvp/rsvp_actions.dart';
import 'rsvp/rsvp_panel.dart';

class EventDetailScreen extends StatefulWidget {
  const EventDetailScreen({
    super.key,
    required this.controller,
    required this.eventId,
    this.openDecline = false,
  });
  final AppController controller;
  final String eventId;

  /// Opens the decline sheet once the event is there, e.g. from the
  /// "Du bist eingeplant" reminder (`?intent=decline`).
  final bool openDecline;
  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  /// The decline sheet opens at most once, also across rebuilds.
  late bool _declinePending = widget.openDecline;

  AppController get controller => widget.controller;

  /// A deep link can arrive before the first refresh: this waits until the
  /// event is loaded.
  void _offerDecline(TheaterEvent event) {
    _declinePending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || event.response == 'no' || !event.addressedToMe) return;
      if (!controller.canDecline(event)) {
        showDone(
          context,
          controller.canRespondTo(event)
              ? 'Ab einer Stunde vor Beginn ist keine Absage mehr möglich. '
                    'Bitte melde dich direkt bei der Probenleitung.'
              : 'Für diesen Termin sind keine Rückmeldungen mehr möglich.',
        );
        return;
      }
      declineEvent(context, controller, event);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final matches = controller.events.where((e) => e.id == widget.eventId);
      if (_declinePending && matches.isNotEmpty) _offerDecline(matches.first);
      if (matches.isEmpty) {
        return DesktopRouteFrame(
          controller: controller,
          selectedIndex: AppSection.schedule.index,
          child: Scaffold(
            appBar: AppBar(title: const Text('Termin')),
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
              if (controller.user?.canManageEvents == true)
                IconButton(
                  tooltip: event.fromSlotPool
                      ? 'Im Terminfinder öffnen'
                      : 'Termin bearbeiten',
                  onPressed: () async {
                    final route = Navigator.of(context);
                    final result = await editEvent(context, controller, event);
                    // A deleted event leaves nothing to show here.
                    if (result == EventEditorResult.deleted) route.pop();
                  },
                  icon: Icon(
                    event.fromSlotPool
                        ? Icons.edit_calendar_outlined
                        : Icons.edit_outlined,
                  ),
                ),
              IconButton(
                tooltip: 'In Kalender übernehmen',
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

  /// Who is invited; shown for every event, also for ensembles only.
  String get _audience {
    final label = controller.audienceLabel(
      event.roleIds,
      event.personIds,
      event.productionIds,
    );
    return 'Für ${label == 'Alle' ? 'alle' : label}';
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = constraints.maxWidth > 840
          ? (constraints.maxWidth - 840) / 2 + 24
          : 24.0;
      final now = controller.now;
      final marker = eventMarker(event, now);
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      final user = controller.user;
      final manager = user?.canManageEvents == true;
      final editor = event.lastEditedBy == null
          ? null
          : controller.members
                .where((m) => m.id == event.lastEditedBy)
                .firstOrNull
                ?.name;
      final gap = SizedBox(height: embedded ? 10 : 17);
      return ListView(
        primary: false,
        padding: EdgeInsets.fromLTRB(side, 16, side, 36),
        children: [
          Eyebrow(eventDate(event)),
          const SizedBox(height: 12),
          Text(
            event.title,
            style: embedded
                ? Theme.of(context).textTheme.headlineMedium
                : Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              EventKindPill(event.kind),
              if (marker != null) EventMarker(marker),
              if (event.inSeries)
                Tooltip(
                  message: 'Serientermin',
                  child: StatePill('Serie', color: muted, icon: Icons.repeat),
                ),
              if (eventIsPast(event, now))
                StatePill('Vorbei', color: muted, icon: Icons.history),
              if (!event.addressedToMe) const NotInvitedPill(),
              if (event.autoAccept && !event.fromSlotPool)
                StatePill(
                  'Alle gelten als zugesagt',
                  color: muted,
                  icon: Icons.how_to_reg_outlined,
                ),
            ],
          ),
          SizedBox(height: embedded ? 16 : 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(19),
              child: Column(
                children: [
                  _DetailMeta(Icons.calendar_today_outlined, eventDate(event)),
                  gap,
                  _DetailMeta(Icons.schedule, eventTime(event)),
                  gap,
                  EventPlaceRow(event.place),
                  gap,
                  _DetailMeta(Icons.group_outlined, _audience),
                ],
              ),
            ),
          ),
          SizedBox(height: embedded ? 16 : 24),
          if (event.fromSlotPool)
            SlotEventNotice(controller: controller, event: event)
          else if (!event.addressedToMe)
            Card(
              child: ListTile(
                leading: const Icon(Icons.person_off_outlined),
                title: const Text('Du bist nicht eingeladen'),
                subtitle: Text(
                  user?.isAdmin == true
                      ? 'Der Termin richtet sich an andere. Du siehst ihn, weil du Admin bist.'
                      : 'Der Termin richtet sich an andere. Du siehst ihn, weil du Termine verwaltest.',
                ),
              ),
            )
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
          if (event.description.isNotEmpty) ...[
            const SectionTitle('Beschreibung'),
            SelectableText(event.description),
          ],
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
          if (manager) ...[
            const SectionTitle('Probenleitung'),
            // Several people may plan events; who changed it last helps to ask.
            if (editor != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Zuletzt geändert von $editor',
                  style: TextStyle(color: muted),
                ),
              ),
            // The route offers editing in its app bar; inline it heads here.
            if (embedded) ...[
              FilledButton.tonalIcon(
                onPressed: () => editEvent(context, controller, event),
                icon: Icon(
                  event.fromSlotPool
                      ? Icons.edit_calendar_outlined
                      : Icons.edit_outlined,
                ),
                label: Text(
                  event.fromSlotPool ? 'Im Terminfinder öffnen' : 'Bearbeiten',
                ),
              ),
              const SizedBox(height: 12),
            ],
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
          // The route has the export in its app bar.
          if (embedded) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: event.startsAt == null
                  ? null
                  : () => runAction(context, () => exportEvent(context, event)),
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('In Kalender übernehmen'),
            ),
          ],
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
