import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/tile_group.dart';
import '../../accounts/ui/accounts_admin_screen.dart';
import '../../ensemble/admin/members_admin_screen.dart';
import '../../ensemble/admin/roles_admin_screen.dart';
import '../../events/admin/events_admin_screen.dart';
import '../../events/domain/event_format.dart';
import '../../events/domain/event_selectors.dart';
import '../../feedback/feedback.dart';
import '../../galleries/ui/gallery_list_screen.dart';
import '../../messages/ui/message_composer_screen.dart';
import '../../messages/ui/push_admin_screen.dart';
import '../../participation/ui/participation_screen.dart';
import '../../polls/ui/polls_screen.dart';
import '../../productions/admin/ensembles_admin_screen.dart';
import '../../productions/admin/productions_admin_screen.dart';
import '../../rehearsal/ui/attendance_screen.dart';
import '../../rehearsal/ui/responses_screen.dart';
import '../../rehearsal/ui/scene_planner_screen.dart';
import '../../slots/ui/slot_pools_screen.dart';

/// Event kinds whose scenes are planned in advance.
const _scenePlanningKinds = {'rehearsal', 'dress'};

/// The first of [upcoming] that is a rehearsal linked to a production, i.e.
/// the event "Szenen planen" prepares; null when there is none.
TheaterEvent? nextScenePlanningEvent(Iterable<TheaterEvent> upcoming) =>
    upcoming
        .where(
          (e) =>
              _scenePlanningKinds.contains(e.kind) &&
              (e.productionId?.isNotEmpty ?? false),
        )
        .firstOrNull;

class ManagementScreen extends StatelessWidget {
  const ManagementScreen({
    super.key,
    required this.controller,
    this.embedded = false,
  });
  final AppController controller;

  /// Shown as a main section below the app bar instead of its own page.
  final bool embedded;

