import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../scripts/ui/script_reader_screen.dart';
import '../domain/scene_planning.dart';

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
  bool _conflict = false;
  late int _version;
  final Set<String> _failedSaves = {};
  late DateTime _at;
  final Set<String> _selected = {};
  @override
  void initState() {
    super.initState();
    final event =
        widget.controller.events
            .where((e) => e.id == widget.event.id)
            .firstOrNull ??
        widget.event;
    _version = event.version;
    _production =
        event.productionId ?? widget.controller.productions.firstOrNull?.id;
    _at = event.startsAt ?? DateTime.now();
    _selected.addAll(event.sceneIds);
    if (_production != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await widget.controller.loadScript(_production!);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final previous = widget.controller.outbox.map((a) => a.id).toSet();
    setState(() => _saving = true);
    try {
      await widget.controller.performAction({
        'action': 'event.script',
        'eventId': widget.event.id,
        'version': _version,
        'productionId': _production,
        'sceneIds': _selected.toList(),
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        if (e is ApiException && e.statusCode == 409) {
          setState(() {
            _conflict = true;
            _failedSaves.addAll(
              widget.controller.outbox
                  .where((a) => a.failed && !previous.contains(a.id))
                  .map((a) => a.id),
            );
          });
        }
        showProblem(context, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resolveConflict({required bool keepDraft}) async {
    setState(() => _saving = true);
    try {
      await widget.controller.refresh();
      if (widget.controller.isOffline) {
        throw const ApiException(
          'Der aktuelle Stand ist offline nicht verfügbar. Dein Entwurf bleibt erhalten.',
        );
      }
      if (widget.controller.error != null) {
        throw const ApiException(
          'Der aktuelle Stand konnte nicht geladen werden. Dein Entwurf bleibt erhalten.',
        );
      }
      final latest = widget.controller.events
          .where((e) => e.id == widget.event.id)
          .firstOrNull;
      if (latest == null) {
        throw const ApiException('Der Termin ist nicht mehr verfügbar.');
      }
      for (final id in _failedSaves) {
        await widget.controller.discardAction(id);
      }
      if (!mounted) return;
      setState(() {
        _version = latest.version;
        _conflict = false;
        _failedSaves.clear();
        if (!keepDraft) {
          _production =
              latest.productionId ??
              widget.controller.productions.firstOrNull?.id;
          _selected
            ..clear()
            ..addAll(latest.sceneIds);
        }
      });
      if (_production != null) await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              keepDraft
                  ? 'Aktueller Stand geladen. Prüfe deinen Entwurf und speichere erneut.'
                  : 'Aktuelle Szenenauswahl übernommen.',
            ),
          ),
        );
      }
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
      final currentEvent = widget.controller.events
          .where((e) => e.id == widget.event.id)
          .firstOrNull;
      return [
        DropdownButtonFormField<String>(
          key: ValueKey(_production),
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
          onChanged: _saving || _loading
              ? null
              : (v) {
                  setState(() {
                    _production = v;
                    _selected.clear();
                  });
                  if (v != null) _load();
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
            title: Text(
              'Planen ab ${DateFormat('EEE, dd.MM. · HH:mm', 'de').format(_at)}',
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final time = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(_at),
              );
              if (time != null && mounted) {
                setState(
                  () => _at = scenePlanningTime(
                    startsAt: widget.event.startsAt ?? _at,
                    endsAt: widget.event.endsAt,
                    hour: time.hour,
                    minute: time.minute,
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
                      onChanged: _saving
                          ? null
                          : (v) => setState(() {
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
        if (_conflict) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Szenenauswahl prüfen',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Die Zuordnung wurde inzwischen geändert oder abgelehnt. Dein Entwurf bleibt erhalten. Lade den aktuellen Stand, bevor du erneut speicherst.',
                  ),
                  if (currentEvent != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      currentEvent.sceneIds.isEmpty
                          ? 'Aktuell gespeichert: keine Szenen ausgewählt.'
                          : 'Aktuell gespeichert: Szenen ${currentEvent.sceneIds.join(', ')}.',
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => _resolveConflict(keepDraft: true),
                    child: const Text('Entwurf behalten und Stand prüfen'),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _resolveConflict(keepDraft: false),
                    child: const Text('Aktuelle Auswahl übernehmen'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        FilledButton(
          onPressed: _saving || _loading || _conflict || _production == null
              ? null
              : _save,
          child: const Text('Für diese Probe speichern'),
        ),
      ];
    },
  );
}
