import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/widgets/empty_state.dart';
import '../data/learn_preferences.dart';
import '../data/reader_preferences.dart';
import '../domain/line_learning.dart';
import '../domain/reader_entries.dart';
import '../domain/script_roles.dart';
import 'widgets/reader_sheet_frame.dart';
import 'widgets/reader_style.dart';

/// Learning one's own lines with cue cards: the line before is shown, the
/// own line stays hidden until the member asks for the first letters or the
/// whole line, then rates it. Works on the script stored on the device;
/// the progress stays on this device.
class LineLearningScreen extends StatefulWidget {
  const LineLearningScreen({
    super.key,
    required this.controller,
    required this.productionId,
  });
  final AppController controller;
  final String productionId;

  @override
  State<LineLearningScreen> createState() => _LineLearningScreenState();
}

/// How much of the own line is visible.
enum _Hint { hidden, initials, full }

class _LineLearningScreenState extends State<LineLearningScreen> {
  ScriptDocument? _document;
  bool _loading = false;
  String? _loadError;
  Set<String> _roles = {};
  Set<String>? _scenes;
  LearnOrder _order = LearnOrder.script;
  bool _skipMastered = false, _groups = true, _directions = true;
  LearnProgress _progress = const LearnProgress();
  double _fontScale = 1;
  LearnSession? _session;
  _Hint _hint = _Hint.hidden;

  AppController get _controller => widget.controller;

  String get _title =>
      _controller.productions
          .where((p) => p.id == widget.productionId)
          .firstOrNull
          ?.title ??
      'Skript';

