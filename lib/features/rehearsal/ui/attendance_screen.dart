import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../events/domain/event_format.dart';
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
  bool? present(int id) => _changes.containsKey(id)
      ? _changes[id]
      : jsonMap(widget.controller.checkinsByEvent[widget.event.id])[id
                .toString()]
            as bool?;
  Future<void> _save({bool openScenes = false}) async {
    setState(() => _busy = true);
    try {
      if (_changes.isNotEmpty) {
        await widget.controller.performAction({
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.pendingCount > 0
                  ? 'Auf diesem Gerät vorgemerkt.'
                  : 'Anwesenheit gespeichert.',
            ),
          ),
        );
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
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Anwesenheit',
    children: (context) {
      final members = widget.controller.members
          .where(
            (m) =>
                m.active &&
                m.inAudience(
                  widget.event.roleIds,
                  widget.event.personIds,
                  widget.controller.ensemblesOf(widget.event.productionIds),
                ),
          )
          .toList();
      final here = members.where((m) => present(m.id) == true).length,
          away = members.where((m) => present(m.id) == false).length;
      return [
        Text('${widget.event.title} · ${eventDate(widget.event)}'),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Vor Ort', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  '$here da · $away fehlt · ${members.length - here - away} nicht erfasst',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
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
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    MemberAvatar(
                      controller: widget.controller,
                      avatarId: m.avatarId,
                      initials: m.initials,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            memberResponseLabel(
                              widget.controller,
                              widget.event.id,
                              m.id,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: present(m.id) == true
                          ? 'here'
                          : present(m.id) == false
                          ? 'away'
                          : 'unknown',
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 'here', child: Text('Da')),
                        DropdownMenuItem(value: 'away', child: Text('Fehlt')),
                        DropdownMenuItem(
                          value: 'unknown',
                          child: Text('Nicht erfasst'),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _versions.putIfAbsent(
                                m.id,
                                () => intValue(
                                  widget
                                      .controller
                                      .checkinVersions['${widget.event.id}:${m.id}'],
                                ),
                              );
                              _changes[m.id] = v == 'unknown'
                                  ? null
                                  : v == 'here';
                            }),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy || _changes.isEmpty ? null : _save,
          child: Text(
            _changes.isEmpty
                ? 'Anwesenheit gespeichert'
                : 'Änderungen speichern',
          ),
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
  );
}
