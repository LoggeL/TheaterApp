import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import 'annotations.dart';

const _accent = Color(0xFFED6B36);
const _ink = Color(0xFF242628);

class ProductionsScreen extends StatelessWidget {
  const ProductionsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => CustomScrollView(
      key: const PageStorageKey('productions'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DEINE BÜHNE',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: 2.4,
                    color: _accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Drehbücher',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.08,
                    letterSpacing: -1.3,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Deine Produktionen',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Pill(
                      icon: Icons.menu_book_rounded,
                      label: '${controller.productions.length} Produktionen',
                    ),
                    _Pill(
                      icon: Icons.offline_pin_outlined,
                      label: '${controller.scripts.length} offline verfügbar',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (controller.productions.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _ReaderEmpty(
              icon: Icons.theater_comedy_outlined,
              title: 'Die Bühne wartet.',
              message:
                  controller.error ??
                  'Sobald eine Produktion freigegeben ist, findest du hier dein Drehbuch.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
            sliver: SliverList.builder(
              itemCount: controller.productions.length,
              itemBuilder: (context, index) {
                final production = controller.productions[index];
                final cached = controller.scripts.containsKey(production.id);
                final role =
                    controller.preferences['reader.${production.id}.role']
                        as String?;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _ProductionCard(
                    production: production,
                    number: index + 1,
                    cached: cached,
                    role: role,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ScriptReaderScreen(
                          controller: controller,
                          productionId: production.id,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );
}

class _ProductionCard extends StatelessWidget {
  const _ProductionCard({
    required this.production,
    required this.number,
    required this.cached,
    required this.role,
    required this.onTap,
  });
  final Production production;
  final int number;
  final bool cached;
  final String? role;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    color: number.isOdd ? _ink : const Color(0xFF394642),
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.theater_comedy_outlined,
                  color: Color(0xFFFFA37A),
                  size: 32,
                ),
                const Spacer(),
                Text(
                  number.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w300,
                    color: Colors.white30,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Text(
              production.title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
            ),
            if (production.subtitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                production.subtitle,
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                if (production.sceneCount > 0)
                  Text(
                    '${production.sceneCount} Szenen',
                    style: const TextStyle(color: Colors.white70),
                  ),
                Text(
                  role?.isNotEmpty == true
                      ? 'Deine Rolle: $role'
                      : 'Rolle im Drehbuch auswählen',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Icon(
                  cached
                      ? Icons.offline_pin_outlined
                      : Icons.cloud_download_outlined,
                  color: Colors.white60,
                  size: 17,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    cached
                        ? 'Auf diesem Gerät gespeichert'
                        : 'Beim Öffnen offline speichern',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
                const CircleAvatar(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  child: Icon(Icons.arrow_forward_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Pure view derivation: context stays in its scene and canonical order is kept.
/// The original document is never altered by display preferences.
List<ScriptCue> visibleScriptCues(
  ScriptDocument document, {
  String role = '',
  Set<String> roles = const {},
  String mode = 'read',
  int contextLines = 2,
  bool showDirections = true,
  bool showTechnical = true,
  bool technicalFullText = false,
  Set<String>? categories,
  Map<String, int> categoryContext = const {},
}) {
  final all = document.cues;
  final selected = {
    ...roles,
    if (role.isNotEmpty) role,
  }.map((r) => r.trim().toUpperCase()).toSet();
  final included = <int>{};
  final actor = mode == 'actor' && selected.isNotEmpty;
  final technicalOnly = mode == 'technical' && !technicalFullText;
  void includeContext(int index, int count) {
    final start = (index - count).clamp(0, all.length),
        end = (index + count + 1).clamp(0, all.length);
    for (var neighbor = start; neighbor < end; neighbor++) {
      if (all[neighbor].sceneId == all[index].sceneId) included.add(neighbor);
    }
  }

  for (var index = 0; index < all.length; index++) {
    final cue = all[index], key = cueCategory(all[index]);
    if (actor &&
        cue.kind == 'dialogue' &&
        selected.contains(cue.role.trim().toUpperCase())) {
      includeContext(index, contextLines);
    }
    if (technicalOnly &&
        (_isTechnical(cue) || cue.kind == 'direction') &&
        (categories == null || categories.contains(key))) {
      includeContext(index, categoryContext[key] ?? 0);
    }
  }
  return [
    for (var index = 0; index < all.length; index++)
      if ((!actor && !technicalOnly || included.contains(index)) &&
          (showDirections || all[index].kind != 'direction') &&
          (showTechnical || !_isTechnical(all[index])) &&
          (categories == null ||
              all[index].kind == 'dialogue' ||
              categories.contains(cueCategory(all[index]))) &&
          all[index].kind != 'scene' &&
          all[index].kind != 'role')
        all[index],
  ];
}

String cueCategory(ScriptCue cue) =>
    cue.kind == 'microphone' && cue.isAutoMic ? 'autoMicrophone' : cue.kind;

bool _isTechnical(ScriptCue cue) => const {
  'technical',
  'lighting',
  'audio',
  'props',
  'microphone',
}.contains(cue.kind);

class ScriptReaderScreen extends StatefulWidget {
  const ScriptReaderScreen({
    super.key,
    required this.controller,
    required this.productionId,
    this.initialSceneId,
    this.initialCueId,
  });
  final AppController controller;
  final String productionId;
  final String? initialSceneId, initialCueId;

  @override
  State<ScriptReaderScreen> createState() => _ScriptReaderScreenState();
}

class _ScriptReaderScreenState extends State<ScriptReaderScreen>
    with WidgetsBindingObserver {
  final _itemScroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _saveTimer;
  Timer? _searchTimer;
  Timer? _focusTimer;
  FocusState? _liveFocus;
  String? _liveError;
  bool _following = false;
  bool _directing = false;
  bool _focusRequest = false;
  bool _foreground = true;
  int _lastFocusSequence = -1;
  ScriptDocument? _document;
  List<_ReaderEntry> _entries = [];
  Map<String, int> _cueIndices = {};
  List<ScriptCue> _searchResults = [];
  Set<String> _bookmarks = {};
  String _role = '';
  Set<String> _roles = {};
  final Set<String> _revealed = {};
  Set<String> _categories = {'direction'};
  Map<String, int> _categoryContext = {};
  JsonMap _notes = {};
  bool _assignedRoles = true;
  bool _own(ScriptCue cue) =>
      cue.kind == 'dialogue' &&
      _roles.any((r) => r.toUpperCase() == cue.role.trim().toUpperCase());
  bool get _hasRoles => _roles.isNotEmpty;
  String _mode = 'read';
  String? _activeCueId;
  String? _firstVisibleCueId;
  String? _loadError;
  String _sceneLabel = '';
  double _fontScale = 1;
  int _contextLines = 2;
  int _searchResultIndex = 0;
  bool _showDirections = true;
  bool _showTechnical = true;
  bool _loading = true;
  bool _searching = false;
  bool _printing = false;

  String get _prefix => 'reader.${widget.productionId}';
  bool get _stage => _mode == 'stage';
  String get _title {
    for (final production in widget.controller.productions) {
      if (production.id == widget.productionId) return production.title;
    }
    return 'Drehbuch';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final preferences = widget.controller.preferences;
    _role = preferences['$_prefix.role'] as String? ?? '';
    _roles = jsonList(
      preferences['$_prefix.roles'],
    ).map((v) => v.toString()).toSet();
    if (_roles.isEmpty && _role.isNotEmpty) _roles.add(_role);
    _assignedRoles = preferences.containsKey('$_prefix.assignedRoles')
        ? preferences['$_prefix.assignedRoles'] == true
        : _roles.isEmpty;
    _notes = jsonMap(preferences['$_prefix.notes']);
    _categories = preferences.containsKey('$_prefix.categories')
        ? jsonList(
            preferences['$_prefix.categories'],
          ).map((v) => v.toString()).toSet()
        : {'direction'};
    _categoryContext = jsonMap(
      preferences['$_prefix.categoryContext'],
    ).map((k, v) => MapEntry(k, intValue(v)));
    _mode =
        preferences['$_prefix.mode'] as String? ??
        (preferences['$_prefix.actorMode'] == true ? 'actor' : 'read');
    if (!const {
      'read',
      'actor',
      'practice',
      'stage',
      'technical',
      'cues',
    }.contains(_mode)) {
      _mode = 'read';
    }
    _fontScale = ((preferences['$_prefix.fontScale'] as num?)?.toDouble() ?? 1)
        .clamp(0.85, 1.6);
    _contextLines =
        ((preferences['$_prefix.contextLines'] as num?)?.toInt() ?? 2).clamp(
          0,
          6,
        );
    _showDirections = preferences['$_prefix.showDirections'] != false;
    _showTechnical = preferences['$_prefix.showTechnical'] == true;
    _bookmarks = (preferences['$_prefix.bookmarks'] as List? ?? [])
        .whereType<String>()
        .toSet();
    _activeCueId =
        widget.initialCueId ?? preferences['$_prefix.lastCueId'] as String?;
    _positions.itemPositions.addListener(_onPositionsChanged);
    _document = widget.controller.scripts[widget.productionId];
    _selectAssignedRoles();
    _rebuildEntries();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _searchTimer?.cancel();
    _focusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _positions.itemPositions.removeListener(_onPositionsChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && (_following || _directing)) {
      _startFocusPolling();
    } else {
      _focusTimer?.cancel();
    }
  }

  void _startFocusPolling() {
    _focusTimer?.cancel();
    if (!_foreground || (!_following && !_directing)) return;
    _refreshFocus();
    _focusTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshFocus(),
    );
  }

  Future<void> _refreshFocus() async {
    if (_focusRequest || !_foreground || !mounted) return;
    _focusRequest = true;
    try {
      final focus = await widget.controller.getFocus(widget.productionId);
      if (!mounted || !_foreground) return;
      if (focus.productionId != widget.productionId ||
          focus.sequence < _lastFocusSequence) {
        return;
      }
      final changed = focus.sequence > _lastFocusSequence;
      _lastFocusSequence = focus.sequence;
      if (focus.cueId != null && focus.revision != _document?.revision) {
        setState(() {
          _liveFocus = focus;
          _liveError =
              'Andere Drehbuchfassung. Bitte aktualisieren, um dem Fokus zu folgen.';
        });
        return;
      }
      setState(() {
        _liveFocus = focus;
        _liveError = null;
        if (!focus.canDirect) _directing = false;
      });
      if (changed && _following && focus.cueId != null) {
        await _jumpToCue(focus.cueId!);
      }
      if (changed && _following && focus.cueId == null) {
        setState(() => _activeCueId = null);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _liveError =
              'Fokus zurzeit nicht erreichbar. Dein Drehbuch bleibt lesbar.',
        );
      }
    } finally {
      _focusRequest = false;
    }
  }

  Future<void> _publishFocus(ScriptCue cue) async {
    if (_focusRequest) {
      _notice(
        'Der letzte Fokus wird noch übertragen. Bitte gleich noch einmal tippen.',
      );
      return;
    }
    _focusRequest = true;
    try {
      final focus = await widget.controller.publishFocus(
        widget.productionId,
        revision: _document!.revision,
        cueId: cue.id,
      );
      if (!mounted) return;
      setState(() {
        _liveFocus = focus;
        _liveError = null;
        _lastFocusSequence = focus.sequence;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _liveError =
              'Der Fokus wurde nicht geteilt. Bitte erneut versuchen.',
        );
        _notice(_liveError!);
      }
    } finally {
      _focusRequest = false;
    }
  }

  Future<void> _showLive() async {
    await _refreshFocus();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, updateSheet) => _SheetFrame(
          title: 'Ein gemeinsamer Fokus',
          subtitle: widget.controller.isDemo
              ? 'Die Demo zeigt den Fokus auf diesem Gerät. Für mehrere Geräte verbinde dich mit eurem Server.'
              : _liveFocus?.source == 'skript'
              ? 'Mit dem Skript-Browser verbunden. Folge der gemeinsamen Textstelle.'
              : 'Folge derselben Textstelle auf Handy, Tablet und in der Web-App.',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_liveError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _liveError!,
                      style: const TextStyle(color: _accent),
                    ),
                  ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Der Regie folgen'),
                  subtitle: const Text(
                    'Automatisch zur gemeinsamen Textstelle springen',
                  ),
                  value: _following,
                  onChanged: _liveFocus == null
                      ? null
                      : (value) {
                          setState(() {
                            _following = value;
                            if (value) {
                              _directing = false;
                              _lastFocusSequence = -1;
                            }
                          });
                          updateSheet(() {});
                          _startFocusPolling();
                        },
                ),
                if (_liveFocus?.canDirect == true)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Regie übernehmen'),
                    subtitle: const Text(
                      'Angetippte Textstellen mit allen folgenden Geräten teilen',
                    ),
                    value: _directing,
                    onChanged: (value) {
                      setState(() {
                        _directing = value;
                        if (value) _following = false;
                      });
                      updateSheet(() {});
                      _startFocusPolling();
                    },
                  ),
                if (_liveFocus?.canDirect == true && _liveFocus?.cueId != null)
                  TextButton.icon(
                    onPressed: () async {
                      try {
                        await widget.controller.clearFocus(widget.productionId);
                        if (!mounted) return;
                        await _refreshFocus();
                        if (context.mounted) updateSheet(() {});
                      } catch (_) {
                        if (mounted) {
                          _notice('Der Fokus konnte nicht aufgehoben werden.');
                        }
                      }
                    },
                    icon: const Icon(Icons.location_disabled),
                    label: const Text('Gemeinsamen Fokus aufheben'),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Zurück zum Stück'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _preference(String key, Object? value) async {
    try {
      await widget.controller.setPreference('$_prefix.$key', value);
    } catch (_) {
      if (mounted) _notice('Die Einstellung konnte nicht gespeichert werden.');
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await widget.controller.loadScript(widget.productionId);
      if (!mounted) return;
      final loaded = widget.controller.scripts[widget.productionId];
      setState(() {
        _document = loaded;
        _selectAssignedRoles();
        _loading = false;
        if (loaded == null) {
          _loadError =
              widget.controller.error ??
              'Das Drehbuch konnte nicht geladen werden.';
        }
        _rebuildEntries();
      });
      if (widget.initialCueId == null && widget.initialSceneId != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _jumpToScene(widget.initialSceneId!, animate: false),
        );
      } else if (_activeCueId != null) {
        final destination = _activeCueId!;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _jumpToCue(destination, animate: false),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Verbindung fehlgeschlagen. Bitte erneut versuchen.';
        });
      }
    }
  }

  void _rebuildEntries() {
    final doc = _document;
    if (doc == null) return;
    final cues = visibleScriptCues(
      doc,
      roles: _roles,
      mode: _mode == 'cues' ? 'technical' : _mode,
      technicalFullText: _mode == 'technical',
      categories: _categories,
      categoryContext: _categoryContext,
      contextLines: _contextLines,
      showDirections: _showDirections,
      showTechnical: _showTechnical || _mode == 'technical' || _mode == 'cues',
    );
    final scenes = {for (final scene in doc.scenes) scene.id: scene};
    final entries = <_ReaderEntry>[];
    final cueIndices = <String, int>{};
    String? previousScene;
    for (final cue in cues) {
      if (cue.sceneId != previousScene) {
        entries.add(
          _ReaderEntry.scene(
            scenes[cue.sceneId] ??
                ScriptScene(
                  id: cue.sceneId,
                  title: 'Szene ${cue.sceneId}',
                  ordinal: 0,
                  roles: const [],
                ),
          ),
        );
        previousScene = cue.sceneId;
      }
      cueIndices[cue.id] = entries.length;
      entries.add(_ReaderEntry.cue(cue));
    }
    _entries = entries;
    _cueIndices = cueIndices;
  }

  void _onPositionsChanged() {
    final positions =
        _positions.itemPositions.value
            .where(
              (position) =>
                  position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1,
            )
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    for (final position in positions) {
      if (position.index >= _entries.length) continue;
      final cue = _entries[position.index].cue;
      if (cue == null) continue;
      if (_firstVisibleCueId == cue.id) return;
      _firstVisibleCueId = cue.id;
      final scenes = _document?.scenes ?? <ScriptScene>[];
      var label = 'Szene ${cue.sceneId}';
      for (final scene in scenes) {
        if (scene.id == cue.sceneId) {
          label = scene.title;
          break;
        }
      }
      if (_sceneLabel != label && mounted) setState(() => _sceneLabel = label);
      _saveTimer?.cancel();
      _saveTimer = Timer(
        const Duration(milliseconds: 650),
        () => _preference('lastCueId', cue.id),
      );
      return;
    }
  }

  Future<void> _jumpToCue(String cueId, {bool animate = true}) async {
    if (!mounted) return;
    if (!_cueIndices.containsKey(cueId)) {
      setState(() {
        _mode = 'read';
        _showDirections = true;
        _showTechnical = true;
        _rebuildEntries();
      });
      await _preference('mode', 'read');
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
    }
    final index = _cueIndices[cueId];
    if (index == null) {
      _notice('Diese Textstelle ist in dieser Fassung nicht vorhanden.');
      return;
    }
    setState(() => _activeCueId = cueId);
    if (_itemScroll.isAttached) {
      if (animate && !MediaQuery.disableAnimationsOf(context)) {
        await _itemScroll.scrollTo(
          index: index,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.08,
        );
      } else {
        _itemScroll.jumpTo(index: index, alignment: 0.08);
      }
    }
    _preference('lastCueId', cueId);
  }

  void _notice(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  void _search(String query) {
    final needle = query.toLowerCase().trim();
    setState(() {
      _searchResults = needle.isEmpty
          ? []
          : (_document?.cues ?? <ScriptCue>[])
                .where(
                  (cue) =>
                      cue.kind != 'scene' &&
                      cue.kind != 'role' &&
                      '${cue.role} ${cue.text}'.toLowerCase().contains(needle),
                )
                .toList();
      _searchResultIndex = 0;
    });
    if (_searchResults.isNotEmpty) _jumpToCue(_searchResults.first.id);
  }

  void _nextSearchResult(int delta) {
    if (_searchResults.isEmpty) return;
    setState(
      () => _searchResultIndex =
          (_searchResultIndex + delta) % _searchResults.length,
    );
    _jumpToCue(_searchResults[_searchResultIndex].id);
  }

  void _toggleBookmark(String cueId) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_bookmarks.add(cueId)) _bookmarks.remove(cueId);
    });
    _preference('bookmarks', _bookmarks.toList());
  }

  @override
  Widget build(BuildContext context) {
    final parentTheme = Theme.of(context);
    final readerTheme = _stage
        ? ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: _accent,
              brightness: Brightness.dark,
              surface: const Color(0xFF151719),
            ),
            useMaterial3: true,
          )
        : parentTheme;
    return Theme(
      data: readerTheme,
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: _stage
              ? const Color(0xFF151719)
              : readerTheme.scaffoldBackgroundColor,
          appBar: AppBar(
            titleSpacing: 0,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_sceneLabel.isNotEmpty)
                  Text(
                    _sceneLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: readerTheme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Im Drehbuch suchen',
                onPressed: () {
                  setState(() => _searching = !_searching);
                  if (_searching) {
                    _searchFocus.requestFocus();
                  } else {
                    _searchController.clear();
                    _search('');
                  }
                },
                icon: Icon(
                  _searching ? Icons.search_off_rounded : Icons.search_rounded,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Weitere Aktionen',
                onSelected: (value) {
                  switch (value) {
                    case 'settings':
                      _showSettings();
                    case 'notes':
                      _showNotes();
                    case 'bookmarks':
                      _showBookmarks();
                    case 'export':
                      _exportPdf();
                    case 'refresh':
                      _load();
                    case 'focus':
                      _showLive();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'settings',
                    child: Text('Leseeinstellungen'),
                  ),
                  const PopupMenuItem(
                    value: 'notes',
                    child: Text('Private Notizen'),
                  ),
                  PopupMenuItem(
                    value: 'focus',
                    enabled: _document != null,
                    child: const Text('Gemeinsamer Fokus'),
                  ),
                  const PopupMenuItem(
                    value: 'bookmarks',
                    child: Text('Lesezeichen'),
                  ),
                  PopupMenuItem(
                    value: 'export',
                    enabled: _document != null && !_printing,
                    child: Text(
                      _printing ? 'PDF wird erstellt …' : 'Drucken / PDF',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'refresh',
                    child: Text('Fassung aktualisieren'),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (_searching) _buildSearch(context),
              if (_document != null) _buildToolbar(context),
              if (_following || _directing)
                Material(
                  color: _accent.withValues(alpha: 0.12),
                  child: ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: Icon(
                      _directing ? Icons.cell_tower : Icons.sync,
                      color: _accent,
                      size: 19,
                    ),
                    title: Text(
                      _liveError ??
                          (widget.controller.isDemo
                              ? 'Demo-Fokus · nur dieses Gerät'
                              : _directing
                              ? 'Du führst · Text antippen, um den Fokus zu teilen'
                              : _liveFocus?.cueId == null
                              ? 'Warte auf den gemeinsamen Fokus'
                              : 'Du folgst dem gemeinsamen Fokus'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: IconButton(
                      tooltip: 'Fokus beenden',
                      icon: const Icon(Icons.close, size: 19),
                      onPressed: () {
                        setState(() {
                          _following = false;
                          _directing = false;
                        });
                        _focusTimer?.cancel();
                      },
                    ),
                  ),
                ),
              if (_document?.stale == true)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 6,
                  ),
                  child: Text(
                    'Gespeicherte Fassung · Aktualisierung zurzeit nicht möglich',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              if (_loading && _document != null)
                const LinearProgressIndicator(minHeight: 2),
              Expanded(child: _buildAdaptiveContent(context)),
            ],
          ),
          bottomNavigationBar: _document == null
              ? null
              : _buildBottomBar(context),
        ),
      ),
    );
  }

  Widget _buildSearch(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocus,
            onChanged: (query) {
              _searchTimer?.cancel();
              _searchTimer = Timer(
                const Duration(milliseconds: 180),
                () => _search(query),
              );
            },
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _searchFocus.unfocus(),
            decoration: InputDecoration(
              hintText: 'Text oder Rolle suchen',
              prefixIcon: const Icon(Icons.search),
              suffixText: _searchController.text.isEmpty
                  ? null
                  : _searchResults.isEmpty
                  ? '0 Treffer'
                  : '${_searchResultIndex + 1}/${_searchResults.length}',
              isDense: true,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Vorheriger Treffer',
          onPressed: _searchResults.isEmpty
              ? null
              : () => _nextSearchResult(-1),
          icon: const Icon(Icons.keyboard_arrow_up),
        ),
        IconButton(
          tooltip: 'Nächster Treffer',
          onPressed: _searchResults.isEmpty ? null : () => _nextSearchResult(1),
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
      ],
    ),
  );

  void _selectAssignedRoles() {
    if (!_assignedRoles || _document == null) return;
    _roles = _document!.roles
        .where(
          (r) =>
              r.personId != null &&
              r.personId == widget.controller.user?.personId,
        )
        .map((r) => r.id)
        .toSet();
    _role = _roles.firstOrNull ?? '';
  }

  static const _modes = {
    'read': 'Lesen',
    'practice': 'Lernen',
    'actor': 'Meine Texte',
    'technical': 'Technik',
    'cues': 'Nur Cues',
    'stage': 'Bühne',
  };

  void _changeMode(String mode) {
    setState(() {
      _mode = mode;
      _revealed.clear();
      if (mode == 'technical' || mode == 'cues') {
        _showTechnical = true;
        _categories.addAll({
          'direction',
          'technical',
          'lighting',
          'audio',
          'props',
          'microphone',
          'autoMicrophone',
        });
      }
      _rebuildEntries();
    });
    _preference('mode', mode);
    _preference('categories', _categories.toList());
    if ((mode == 'practice' || mode == 'actor') && !_hasRoles) _showRoles();
  }

  Widget _buildToolbar(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    child: Row(
      children: [
        TextButton.icon(
          onPressed: _showScenes,
          icon: const Icon(Icons.list_rounded, size: 18),
          label: const Text('Szenen'),
        ),
        const Spacer(),
        Flexible(
          child: TextButton(
            onPressed: _showRoles,
            child: Text(
              _roles.isEmpty
                  ? 'Meine Rollen'
                  : _roles.length == 1
                  ? _roles.first
                  : '${_roles.length} Rollen',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Lesemodus',
          initialValue: _mode,
          onSelected: _changeMode,
          itemBuilder: (_) => [
            for (final mode in _modes.entries)
              CheckedPopupMenuItem(
                value: mode.key,
                checked: _mode == mode.key,
                child: Text(mode.value),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_modes[_mode] ?? 'Lesen'),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more, size: 18),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildAdaptiveContent(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 1100 || _document == null) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: _buildContent(context),
          ),
        );
      }
      final focus = _document!.cues
          .where((c) => c.id == _liveFocus?.cueId)
          .firstOrNull;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 220,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Szenen',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                for (final scene in _document!.scenes)
                  ListTile(
                    title: Text('${scene.id} · ${scene.title}'),
                    selected: _document!.cues.any(
                      (c) => c.sceneId == scene.id && _own(c),
                    ),
                    selectedColor: _accent,
                    selectedTileColor: _accent.withValues(alpha: 0.08),
                    onTap: () {
                      final cue = _document!.cues
                          .where(
                            (c) =>
                                c.sceneId == scene.id &&
                                _cueIndices.containsKey(c.id),
                          )
                          .firstOrNull;
                      if (cue != null) _jumpToCue(cue.id);
                    },
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _buildContent(context)),
          const VerticalDivider(width: 1),
          SizedBox(
            width: 260,
            child: ListView(
              padding: const EdgeInsets.all(22),
              children: [
                Text('Regie', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _showLive,
                  icon: const Icon(Icons.cell_tower),
                  label: Text(
                    _directing
                        ? 'Du führst'
                        : _following
                        ? 'Du folgst'
                        : 'Sitzung öffnen',
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  focus == null
                      ? 'Keine Regiemarkierung'
                      : 'Szene ${focus.sceneId} · ${focus.role}',
                ),
                if (focus != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    focus.text,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
                const SizedBox(height: 28),
                const Text(
                  'Besetzung',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                for (final role in _document!.roles)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(role.name),
                    subtitle: Text(
                      role.actor.isEmpty ? 'Noch nicht besetzt' : role.actor,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _buildContent(BuildContext context) {
    if (_loading && _document == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text('Das Drehbuch wird vorbereitet …'),
          ],
        ),
      );
    }
    if (_document == null) {
      return _ReaderEmpty(
        icon: Icons.cloud_off_rounded,
        title: 'Noch kein Drehbuch auf dem Gerät.',
        message:
            _loadError ??
            'Öffne dieses Stück einmal mit Internetverbindung, um es offline zu lesen.',
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Erneut versuchen'),
        ),
      );
    }
    if (_entries.isEmpty) {
      return _ReaderEmpty(
        icon: Icons.filter_alt_off_outlined,
        title: 'Hier ist es gerade still.',
        message:
            'Für diese Auswahl sind keine Textstellen vorhanden. Passe deine Rolle oder die Leseeinstellungen an.',
        action: OutlinedButton(
          onPressed: _showSettings,
          child: const Text('Einstellungen öffnen'),
        ),
      );
    }
    return ScrollablePositionedList.builder(
      itemScrollController: _itemScroll,
      itemPositionsListener: _positions,
      itemCount: _entries.length,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 36),
      minCacheExtent: 600,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        if (entry.scene != null) {
          return _SceneHeading(
            key: ValueKey('scene-${entry.scene!.id}'),
            scene: entry.scene!,
            roles: _document!.roles,
            dark: _stage,
          );
        }
        final cue = entry.cue!;
        return _CueCard(
          key: ValueKey(cue.id),
          cue: cue,
          own: _own(cue),
          hidden:
              _mode == 'practice' && _own(cue) && !_revealed.contains(cue.id),
          hasNote: _notes.containsKey(cue.id),
          active: (_following || _directing) && cue.id == _liveFocus?.cueId,
          bookmarked: _bookmarks.contains(cue.id),
          fontScale: _fontScale * (_stage ? 1.2 : 1),
          dark: _stage,
          query: _searchController.text.trim(),
          onTap: () {
            setState(() {
              _activeCueId = cue.id;
              if (_mode == 'practice' && _own(cue)) {
                if (!_revealed.add(cue.id)) _revealed.remove(cue.id);
              }
            });
            _preference('lastCueId', cue.id);
            if (_directing) _publishFocus(cue);
          },
          onBookmark: () => _toggleBookmark(cue.id),
          onLongPress: () => _showCueActions(cue),
        );
      },
    );
  }

  void _jumpOwn(int direction) {
    final cues = _entries
        .where((e) => e.cue != null && _own(e.cue!))
        .map((e) => e.cue!)
        .toList();
    if (cues.isEmpty) {
      _showRoles();
      return;
    }
    final current = _cueIndices[_firstVisibleCueId] ?? 0;
    final options = cues
        .where(
          (c) => direction > 0
              ? (_cueIndices[c.id] ?? 0) > current
              : (_cueIndices[c.id] ?? 0) < current,
        )
        .toList();
    final cue = options.isEmpty
        ? (direction > 0 ? cues.first : cues.last)
        : (direction > 0 ? options.first : options.last);
    _jumpToCue(cue.id);
  }

  ScriptCue? get _currentCue =>
      _document?.cues
          .where((c) => c.id == (_activeCueId ?? _firstVisibleCueId))
          .firstOrNull ??
      _document?.cues.where((c) => c.kind == 'dialogue').firstOrNull;

  Widget _buildBottomBar(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: .15),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: 'Voriger eigener Einsatz',
            onPressed: () => _jumpOwn(-1),
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          IconButton(
            tooltip: 'Nächster eigener Einsatz',
            onPressed: () => _jumpOwn(1),
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          Tooltip(
            message: widget.controller.isOffline
                ? 'Offline lesbar'
                : 'Auf diesem Gerät gespeichert',
            child: Icon(
              widget.controller.isOffline
                  ? Icons.cloud_off_outlined
                  : Icons.offline_pin_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: 'Private Notizen',
            onPressed: _showNotes,
            icon: const Icon(Icons.edit_note),
          ),
          IconButton(
            tooltip: 'Kommentare zur Textstelle',
            onPressed: _currentCue == null
                ? null
                : () => _showComments(_currentCue!),
            icon: const Icon(Icons.chat_bubble_outline, size: 21),
          ),
          IconButton(
            tooltip: 'Lesezeichen öffnen',
            onPressed: _showBookmarks,
            icon: Icon(
              _bookmarks.isEmpty ? Icons.bookmark_border : Icons.bookmark,
              size: 22,
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _showRoles() async {
    final doc = _document;
    if (doc == null) return;
    final chosen = Set<String>.from(_roles);
    var assigned = _assignedRoles;
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => _SheetFrame(
          title: 'Rollen auswählen',
          subtitle: '',
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('Meine Rollen'),
                onTap: () => update(() {
                  assigned = true;
                  chosen.clear();
                  chosen.addAll(
                    doc.roles
                        .where(
                          (r) =>
                              r.personId != null &&
                              r.personId == widget.controller.user?.personId,
                        )
                        .map((r) => r.id),
                  );
                }),
              ),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Alle Rollen ohne Hervorhebung'),
                onTap: () => update(() {
                  assigned = false;
                  chosen.clear();
                }),
              ),
              for (final role in doc.roles)
                CheckboxListTile(
                  value: chosen.any(
                    (r) =>
                        r.toUpperCase() == role.id.toUpperCase() ||
                        r.toUpperCase() == role.name.toUpperCase(),
                  ),
                  title: Text(role.name),
                  subtitle: role.actor.isEmpty ? null : Text(role.actor),
                  onChanged: (value) => update(() {
                    assigned = false;
                    chosen.removeWhere(
                      (r) =>
                          r.toUpperCase() == role.id.toUpperCase() ||
                          r.toUpperCase() == role.name.toUpperCase(),
                    );
                    if (value == true) chosen.add(role.id);
                  }),
                ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: FilledButton(
                  onPressed: () => Navigator.pop(sheet, chosen),
                  child: const Text('Übernehmen'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _roles = result;
      _role = result.firstOrNull ?? '';
      _assignedRoles = assigned;
      _revealed.clear();
      if (!_hasRoles && (_mode == 'actor' || _mode == 'practice')) {
        _mode = 'read';
      }
      _rebuildEntries();
    });
    _preference('roles', result.toList());
    _preference('role', _role);
    _preference('assignedRoles', assigned);
    _preference('mode', _mode);
  }

  Future<void> _jumpToScene(String sceneId, {bool animate = true}) async {
    var index = _entries.indexWhere((entry) => entry.scene?.id == sceneId);
    if (index < 0) {
      setState(() {
        _mode = 'read';
        _rebuildEntries();
      });
      await _preference('mode', 'read');
      await Future<void>.delayed(Duration.zero);
      index = _entries.indexWhere((entry) => entry.scene?.id == sceneId);
    }
    if (!mounted || index < 0 || !_itemScroll.isAttached) return;
    if (animate && !MediaQuery.disableAnimationsOf(context)) {
      await _itemScroll.scrollTo(
        index: index,
        duration: const Duration(milliseconds: 320),
        alignment: 0.02,
      );
    } else {
      _itemScroll.jumpTo(index: index, alignment: 0.02);
    }
  }

  void _showScenes() {
    final doc = _document;
    if (doc == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _SheetFrame(
        title: 'Szenen',
        subtitle: '${doc.scenes.length} Szenen',
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: doc.scenes.length,
          itemBuilder: (context, index) {
            final scene = doc.scenes[index];
            ScriptCue? first;
            var ownCount = 0;
            for (final cue in doc.cues) {
              if (cue.sceneId != scene.id ||
                  cue.kind == 'scene' ||
                  cue.kind == 'role') {
                continue;
              }
              first ??= cue;
              if (_own(cue)) {
                ownCount++;
              }
            }
            final firstCue = first;
            return ListTile(
              selected: ownCount > 0,
              selectedTileColor: _accent.withValues(alpha: 0.08),
              selectedColor: _accent,
              leading: CircleAvatar(
                backgroundColor: _accent.withValues(
                  alpha: ownCount > 0 ? 0.25 : 0.06,
                ),
                foregroundColor: _accent,
                child: Text('${index + 1}'),
              ),
              title: Text(scene.title),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: firstCue == null
                  ? null
                  : () {
                      Navigator.pop(context);
                      _jumpToScene(scene.id);
                    },
            );
          },
        ),
      ),
    );
  }

  void _showBookmarks() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => _SheetFrame(
          title: 'Deine Lesezeichen',
          subtitle: '',
          child: ListView(
            shrinkWrap: true,
            children: [
              if (_bookmarks.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Noch keine Lesezeichen.'),
                ),
              for (final id in _bookmarks)
                Builder(
                  builder: (context) {
                    final cue = _document?.cues
                        .where((cue) => cue.id == id)
                        .firstOrNull;
                    return ListTile(
                      leading: const Icon(Icons.bookmark_outline),
                      title: Text(
                        cue == null
                            ? 'Nicht mehr zugeordnet'
                            : cue.role.isEmpty
                            ? 'Textstelle'
                            : cue.role,
                      ),
                      subtitle: Text(
                        cue?.text ?? 'Die Textstelle fehlt in dieser Fassung.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Lesezeichen entfernen',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _toggleBookmark(id);
                          update(() {});
                        },
                      ),
                      onTap: cue == null
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _jumpToCue(id);
                            },
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSettings() {
    const names = {
      'direction': 'Regieanweisungen',
      'technical': 'Technik',
      'lighting': 'Licht',
      'audio': 'Ton',
      'props': 'Requisiten',
      'microphone': 'Mikrofonhinweise',
      'autoMicrophone': 'Automatische Mikrofonhinweise',
    };
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => _SheetFrame(
          title: 'Leseeinstellungen',
          subtitle: '',
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Schriftgröße · ${(_fontScale * 100).round()} %',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Slider(
                    value: _fontScale,
                    min: .85,
                    max: 1.6,
                    divisions: 15,
                    onChanged: (v) {
                      setState(() => _fontScale = v);
                      update(() {});
                    },
                    onChangeEnd: (v) => _preference('fontScale', v),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Kontext um eigene Texte · $_contextLines Zeilen',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Slider(
                    value: _contextLines.toDouble(),
                    min: 0,
                    max: 6,
                    divisions: 6,
                    onChanged: (v) {
                      setState(() {
                        _contextLines = v.round();
                        _rebuildEntries();
                      });
                      update(() {});
                    },
                    onChangeEnd: (v) => _preference('contextLines', v.round()),
                  ),
                  const SizedBox(height: 20),
                  for (final category in names.entries)
                    Column(
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(category.value),
                          value: _categories.contains(category.key),
                          onChanged: (enabled) {
                            setState(() {
                              if (enabled) {
                                _categories.add(category.key);
                              } else {
                                _categories.remove(category.key);
                              }
                              _showDirections = _categories.contains(
                                'direction',
                              );
                              _showTechnical = _categories.any(
                                (c) => c != 'direction',
                              );
                              _rebuildEntries();
                            });
                            update(() {});
                            _preference('categories', _categories.toList());
                            _preference('showTechnical', _showTechnical);
                            _preference('showDirections', _showDirections);
                          },
                        ),
                        if (_mode == 'cues' &&
                            _categories.contains(category.key))
                          Row(
                            children: [
                              const Expanded(child: Text('Kontextzeilen')),
                              DropdownButton<int>(
                                value: _categoryContext[category.key] ?? 0,
                                items: [
                                  for (var i = 0; i <= 6; i++)
                                    DropdownMenuItem(
                                      value: i,
                                      child: Text('$i'),
                                    ),
                                ],
                                onChanged: (v) {
                                  setState(() {
                                    _categoryContext[category.key] = v!;
                                    _rebuildEntries();
                                  });
                                  update(() {});
                                  _preference(
                                    'categoryContext',
                                    _categoryContext,
                                  );
                                },
                              ),
                            ],
                          ),
                      ],
                    ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheet),
                      child: const Text('Fertig'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editNote(ScriptCue cue) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PrivateNoteEditor(
        initialText: textValue(jsonMap(_notes[cue.id])['text']),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result.isEmpty) {
        _notes.remove(cue.id);
      } else {
        _notes[cue.id] = {
          'text': result,
          'revision': _document!.revision,
          'sceneId': cue.sceneId,
          'role': cue.role,
        };
      }
    });
    await _preference('notes', _notes);
  }

  void _showComments(ScriptCue cue) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => CueCommentsScreen(
        controller: widget.controller,
        document: _document!,
        cue: cue,
      ),
    ),
  );

  void _showNotes() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => _SheetFrame(
        title: 'Private Notizen',
        subtitle: 'Nur auf diesem Gerät gespeichert',
        child: ListView(
          shrinkWrap: true,
          children: [
            if (_currentCue != null)
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Notiz an aktueller Textstelle'),
                onTap: () {
                  Navigator.pop(sheet);
                  _editNote(_currentCue!);
                },
              ),
            for (final entry in _notes.entries)
              Builder(
                builder: (context) {
                  final cue = _document?.cues
                      .where((c) => c.id == entry.key)
                      .firstOrNull;
                  final note = jsonMap(entry.value);
                  return ListTile(
                    leading: Icon(
                      cue == null ? Icons.link_off : Icons.edit_note,
                    ),
                    title: Text(
                      textValue(note['text']),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      cue == null
                          ? 'Nicht zugeordnet: andere Fassung'
                          : 'Szene ${cue.sceneId}${note['revision'] != _document!.revision ? ' · Aus älterer Fassung' : ''}',
                    ),
                    onTap: cue == null
                        ? null
                        : () {
                            Navigator.pop(sheet);
                            _jumpToCue(cue.id);
                            _editNote(cue);
                          },
                    trailing: cue != null
                        ? null
                        : IconButton(
                            tooltip: 'Verwaiste Notiz löschen',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              setState(() => _notes.remove(entry.key));
                              _preference('notes', _notes);
                              Navigator.pop(sheet);
                            },
                          ),
                  );
                },
              ),
            if (_notes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Noch keine Notizen.'),
              ),
          ],
        ),
      ),
    );
  }

  void _showCueActions(ScriptCue cue) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Private Notiz'),
              onTap: () {
                Navigator.pop(context);
                _editNote(cue);
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Kommentare'),
              onTap: () {
                Navigator.pop(context);
                _showComments(cue);
              },
            ),
            ListTile(
              leading: Icon(
                _bookmarks.contains(cue.id)
                    ? Icons.bookmark_remove_outlined
                    : Icons.bookmark_add_outlined,
              ),
              title: Text(
                _bookmarks.contains(cue.id)
                    ? 'Lesezeichen entfernen'
                    : 'Lesezeichen setzen',
              ),
              onTap: () {
                Navigator.pop(context);
                _toggleBookmark(cue.id);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Text kopieren'),
              onTap: () {
                Clipboard.setData(
                  ClipboardData(
                    text:
                        '${cue.role.isEmpty ? '' : '${cue.role}: '} ${cue.text}'
                            .trim(),
                  ),
                );
                Navigator.pop(context);
                _notice('Text kopiert.');
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _exportPdf() async {
    if (_document == null || _printing) return;
    final full = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Ganzes Drehbuch'),
              onTap: () => Navigator.pop(sheet, true),
            ),
            ListTile(
              leading: const Icon(Icons.filter_alt_outlined),
              title: const Text('Aktuelle Auswahl'),
              subtitle: const Text('Mit deinen Rollen- und Kategoriefiltern'),
              onTap: () => Navigator.pop(sheet, false),
            ),
          ],
        ),
      ),
    );
    if (full == null || !mounted) return;
    setState(() => _printing = true);
    try {
      final font = pw.Font.ttf(
        await rootBundle.load('assets/fonts/DejaVuSans.ttf'),
      );
      final boldFont = pw.Font.ttf(
        await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'),
      );
      final pdf = pw.Document(
        title: _title,
        author: 'Kolpingtheater Ramsen',
        theme: pw.ThemeData.withFont(
          base: font,
          bold: boldFont,
          italic: font,
          boldItalic: boldFont,
        ),
      );
      final entries = <_ReaderEntry>[];
      if (full) {
        String? previousScene;
        for (final cue in _document!.cues) {
          if (cue.kind == 'scene' || cue.kind == 'role') continue;
          if (previousScene != cue.sceneId) {
            final scene = _document!.scenes
                .where((scene) => scene.id == cue.sceneId)
                .firstOrNull;
            if (scene != null) entries.add(_ReaderEntry.scene(scene));
            previousScene = cue.sceneId;
          }
          entries.add(_ReaderEntry.cue(cue));
        }
      } else {
        entries.addAll(_entries);
      }
      pdf.addPage(
        pw.MultiPage(
          maxPages: 500,
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(40),
          header: (context) => pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 14),
            child: pw.Text(
              _title,
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
          ),
          footer: (context) => pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                _roles.isEmpty ? 'Alle Rollen' : 'Rollen: ${_roles.join(', ')}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.Text(
                '${context.pageNumber} / ${context.pagesCount}',
                style: const pw.TextStyle(fontSize: 9),
              ),
            ],
          ),
          build: (context) => [
            for (final entry in entries)
              if (entry.scene != null)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 20, bottom: 10),
                  child: pw.Text(
                    entry.scene!.title,
                    style: pw.TextStyle(
                      fontSize: 16,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                )
              else ...[
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 10, bottom: 3),
                  child: pw.Text(
                    entry.cue!.role.isEmpty
                        ? _category(entry.cue!.kind).label
                        : entry.cue!.role,
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.Text(
                  entry.cue!.text,
                  style: pw.TextStyle(
                    fontSize: 11,
                    lineSpacing: 3,
                    fontStyle: entry.cue!.kind == 'direction'
                        ? pw.FontStyle.italic
                        : pw.FontStyle.normal,
                    fontWeight: _own(entry.cue!)
                        ? pw.FontWeight.bold
                        : pw.FontWeight.normal,
                  ),
                ),
              ],
          ],
        ),
      );
      await Printing.layoutPdf(
        onLayout: (_) => pdf.save(),
        name: '${_title.replaceAll(RegExp(r'[^a-zA-Z0-9äöüÄÖÜß_-]'), '_')}.pdf',
      );
    } catch (_) {
      if (mounted) {
        _notice(
          'Das PDF konnte nicht erstellt werden. Bitte versuche es erneut.',
        );
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }
}