  @override
  void initState() {
    super.initState();
    _document = _controller.scripts[widget.productionId];
    _readPreferences();
    if (_document == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  void _readPreferences() {
    final production = _controller.productions
        .where((p) => p.id == widget.productionId)
        .firstOrNull;
    final saved = LearnPreferences.read(
      _controller.preferences,
      widget.productionId,
      roles: _document?.roles ?? production?.roles ?? const [],
      personId: _controller.user?.personId,
    );
    _roles = saved.roles;
    _scenes = saved.scenes;
    _order = saved.order;
    _skipMastered = saved.skipMastered;
    _groups = saved.groups;
    _directions = saved.directions;
    _progress = saved.progress;
    _fontScale = ReaderPreferences.read(
      _controller.preferences,
      widget.productionId,
    ).fontScale;
  }

  /// Loads the script once when it is not on the device yet.
  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await _controller.loadScript(widget.productionId);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _loading = false;
      _document = _controller.scripts[widget.productionId];
      if (_document == null) {
        _loadError =
            _controller.error ?? 'Das Skript konnte nicht geladen werden.';
      } else {
        _readPreferences();
      }
    });
  }

  Future<void> _save(String name, Object? value) async {
    try {
      await _controller.setPreference(
        LearnPreferences.key(widget.productionId, name),
        value,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Der Lernstand konnte nicht gespeichert werden.'),
          ),
        );
    }
  }

  /// All own lines of the chosen roles, before the scene filter.
  List<LearnCard> get _allCards => _document == null
      ? const []
      : learnCards(_document!, _roles, includeGroups: _groups);

  /// The own lines in the chosen scenes.
  List<LearnCard> get _cards => [
    for (final card in _allCards)
      if (_scenes == null || _scenes!.contains(card.sceneId)) card,
  ];

  void _start(List<LearnCard> queue) {
    if (queue.isEmpty) return;
    setState(() {
      _session = LearnSession(queue);
      _hint = _Hint.hidden;
    });
  }

  void _stop() => setState(() => _session = null);

  void _showMore() {
    if (_session?.current == null) return;
    HapticFeedback.selectionClick();
    setState(() {
      _hint = switch (_hint) {
        _Hint.hidden => _Hint.initials,
        _ => _Hint.full,
      };
    });
  }

  void _reveal() {
    if (_session?.current == null) return;
    HapticFeedback.selectionClick();
    setState(() => _hint = _Hint.full);
  }

  void _answer(bool known) {
    final session = _session, card = session?.current;
    if (session == null || card == null || _hint != _Hint.full) return;
    HapticFeedback.lightImpact();
    setState(() {
      _progress = _progress.rate(card.line, known: known);
      session.answer(known: known);
      _hint = _Hint.hidden;
    });
    _save('progress', _progress.toJson());
  }

  Future<void> _resetProgress() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lernstand zurücksetzen?'),
        content: const Text(
          'Alle Repliken dieses Stücks gelten danach wieder als neu. Das betrifft nur dieses Gerät.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Zurücksetzen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _progress = const LearnProgress());
    await _save('progress', null);
  }

  String _names(Iterable<String> ids) {
    final names = roleNames(ids, _document?.roles ?? const []);
    return names.join(' & ');
  }

  Future<void> _chooseRoles() async {
    final doc = _document;
    if (doc == null) return;
    final assigned = assignedRoleIds(doc.roles, _controller.user?.personId);
    final chosen = {
      for (final role in doc.roles)
        if (_roles.any(
          (id) =>
              id.toUpperCase() == role.id.toUpperCase() ||
              id.toUpperCase() == role.name.toUpperCase(),
        ))
          role.id,
    };
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => ReaderSheetFrame(
          title: 'Rolle wählen',
          subtitle: 'Du lernst die Repliken der gewählten Rollen.',
          footer: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(sheet, chosen),
                child: const Text('Übernehmen'),
              ),
            ),
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final role in doc.roles)
                if (!isGroupSpeaker(role.id))
                  CheckboxListTile(
                    key: ValueKey('learn-role-${role.id}'),
                    value: chosen.contains(role.id),
                    onChanged: (value) => update(() {
                      if (value == true) {
                        chosen.add(role.id);
                      } else {
                        chosen.remove(role.id);
                      }
                    }),
                    title: Text(role.name.isEmpty ? role.id : role.name),
                    subtitle: assigned.contains(role.id)
                        ? const Text('Dir zugewiesen')
                        : role.actor.isEmpty
                        ? null
                        : Text(role.actor),
                  ),
            ],
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _roles = result);
    await _save('roles', result.toList());
  }

  void _setScenes(Set<String>? scenes) {
    setState(() => _scenes = scenes);
    _save('scenes', scenes?.toList());
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return PopScope(
      canPop: session == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stop();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: session == null ? null : 0,
          leading: session == null
              ? null
              : IconButton(
                  tooltip: 'Durchgang beenden',
                  onPressed: _stop,
                  icon: const Icon(Icons.close_rounded),
                ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Text lernen',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              Text(
                _title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            if (session == null && _document != null)
              PopupMenuButton<String>(
                tooltip: 'Weitere Aktionen',
                onSelected: (value) {
                  if (value == 'reset') _resetProgress();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'reset',
                    child: Text('Lernstand zurücksetzen'),
                  ),
                ],
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: _buildBody(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_document == null) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Noch kein Skript auf dem Gerät.',
            message:
                _loadError ??
                'Öffne dieses Stück einmal mit Internetverbindung, um offline zu lernen.',
            action: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut versuchen'),
            ),
          ),
        ),
      );
    }
    final session = _session;
    if (session == null) return _buildSetup(context);
    if (session.finished) return _buildFinished(context, session);
    return _buildCard(context, session);
  }

  // ---------------------------------------------------------------- setup

  Widget _buildSetup(BuildContext context) {
    final doc = _document!;
    final theme = Theme.of(context);
    final all = _allCards;
    final cards = _cards;
    final queue = learnQueue(
      cards,
      _progress,
      order: _order,
      skipMastered: _skipMastered,
    );
    final summary = _progress.summary(cards);
    final byScene = <String, List<LearnCard>>{};
    for (final card in all) {
      byScene.putIfAbsent(card.sceneId, () => []).add(card);
    }
    final scenes = [
      for (final scene in doc.scenes)
        if (byScene.containsKey(scene.id)) scene,
    ];
    final roleText = _names(_roles);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Card(
                child: ListTile(
                  key: const ValueKey('learn-roles'),
                  minTileHeight: 64,
                  leading: const Icon(Icons.person_outline_rounded),
                  title: Text(
                    roleText.isEmpty ? 'Keine Rolle gewählt' : roleText,
                  ),
                  subtitle: Text(
                    _roles.isEmpty
                        ? 'Wähle die Rolle, deren Text du lernst.'
                        : _roles.length == 1
                        ? 'Deine Rolle'
                        : 'Deine Rollen',
                  ),
                  trailing: TextButton(
                    onPressed: _chooseRoles,
                    child: Text(_roles.isEmpty ? 'Wählen' : 'Ändern'),
                  ),
                  onTap: _chooseRoles,
                ),
              ),
              if (_roles.isNotEmpty && all.isEmpty)
                const EmptyState(
                  icon: Icons.speaker_notes_off_outlined,
                  title: 'Keine Repliken gefunden.',
                  message:
                      'Diese Rolle hat in der gespeicherten Fassung keinen Text.',
                ),
              if (all.isNotEmpty) ...[
                const SizedBox(height: 8),
                _SummaryCard(
                  total: cards.length,
                  fresh: summary.fresh,
                  weak: summary.weak,
                  mastered: summary.mastered,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Szenen',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _scenes == null
                          ? null
                          : () => _setScenes(null),
                      child: const Text('Alle'),
                    ),
                    TextButton(
                      onPressed: _scenes?.isEmpty == true
                          ? null
                          : () => _setScenes({}),
                      child: const Text('Keine'),
                    ),
                  ],
                ),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final scene in scenes)
                        CheckboxListTile(
                          key: ValueKey('learn-scene-${scene.id}'),
                          minTileHeight: 60,
                          value: _scenes?.contains(scene.id) ?? true,
                          onChanged: (value) {
                            final next = {
                              ..._scenes ?? {for (final s in scenes) s.id},
                            };
                            if (value == true) {
                              next.add(scene.id);
                            } else {
                              next.remove(scene.id);
                            }
                            // Every scene again means all, new ones included.
                            _setScenes(
                              scenes.every((s) => next.contains(s.id))
                                  ? null
                                  : next,
                            );
                          },
                          title: Text(scene.title),
                          subtitle: Text(_sceneProgress(byScene[scene.id]!)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Semantics(
                  header: true,
                  child: Text('Abfrage', style: theme.textTheme.titleMedium),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<LearnOrder>(
                    segments: [
                      for (final order in LearnOrder.values)
                        ButtonSegment(value: order, label: Text(order.label)),
                    ],
                    selected: {_order},
                    onSelectionChanged: (value) {
                      setState(() => _order = value.single);
                      _save('order', _order.code);
                    },
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _skipMastered,
                  onChanged: (value) {
                    setState(() => _skipMastered = value);
                    _save('skipMastered', value);
                  },
                  title: const Text('Sichere Repliken auslassen'),
                  subtitle: const Text('Was du dreimal in Folge konntest'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _directions,
                  onChanged: (value) {
                    setState(() => _directions = value);
                    _save('directions', value);
                  },
                  title: const Text('Regieanweisungen zeigen'),
                  subtitle: const Text(
                    'Als Hinweis zwischen Stichwort und Text',
                  ),
                ),
                if (hasGroupLines(doc))
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _groups,
                    onChanged: (value) {
                      setState(() => _groups = value);
                      _save('groups', value);
                    },
                    title: const Text('Gruppenrepliken mitlernen'),
                    subtitle: const Text('Zum Beispiel „ALLE“ oder „CHOR“'),
                  ),
              ],
            ],
          ),
        ),
        _BottomBar(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('learn-start'),
                style: _bigButton,
                onPressed: queue.isEmpty
                    ? (_roles.isEmpty ? _chooseRoles : null)
                    : () => _start(queue),
                icon: Icon(
                  _roles.isEmpty
                      ? Icons.person_search_outlined
                      : Icons.play_arrow_rounded,
                ),
                label: Text(
                  _roles.isEmpty
                      ? 'Rolle wählen'
                      : queue.isEmpty
                      ? 'Keine Repliken in dieser Auswahl'
                      : queue.length == 1
                      ? 'Lernen · 1 Replik'
                      : 'Lernen · ${queue.length} Repliken',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _sceneProgress(List<LearnCard> cards) {
    final summary = _progress.summary(cards);
    final lines = cards.length == 1 ? '1 Replik' : '${cards.length} Repliken';
    return summary.mastered == 0
        ? lines
        : '$lines · ${summary.mastered} sicher';
  }

  // ----------------------------------------------------------------- card

  Widget _buildCard(BuildContext context, LearnSession session) {
    final card = session.current!;
    final doc = _document!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final prompt = card.prompt;
    final textSize = 19 * _fontScale;
    final ownLabel = card.group
        ? card.line.role
        : _names(
            card.line.roles.where((r) => _roles.any((id) => _same(id, r))),
          );
    final partners = [
      for (final role in card.line.roles)
        if (!card.group && !_roles.any((id) => _same(id, role))) role,
    ];
    final progress = _progress.of(card.line);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _showMore,
        const SingleActivator(LogicalKeyboardKey.enter): _reveal,
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _answer(true),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _answer(false),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            LinearProgressIndicator(
              value: session.length == 0
                  ? 0
                  : session.position / session.length,
              minHeight: 3,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          sceneTitle(doc, card.sceneId),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Text(
                        '${session.position + 1} / ${session.length}',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _Panel(
                    color: scheme.surfaceContainerHigh,
                    label: prompt == null
                        ? 'SZENENBEGINN'
                        : card.promptIsOwn
                        ? 'DEIN VORHERIGER SATZ · ${_speaker(prompt)}'
                        : 'STICHWORT · ${_speaker(prompt)}',
                    labelColor: scheme.onSurfaceVariant,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          prompt?.text ?? sceneTitle(doc, card.sceneId),
                          key: const ValueKey('learn-prompt'),
                          style: TextStyle(fontSize: textSize, height: 1.4),
                        ),
                        if (_directions)
                          for (final direction in card.directions)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                direction.text,
                                style: TextStyle(
                                  fontSize: textSize * .78,
                                  fontStyle: FontStyle.italic,
                                  height: 1.35,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _OwnLine(
                    label: [
                      'DEIN TEXT · ${ownLabel.isEmpty ? card.line.role : ownLabel}',
                      if (partners.isNotEmpty) 'mit ${_names(partners)}',
                    ].join(' '),
                    hint: _hint,
                    text: card.line.text,
                    textSize: textSize,
                    onTap: _hint == _Hint.full ? null : _showMore,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    progress.isNew
                        ? 'Neu'
                        : progress.mastered
                        ? 'Sitzt · ${progress.known} von ${progress.seen} gekonnt'
                        : '${progress.known} von ${progress.seen} gekonnt',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            _BottomBar(
              children: _hint == _Hint.full
                  ? [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('learn-again'),
                          style: _bigButton,
                          onPressed: () => _answer(false),
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('Nochmal'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('learn-known'),
                          style: _bigButton.merge(
                            FilledButton.styleFrom(
                              backgroundColor: StageTheme.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                          onPressed: () => _answer(true),
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Konnte ich'),
                        ),
                      ),
                    ]
                  : [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('learn-hint'),
                          style: _bigButton,
                          onPressed: _hint == _Hint.hidden ? _showMore : null,
                          icon: const Icon(Icons.lightbulb_outline_rounded),
                          label: const Text('Hinweis'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('learn-reveal'),
                          style: _bigButton,
                          onPressed: _reveal,
                          icon: const Icon(Icons.visibility_outlined),
                          label: const Text('Aufdecken'),
                        ),
                      ),
                    ],
            ),
          ],
        ),
      ),
    );
  }

  /// Large buttons for the thumb zone.
  ButtonStyle get _bigButton => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 60)),
    textStyle: WidgetStatePropertyAll(
      Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  );

  static bool _same(String a, String b) =>
      a.trim().toUpperCase() == b.trim().toUpperCase();

  String _speaker(ScriptCue cue) {
    if (cue.roles.isEmpty) return cue.role;
    final names = _names(cue.roles);
    return names.isEmpty ? cue.role : names;
  }

  // ------------------------------------------------------------- finished

  Widget _buildFinished(BuildContext context, LearnSession session) {
    final summary = _progress.summary(_cards);
    final missed = session.missed;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: EmptyState(
                icon: Icons.emoji_events_outlined,
                title: 'Durchgang geschafft.',
                message: [
                  '${session.known} gekonnt · ${session.again}× nochmal',
                  '${summary.mastered} von ${_cards.length} Repliken sitzen.',
                ].join('\n'),
              ),
            ),
          ),
        ),
        _BottomBar(
          vertical: true,
          children: [
            if (missed.isNotEmpty)
              FilledButton.icon(
                key: const ValueKey('learn-repeat-missed'),
                style: _bigButton,
                onPressed: () => _start(List.of(missed)),
                icon: const Icon(Icons.replay_rounded),
                label: Text(
                  missed.length == 1
                      ? 'Die schwache Replik wiederholen'
                      : '${missed.length} schwache Repliken wiederholen',
                ),
              ),
            OutlinedButton(
              key: const ValueKey('learn-overview'),
              style: _bigButton,
              onPressed: _stop,
              child: const Text('Zur Übersicht'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Accent and green as text: 4.5:1 on the light and on the dark surfaces.
Color _accentText(Brightness brightness) => brightness == Brightness.dark
    ? StageTheme.onInkAccent
    : const Color(0xFFB13C15);
Color _greenText(Brightness brightness) =>
    brightness == Brightness.dark ? const Color(0xFF9ED6B6) : StageTheme.green;

/// The bar at the bottom of the screen that holds the main actions.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.children, this.vertical = false});
  final List<Widget> children;
  final bool vertical;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        top: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: .15),
        ),
      ),
    ),
    child: vertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, child) in children.indexed) ...[
                if (index > 0) const SizedBox(height: 10),
                child,
              ],
            ],
          )
        : Row(children: children),
  );
}

