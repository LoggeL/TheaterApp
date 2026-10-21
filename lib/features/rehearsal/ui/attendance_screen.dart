import 'package:flutter/material.dart';

import '../../../core/account_permissions.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../events/domain/event_format.dart';
import '../domain/implicit_attendance.dart';
import 'responses_screen.dart';
import 'scene_planner_screen.dart';

class AttendanceEditorScreen extends StatefulWidget {
  const AttendanceEditorScreen({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  State<AttendanceEditorScreen> createState() => _AttendanceEditorScreenState();
}

class _AttendanceEditorScreenState extends State<AttendanceEditorScreen> {
  final Map<int, bool?> _changes = {};
  final Map<int, int> _versions = {};
  String _search = '';
  bool _busy = false;

  /// The attendance as last saved or queued, without unsaved changes.
  bool? _saved(int id) =>
      jsonMap(widget.controller.checkinsByEvent[widget.event.id])[id.toString()]
          as bool?;
  bool? present(int id) => _changes.containsKey(id) ? _changes[id] : _saved(id);

  void _set(int id, bool? value) {
    if (value == _saved(id)) {
      _changes.remove(id);
      _versions.remove(id);
      return;
    }
    _versions.putIfAbsent(
      id,
      () =>
          intValue(widget.controller.checkinVersions['${widget.event.id}:$id']),
    );
    _changes[id] = value;
  }

  Future<void> _save({bool openScenes = false}) async {
    setState(() => _busy = true);
    try {
      final changed = _changes.isNotEmpty;
      var outcome = ActionOutcome.synced;
      if (changed) {
        outcome = await widget.controller.performAction({
          'action': 'checkin.save',
          'eventId': widget.event.id,
          'members': [
            for (final item in _changes.entries)
              {
                'id': item.key,
                'present': item.value,
                'version': _versions[item.key] ?? 0,
              },
          ],
        });
      }
      if (mounted) {
        setState(() {
          _changes.clear();
          _versions.clear();
        });
        if (changed) {
          showDone(
            context,
            outcomeText(
              outcome,
              done: 'Anwesenheit gespeichert.',
              queued: 'Anwesenheit vorgemerkt – wird bei Verbindung gesendet.',
            ),
          );
        }
        if (openScenes) {
          openPage(
            context,
            ScenePlannerScreen(
              controller: widget.controller,
              event:
                  widget.controller.events
                      .where((e) => e.id == widget.event.id)
                      .firstOrNull ??
                  widget.event,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DiscardGuard(
    dirty: _changes.isNotEmpty,
    child: AdminPage(
      controller: widget.controller,
      permission: eventsPermission,
      title: 'Anwesenheit',
      children: (context) {
        final controller = widget.controller, event = widget.event;
        // Implicit attendees of an auto-accepted event count as confirmed.
        final responses = plannedResponses(controller, event);
        int unrecordedFirst(TheaterMember a, TheaterMember b) {
          final open = (_saved(a.id) == null ? 0 : 1).compareTo(
            _saved(b.id) == null ? 0 : 1,
          );
          return open != 0
              ? open
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }

        // Sorted by the saved state, so rows stay in place while marking.
        final members =
            controller.members
                .where(
                  (m) =>
                      m.active &&
                      m.inAudience(
                        event.roleIds,
                        event.personIds,
                        controller.ensemblesOf(event.productionIds),
                      ),
                )
                .toList()
              ..sort(unrecordedFirst);
        final here = members.where((m) => present(m.id) == true).length,
            away = members.where((m) => present(m.id) == false).length;
        final confirmed = members
            .where(
              (m) =>
                  responses[m.id.toString()] == 'yes' && present(m.id) != true,
            )
            .toList();
        final queued = controller.outbox.any(
          (a) =>
              !a.failed &&
              a.payload['action'] == 'checkin.save' &&
              a.payload['eventId'] == event.id,
        );
        final theme = Theme.of(context);
        final unsaved = _changes.length;
        return [
          Text('${event.title} · ${eventDate(event)}'),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Vor Ort', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '$here da · ${away == 1 ? '1 fehlt' : '$away fehlen'} · '
                    '${members.length - here - away} nicht erfasst',
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        unsaved > 0
                            ? Icons.edit_outlined
                            : queued
                            ? Icons.cloud_upload_outlined
                            : Icons.check_circle_outline,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          unsaved == 1
                              ? '1 Änderung noch nicht gespeichert'
                              : unsaved > 1
                              ? '$unsaved Änderungen noch nicht gespeichert'
                              : queued
                              ? 'Auf diesem Gerät vorgemerkt'
                              : 'Alles gespeichert',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy || confirmed.isEmpty
                  ? null
                  : () => setState(() {
                      for (final m in confirmed) {
                        _set(m.id, true);
                      }
                    }),
              icon: const Icon(Icons.done_all),
              label: const Text('Alle Zugesagten als da markieren'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Mitglied suchen',
            ),
            onChanged: (s) => setState(() => _search = s),
          ),
          const SizedBox(height: 16),
          for (final m in members.where(
            (m) => m.name.toLowerCase().contains(_search.toLowerCase()),
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _AttendanceRow(
                controller: controller,
                member: m,
                response: memberResponseLabel(controller, event, m.id),
                present: present(m.id),
                changed: _changes.containsKey(m.id),
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _set(m.id, value)),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy || _changes.isEmpty ? null : _save,
            child: const Text('Änderungen speichern'),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _save(openScenes: true),
            icon: const Icon(Icons.playlist_add_check),
            label: Text(
              _changes.isEmpty
                  ? 'Spielbare Szenen ansehen'
                  : 'Speichern und Szenen ansehen',
            ),
          ),
        ];
      },
    ),
  );
}

/// One invited person with their response and a Da/Fehlt choice. Tapping the
/// selected choice again leaves the person unrecorded.
class _AttendanceRow extends StatelessWidget {
  const _AttendanceRow({
    required this.controller,
    required this.member,
    required this.response,
    required this.present,
    required this.changed,
    required this.onChanged,
  });
  final AppController controller;
  final TheaterMember member;
  final String response;
  final bool? present;
  final bool changed;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choice = SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: true, label: Text('Da'), icon: Icon(Icons.check)),
        ButtonSegment(
          value: false,
          label: Text('Fehlt'),
          icon: Icon(Icons.close),
        ),
      ],
      selected: {?present},
      emptySelectionAllowed: true,
      showSelectedIcon: false,
      onSelectionChanged: onChanged == null
          ? null
          : (value) => onChanged!(value.firstOrNull),
    );
    final person = Row(
      children: [
        MemberAvatar(
          controller: controller,
          avatarId: member.avatarId,
          initials: member.initials,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(member.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                changed ? '$response · nicht gespeichert' : response,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          // Narrow rows place the choice below the name.
          builder: (context, constraints) =>
              constraints.maxWidth <
                  420 * MediaQuery.textScalerOf(context).scale(1)
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    person,
                    const SizedBox(height: 12),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: choice,
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: person),
                    const SizedBox(width: 8),
                    choice,
                  ],
                ),
        ),
      ),
    );
  }
}
