import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/scene_planning.dart';
import 'admin.dart';
import 'events.dart';
import 'reader.dart';
import 'theme.dart';

String memberResponseLabel(AppController c, String eventId, int memberId) {
  final status = textValue(
    jsonMap(c.memberAttendanceByEvent[eventId])[memberId.toString()],
    'open',
  );
  final arrival = dateValue(
    jsonMap(c.arrivalsByEvent[eventId])[memberId.toString()],
  );
  return status == 'late'
      ? 'Später · ${arrival == null ? 'Uhrzeit offen' : DateFormat.Hm('de').format(arrival.toLocal())}'
      : statusText(status);
}

class ResponsesAdminScreen extends StatelessWidget {
  const ResponsesAdminScreen({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  Widget build(BuildContext context) => AdminPage(
    controller: controller,
    title: 'Rückmeldungen',
    children: (context) {
      final responses = jsonMap(controller.memberAttendanceByEvent[event.id]);
      final people = controller.members.where((m) => m.active).toList();
      return [
        Text(event.title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 10),
        Text('${eventDate(event)} · ${eventTime(event)}'),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final status in ['yes', 'late', 'no', 'open'])
                SizedBox(
                  width: (constraints.maxWidth - 10) / 2,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: statusColor(status).withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '${people.where((m) => textValue(responses[m.id.toString()], 'open') == status).length}',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        Text(
                          const {
                            'yes': 'Dabei',
                            'late': 'Später',
                            'no': 'Abgesagt',
                            'open': 'Offen',
                          }[status]!,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        for (final m in people)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ListTile(
                leading: CircleAvatar(child: Text(m.initials)),
                title: Text(m.name),
                subtitle: Text(m.group),
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 170),
                  child: StatePill(
                    memberResponseLabel(controller, event.id, m.id),
                    color: statusColor(
                      textValue(responses[m.id.toString()], 'open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: () => openPage(
            context,
            ScenePlannerScreen(controller: controller, event: event),
          ),
          icon: const Icon(Icons.auto_stories_outlined),
          label: const Text('Szenen planen'),
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
      ];
    },
  );
}

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
  Future<void> _save() async {
    setState(() => _busy = true);
    try {
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
      final members = widget.controller.members.where((m) => m.active).toList();
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
                    CircleAvatar(child: Text(m.initials)),
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
          onPressed: () => openPage(
            context,
            ScenePlannerScreen(
              controller: widget.controller,
              event: widget.event,
            ),
          ),
          icon: const Icon(Icons.playlist_add_check),
          label: const Text('Spielbare Szenen ansehen'),
        ),
      ];
    },
  );
}

class ScenePlannerScreen extends StatefulWidget {
  const ScenePlannerScreen({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  State<ScenePlannerScreen> createState() => _ScenePlannerScreenState();
}

class _ScenePlannerScreenState extends State<ScenePlannerScreen> {
  String? _production;
  bool _useCheckins = true, _loading = false, _saving = false;
  late DateTime _at;
  final Set<String> _selected = {};
  @override
  void initState() {
    super.initState();
    _production =
        widget.event.productionId ??
        widget.controller.productions.firstOrNull?.id;
    _at = widget.event.startsAt ?? DateTime.now();
    _selected.addAll(widget.event.sceneIds);
    if (_production != null) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await widget.controller.loadScript(_production!);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.controller.performAction({
        'action': 'event.script',
        'eventId': widget.event.id,
        'productionId': _production,
        'sceneIds': _selected.toList(),
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Szenen planen',
    children: (context) {
      final doc = widget.controller.scripts[_production];
      final production = widget.controller.productionRecords
          .where((p) => p['id'] == _production)
          .firstOrNull;
      return [
        DropdownButtonFormField<String>(
          initialValue: _production,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Produktion'),
          items: [
            for (final p in widget.controller.productions)
              DropdownMenuItem(
                value: p.id,
                child: Text(p.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            setState(() {
              _production = v;
              _selected.clear();
            });
            _load();
          },
        ),
        const SizedBox(height: 24),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Vor Ort')),
            ButtonSegment(value: false, label: Text('Zusagen')),
          ],
          selected: {_useCheckins},
          onSelectionChanged: (v) => setState(() => _useCheckins = v.single),
        ),
        const SizedBox(height: 12),
        Text(
          _useCheckins
              ? 'Grundlage: erfasste Anwesenheit'
              : 'Grundlage: Rückmeldungen',
        ),
        if (!_useCheckins)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: Text('Planen ab ${DateFormat.Hm('de').format(_at)}'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final time = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(_at),
              );
              if (time != null && mounted) {
                setState(
                  () => _at = DateTime(
                    _at.year,
                    _at.month,
                    _at.day,
                    time.hour,
                    time.minute,
                  ),
                );
              }
            },
          ),
        const SizedBox(height: 22),
        if (_loading) const LinearProgressIndicator(),
        if (!_loading && doc == null)
          EmptyState(
            icon: Icons.menu_book_outlined,
            title: 'Noch kein Drehbuch',
            message:
                widget.controller.error ??
                'Bitte zuerst ein Drehbuch zur Produktion übernehmen.',
          ),
        if (doc != null)
          for (final scene in doc.scenes)
            Builder(
              builder: (context) {
                final state = evaluateScene(
                  scene: scene,
                  casting: jsonMap(production?['casting']),
                  checkins: jsonMap(
                    widget.controller.checkinsByEvent[widget.event.id],
                  ),
                  responses: jsonMap(
                    widget.controller.memberAttendanceByEvent[widget.event.id],
                  ),
                  arrivals: jsonMap(
                    widget.controller.arrivalsByEvent[widget.event.id],
                  ),
                  useCheckins: _useCheckins,
                  at: _at,
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: CheckboxListTile(
                      value: _selected.contains(scene.id),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('Szene ${scene.id} · ${scene.title}'),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.details.isEmpty
                                  ? scene.roles.join(' · ')
                                  : state.details.join('\n'),
                            ),
                            const SizedBox(height: 8),
                            StatePill(
                              state.playable
                                  ? 'Spielbar'
                                  : state.status == 'unknown'
                                  ? 'Ungeklärt'
                                  : 'Unvollständig',
                              color: state.playable
                                  ? StageTheme.green
                                  : state.status == 'unknown'
                                  ? const Color(0xFFA25B06)
                                  : StageTheme.orange,
                            ),
                          ],
                        ),
                      ),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(scene.id);
                        } else {
                          _selected.remove(scene.id);
                        }
                      }),
                    ),
                  ),
                );
              },
            ),
        const SizedBox(height: 20),
        Text('${_selected.length} Szenen ausgewählt'),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _selected.isEmpty || _production == null
              ? null
              : () => openPage(
                  context,
                  ScriptReaderScreen(
                    controller: widget.controller,
                    productionId: _production!,
                    initialSceneId: _selected.first,
                  ),
                ),
          icon: const Icon(Icons.auto_stories_outlined),
          label: const Text('Ausgewählte Szene öffnen'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving || _production == null ? null : _save,
          child: const Text('Für diese Probe speichern'),
        ),
      ];
    },
  );
}