/// A rounded panel with a small caps [label] above its [child].
class _Panel extends StatelessWidget {
  const _Panel({
    required this.color,
    required this.label,
    required this.labelColor,
    required this.child,
  });
  final Color color, labelColor;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: .8,
            color: labelColor,
          ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

/// The own line: hidden, as first letters or in full. Tapping it shows more.
class _OwnLine extends StatelessWidget {
  const _OwnLine({
    required this.label,
    required this.hint,
    required this.text,
    required this.textSize,
    required this.onTap,
  });
  final String label, text;
  final _Hint hint;
  final double textSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = dark ? StageTheme.onInkAccent : readerAccent;
    final accentText = _accentText(Theme.of(context).brightness);
    final body = switch (hint) {
      _Hint.hidden => Semantics(
        label: 'Dein Text ist verdeckt. Tippen zeigt die Anfangsbuchstaben.',
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.visibility_off_outlined,
                    color: accentText,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Sprich deinen Text. Tippe hier für die Anfangsbuchstaben.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              for (final width in const [1.0, .82, .55])
                FractionallySizedBox(
                  widthFactor: width,
                  child: Container(
                    height: textSize * .7,
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      _Hint.initials => Text(
        initialsHint(text),
        key: const ValueKey('learn-initials'),
        style: TextStyle(
          fontSize: textSize * 1.05,
          height: 1.5,
          letterSpacing: 2,
          fontWeight: FontWeight.w600,
        ),
      ),
      _Hint.full => Text(
        text,
        key: const ValueKey('learn-line'),
        style: TextStyle(
          fontSize: textSize,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
      ),
    };
    return Material(
      color: accent.withValues(alpha: dark ? .12 : .08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: accent.withValues(alpha: .6), width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('learn-own-line'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 140),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .8,
                      color: accentText,
                    ),
                  ),
                  const SizedBox(height: 10),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(key: ValueKey(hint), child: body),
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

/// The learning state of the chosen scenes at a glance.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.total,
    required this.fresh,
    required this.weak,
    required this.mastered,
  });
  final int total, fresh, weak, mastered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget stat(String value, String label, Color color) => Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Text(label, style: theme.textTheme.labelMedium),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        child: Column(
          children: [
            Row(
              children: [
                stat('$mastered', 'sitzen', _greenText(theme.brightness)),
                stat('$weak', 'üben', _accentText(theme.brightness)),
                stat('$fresh', 'neu', theme.colorScheme.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: total == 0 ? 0 : mastered / total,
                color: StageTheme.green,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              total == 1
                  ? '1 Replik in deiner Auswahl'
                  : '$total Repliken in deiner Auswahl',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