class _ReaderEntry {
  const _ReaderEntry.scene(this.scene) : cue = null;
  const _ReaderEntry.cue(this.cue) : scene = null;
  final ScriptScene? scene;
  final ScriptCue? cue;
}

class _SceneHeading extends StatelessWidget {
  const _SceneHeading({
    super.key,
    required this.scene,
    required this.roles,
    required this.dark,
  });
  final ScriptScene scene;
  final List<ScriptRole> roles;
  final bool dark;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 28, 16, 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SZENE ${scene.id}',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          scene.title,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

class _CueCard extends StatelessWidget {
  const _CueCard({
    super.key,
    required this.cue,
    required this.own,
    required this.active,
    required this.bookmarked,
    required this.fontScale,
    required this.dark,
    required this.query,
    required this.onTap,
    required this.onBookmark,
    required this.onLongPress,
    this.hidden = false,
    this.hasNote = false,
  });
  final ScriptCue cue;
  final bool own, active, bookmarked, dark, hidden, hasNote;
  final double fontScale;
  final String query;
  final VoidCallback onTap, onBookmark, onLongPress;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context),
        direction = cue.kind == 'direction',
        technical = _isTechnical(cue),
        category = _category(cue.kind);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: own
                      ? _accent
                      : active
                      ? theme.colorScheme.secondary
                      : Colors.transparent,
                  width: own ? 3 : 2,
                ),
              ),
              color: active
                  ? theme.colorScheme.secondary.withValues(alpha: .08)
                  : Colors.transparent,
            ),
            padding: const EdgeInsets.fromLTRB(16, 7, 12, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!direction || bookmarked || hasNote)
                  Row(
                    children: [
                      Expanded(
                        child: direction
                            ? const SizedBox.shrink()
                            : Text(
                                technical
                                    ? category.label.toUpperCase()
                                    : cue.role,
                                style: TextStyle(
                                  fontSize: 12 * fontScale,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1,
                                  color: own
                                      ? _accent
                                      : technical
                                      ? category.color
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                      ),
                      if (cue.isAutoMic)
                        Text('AUTO', style: theme.textTheme.labelSmall),
                      if (bookmarked)
                        IconButton(
                          tooltip: 'Lesezeichen entfernen',
                          onPressed: onBookmark,
                          icon: const Icon(Icons.bookmark, size: 17),
                          color: _accent,
                        ),
                      if (hasNote)
                        IconButton(
                          tooltip: 'Notiz zur Textstelle',
                          onPressed: onLongPress,
                          icon: const Icon(Icons.edit_note, size: 19),
                        ),
                    ],
                  ),
                if (!direction) const SizedBox(height: 7),
                if (hidden)
                  Semantics(
                    label: 'Eigener Text verdeckt. Zum Aufdecken antippen.',
                    button: true,
                    child: ExcludeSemantics(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Row(
                          children: [
                            Icon(
                              Icons.visibility_outlined,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Text aufdecken',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  Text.rich(
                    _highlightedText(
                      cue.text,
                      query,
                      TextStyle(
                        fontSize: (direction ? 16 : 19) * fontScale,
                        height: 1.6,
                        color: direction
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                        fontStyle: direction
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                    ),
                    semanticsLabel:
                        '${cue.role.isNotEmpty ? '${cue.role}: ' : ''}${cue.text}',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

TextSpan _highlightedText(String text, String query, TextStyle style) {
  if (query.isEmpty) return TextSpan(text: text, style: style);
  final lower = text.toLowerCase();
  final needle = query.toLowerCase();
  final spans = <TextSpan>[];
  var cursor = 0;
  while (cursor < text.length) {
    final index = lower.indexOf(needle, cursor);
    if (index == -1) {
      spans.add(TextSpan(text: text.substring(cursor)));
      break;
    }
    if (index > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, index)));
    }
    spans.add(
      TextSpan(
        text: text.substring(index, index + needle.length),
        style: const TextStyle(
          backgroundColor: Color(0xFFFFD289),
          color: Color(0xFF342111),
        ),
      ),
    );
    cursor = index + needle.length;
  }
  return TextSpan(style: style, children: spans);
}

({String label, IconData icon, Color color}) _category(String kind) =>
    switch (kind) {
      'direction' => (
        label: 'Regie',
        icon: Icons.edit_note_rounded,
        color: const Color(0xFF8D7A66),
      ),
      'technical' => (
        label: 'Technik',
        icon: Icons.tune_rounded,
        color: const Color(0xFF648895),
      ),
      'lighting' => (
        label: 'Licht',
        icon: Icons.light_mode_outlined,
        color: const Color(0xFFB1832D),
      ),
      'audio' => (
        label: 'Ton / Einspieler',
        icon: Icons.volume_up_outlined,
        color: const Color(0xFF8076AF),
      ),
      'props' => (
        label: 'Requisite',
        icon: Icons.inventory_2_outlined,
        color: const Color(0xFF62866D),
      ),
      'microphone' => (
        label: 'Mikrofon',
        icon: Icons.mic_none_rounded,
        color: const Color(0xFF4D8792),
      ),
      _ => (
        label: 'Text',
        icon: Icons.notes_rounded,
        color: const Color(0xFF888888),
      ),
    };

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title, subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Flexible(child: child),
        ],
      ),
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    ),
  );
}

class _ReaderEmpty extends StatelessWidget {
  const _ReaderEmpty({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title, message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: _accent),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    ),
  );
}