  List<Widget> _content(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final upcoming = upcomingEvents(
      controller,
      controller.now,
    ).where((e) => !e.fromSlotPool).toList();
    final next = upcoming.firstOrNull;
    final rehearsal = nextScenePlanningEvent(upcoming);
    final registrations = controller.openRegistrationCount;
    GroupTile tile(
      IconData icon,
      String title,
      Widget target, [
      String? subtitle,
      Color? subtitleColor,
    ]) => GroupTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      onTap: () => openPage(ctx, target),
    );
    return [
      if (next != null) ...[
        _NextEventCard(controller: controller, event: next),
        const SizedBox(height: 28),
      ],
      ResponsiveGroups(
        children: [
          TileGroup(
            title: 'Personen',
            tiles: [
              tile(
                Icons.person_add_alt,
                'Konten & Verknüpfungen',
                AccountsAdminScreen(
                  controller: controller,
                  initialView: registrations > 0 ? 'accounts' : 'people',
                  initialFilter: registrations > 0 ? 'pending' : 'all',
                ),
                registrations == 0
                    ? 'Personen, Rollen und E-Mail-Adressen'
                    : registrations == 1
                    ? '1 neue Registrierung wartet auf Zuordnung'
                    : '$registrations neue Registrierungen warten auf Zuordnung',
                registrations == 0 ? null : theme.colorScheme.primary,
              ),
              tile(
                Icons.groups_outlined,
                'Ensemble verwalten',
                MembersAdminScreen(controller: controller),
                'Personen anlegen, Rollen zuordnen',
              ),
              tile(
                Icons.badge_outlined,
                'Rollen verwalten',
                RolesAdminScreen(controller: controller),
                'Eigene Rollen und Mehrfachzuordnung',
              ),
              tile(
                Icons.diversity_3_outlined,
                'Ensembles & Verteiler',
                EnsemblesAdminScreen(controller: controller),
                'Wer zu welchem Stück gehört und warum',
              ),
              tile(
                Icons.event_available_outlined,
                'Teilnahme im Ensemble',
                ParticipationScreen(controller: controller, ensemble: true),
                'Rückmeldungen und Anwesenheit der letzten sechs Monate',
              ),
            ],
          ),
          TileGroup(
            title: 'Planung',
            tiles: [
              tile(
                Icons.calendar_month_outlined,
                'Termine verwalten',
                EventsAdminScreen(controller: controller),
                'Anlegen, ändern, Kalender',
              ),
              tile(
                Icons.edit_calendar_outlined,
                'Terminfinder',
                SlotPoolsScreen(controller: controller),
                'Zeitfenster zum Buchen, z. B. für Fototermine',
              ),
              tile(
                Icons.auto_stories_outlined,
                'Produktionen & Besetzung',
                ProductionsAdminScreen(controller: controller),
                'Stücke, Rollen im Drehbuch, Regie',
              ),
              if (rehearsal != null)
                tile(
                  Icons.playlist_add_check,
                  'Szenen planen',
                  ScenePlannerScreen(controller: controller, event: rehearsal),
                  'Für ${rehearsal.title} · ${eventDate(rehearsal)}',
                ),
            ],
          ),
          TileGroup(
            title: 'Kommunikation',
            tiles: [
              tile(
                Icons.chat_bubble_outline,
                'Mitteilung schreiben',
                MessageComposerScreen(controller: controller),
                'An alle, Rollen, Stücke oder einzelne Personen',
              ),
              tile(
                Icons.poll_outlined,
                'Abstimmungen',
                PollsScreen(controller: controller),
                'Fragen stellen und auswerten',
              ),
              tile(
                Icons.notifications_outlined,
                'Push senden',
                PushAdminScreen(controller: controller),
                'Eigene Pushes und Versandstatus',
              ),
              if (feedbackAvailable(controller))
                tile(
                  Icons.feedback_outlined,
                  'Feedback',
                  FeedbackAdminScreen(controller: controller),
                  'Ideen und Fehlermeldungen der Mitglieder',
                ),
            ],
          ),
          TileGroup(
            title: 'Medien',
            tiles: [
              tile(
                Icons.photo_library_outlined,
                'Galerien',
                GalleryListScreen(controller: controller),
                'Alben und Freigaben',
              ),
            ],
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!embedded) {
      return AdminPage(
        controller: controller,
        title: 'Administration',
        children: _content,
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: RefreshIndicator(
          onRefresh: () => refreshWithFeedback(context, controller),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
            children: [
              const PageHeader(
                'Administration.',
                subtitle: 'Alles für die Theaterleitung an einem Ort.',
              ),
              ..._content(context),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dark stage card for the next event with the two most common actions.
class _NextEventCard extends StatelessWidget {
  const _NextEventCard({required this.controller, required this.event});
  final AppController controller;
  final TheaterEvent event;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [StageTheme.ink, Color(0xFF2C3530)],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Nächster Termin', color: Color(0xFFFFA584)),
          const SizedBox(height: 12),
          Text(
            event.title,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              _Fact(Icons.event_outlined, eventDate(event)),
              _Fact(Icons.schedule, eventTime(event)),
              if (event.place.isNotEmpty)
                _Fact(Icons.place_outlined, event.place),
              if (event.attendeeCount > 0)
                _Fact(
                  Icons.how_to_reg_outlined,
                  '${event.attendeeCount} dabei',
                ),
            ],
          ),
          const SizedBox(height: 22),
          LayoutBuilder(
            builder: (context, constraints) {
              final buttons = <Widget>[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: StageTheme.orangeDeep,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => openPage(
                    context,
                    AttendanceEditorScreen(
                      controller: controller,
                      event: event,
                    ),
                  ),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Anwesenheit erfassen'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                    minimumSize: const Size(48, 52),
                  ),
                  onPressed: () => openPage(
                    context,
                    ResponsesAdminScreen(controller: controller, event: event),
                  ),
                  icon: const Icon(Icons.how_to_reg_outlined),
                  label: const Text('Rückmeldungen'),
                ),
              ];
              // Equal halves side by side, full-width stack on phones.
              if (constraints.maxWidth < 440) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    buttons[0],
                    const SizedBox(height: 10),
                    buttons[1],
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: buttons[0]),
                  const SizedBox(width: 10),
                  Expanded(child: buttons[1]),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: const Color(0xFFFFA584)),
      const SizedBox(width: 6),
      Flexible(
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    ],
  );
}
