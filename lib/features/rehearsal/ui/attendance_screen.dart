import 'package:flutter/material.dart';

import '../../../core/account_permissions.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/visible_listenable_builder.dart';
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

enum _AttendanceFilter { all, unrecorded, present, absent }

class _AttendanceEditorScreenState extends State<AttendanceEditorScreen> {
  final Map<int, bool?> _changes = {};
  final Map<int, int> _versions = {};
  final _searchController = TextEditingController();
  String _search = '';
  _AttendanceFilter _filter = _AttendanceFilter.all;
  bool _busy = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// The attendance as last saved or queued, without unsaved changes.
  bool? _saved(int id, [JsonMap? savedMap]) =>
      (savedMap ?? readJsonMap(widget.controller.checkinsByEvent[widget.event.id]))[
          id.toString()] as bool?;
  bool? present(int id, [JsonMap? savedMap]) =>
      _changes.containsKey(id) ? _changes[id] : _saved(id, savedMap);

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
    child: VisibleListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller, event = widget.event;
        final allowed = controller.user?.can(eventsPermission) == true;
        final queued = controller.outbox.any(
          (a) =>
              !a.failed &&
              a.payload['action'] == 'checkin.save' &&
              a.payload['eventId'] == event.id,
        );
        return Scaffold(
          body: AdminPage(
            controller: controller,
            permission: eventsPermission,
            title: 'Anwesenheit',
            slivers: (context) {
              final savedMap = readJsonMap(
                controller.checkinsByEvent[event.id],
              );
              // Implicit attendees of an auto-accepted event count as confirmed.
              final responses = plannedResponses(controller, event);
              final ensembles = controller.ensemblesOf(event.productionIds);
              int unrecordedFirst(TheaterMember a, TheaterMember b) {
                final open = (_saved(a.id, savedMap) == null ? 0 : 1).compareTo(
                  _saved(b.id, savedMap) == null ? 0 : 1,
                );
                return open != 0
                    ? open
                    : a.name.toLowerCase().compareTo(b.name.toLowerCase());
              }

              // Sorted by the saved state, so rows stay in place while marking.
              final members = [
                for (final m in controller.members)
                  if (m.active &&
                      m.inAudience(event.roleIds, event.personIds, ensembles))
                    m,
              ]..sort(unrecordedFirst);
              var here = 0, away = 0;
              final confirmed = <TheaterMember>[];
              final auto = controller.autoCheckins(event.id);
              var hasAutoSaved = false;
              final query = _search.trim().toLowerCase();
              final filtered = <TheaterMember>[];
              for (final m in members) {
                final p = present(m.id, savedMap);
                if (p == true) {
                  here++;
                } else if (p == false) {
                  away++;
                }
                if (responses[m.id.toString()] == 'yes' && p != true) {
                  confirmed.add(m);
                }
                if (!hasAutoSaved &&
                    auto.contains(m.id) &&
                    _saved(m.id, savedMap) == true) {
                  hasAutoSaved = true;
                }
                if ((query.isEmpty ||
                        '${m.name} ${controller.roleNames(m.roleIds)}'
                            .toLowerCase()
                            .contains(query)) &&
                    switch (_filter) {
                      _AttendanceFilter.all => true,
                      _AttendanceFilter.unrecorded => p == null,
                      _AttendanceFilter.present => p == true,
                      _AttendanceFilter.absent => p == false,
                    }) {
                  filtered.add(m);
                }
              }
              final unrecorded = members.length - here - away;
              final theme = Theme.of(context);
              return [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${event.title} · ${eventDate(event)}'),
                        const SizedBox(height: 20),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Vor Ort',
                                  style: theme.textTheme.titleLarge,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '$here da · ${away == 1 ? '1 fehlt' : '$away fehlen'} · '
                                  '$unrecorded nicht erfasst',
                                ),
                                if (hasAutoSaved)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      'Niemand hat erfasst: Die Zusagen wurden automatisch als da übernommen. Korrigieren geht jederzeit.',
                                      key: const ValueKey('attendance-auto'),
                                      style: theme.textTheme.bodySmall,
                                    ),
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
                            label: const Text(
                              'Alle Zugesagten als da markieren',
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Name oder Rolle suchen',
                            suffixIcon: _search.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Suche leeren',
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _search = '');
                                    },
                                    icon: const Icon(Icons.close),
                                  ),
                          ),
                          onChanged: (s) => setState(() => _search = s),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final (value, label) in [
                              (_AttendanceFilter.all, 'Alle (${members.length})'),
                              (
                                _AttendanceFilter.unrecorded,
                                'Nicht erfasst ($unrecorded)',
                              ),
                              (_AttendanceFilter.present, 'Da ($here)'),
                              (_AttendanceFilter.absent, 'Fehlt ($away)'),
                            ])
                              ChoiceChip(
                                label: Text(label),
                                selected: _filter == value,
                                onSelected: (_) =>
                                    setState(() => _filter = value),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (members.isNotEmpty && filtered.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(
                              query.isNotEmpty
                                  ? 'Keine Treffer für „${_search.trim()}“.'
                                  : 'Niemand in diesem Filter.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (filtered.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    sliver: SliverList.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final m = filtered[index];
                        final baseLabel = memberResponseLabel(
                          controller,
                          event,
                          m.id,
                        );
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _AttendanceRow(
                            controller: controller,
                            member: m,
                            // Adopted from the own commitment after the deadline
                            // (Termin-Kisten): an admin can still correct it.
                            response:
                                !_changes.containsKey(m.id) &&
                                    _saved(m.id, savedMap) == true &&
                                    auto.contains(m.id)
                                ? '$baseLabel · automatisch übernommen'
                                : baseLabel,
                            present: present(m.id, savedMap),
                            changed: _changes.containsKey(m.id),
                            onChanged: _busy
                                ? null
                                : (value) => setState(() => _set(m.id, value)),
                          ),
                        );
                      },
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 32),
                  sliver: SliverToBoxAdapter(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _save(openScenes: true),
                      icon: const Icon(Icons.playlist_add_check),
                      label: Text(
                        _changes.isEmpty
                            ? 'Spielbare Szenen ansehen'
                            : 'Speichern und Szenen ansehen',
                      ),
                    ),
                  ),
                ),
              ];
            },
          ),
          bottomNavigationBar: allowed
              ? _SaveBar(
                  unsaved: _changes.length,
                  queued: queued,
                  onSave: _busy || _changes.isEmpty ? null : _save,
                )
              : null,
        );
      },
    ),
  );
}

/// Stays at the bottom while scrolling: unsaved status and the save action.
class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.unsaved,
    required this.queued,
    required this.onSave,
  });
  final int unsaved;
  final bool queued;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = unsaved == 1
        ? '1 Änderung noch nicht gespeichert'
        : unsaved > 1
        ? '$unsaved Änderungen noch nicht gespeichert'
        : queued
        ? 'Auf diesem Gerät vorgemerkt'
        : 'Alles gespeichert';
    return Material(
      key: const ValueKey('attendance-save-bar'),
      color: theme.colorScheme.surfaceContainer,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 12),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
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
                      Flexible(
                        child: Text(label, style: theme.textTheme.bodySmall),
                      ),
                    ],
                  ),
                  FilledButton(
                    onPressed: onSave,
                    child: const Text('Änderungen speichern'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
