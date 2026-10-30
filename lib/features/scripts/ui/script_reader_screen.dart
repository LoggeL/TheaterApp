import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../../app/shell/app_navigation.dart';
import '../../../app/shell/app_section.dart';
import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/breakpoints.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../casting/ui/production_overview_screen.dart';
import '../data/comments_repository.dart';
import '../data/reader_preferences.dart';
import '../data/script_pdf_exporter.dart';
import '../domain/cue_category.dart';
import '../domain/reader_entries.dart';
import '../domain/reader_mode.dart';
import '../domain/script_filter.dart';
import '../domain/script_roles.dart';
import '../state/live_focus_controller.dart';
import 'annotations/cue_comments_screen.dart';
import 'annotations/private_note_editor.dart';
import 'line_learning_screen.dart';
import 'widgets/cue_card.dart';
import 'widgets/reader_sheet_frame.dart';
import 'widgets/reader_style.dart';
import 'widgets/scene_heading.dart';

part 'reader/reader_annotations.dart';
part 'reader/reader_desktop.dart';
part 'reader/reader_live.dart';
part 'reader/reader_sheets.dart';
part 'reader/reader_toolbars.dart';

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

/// The view filters that automatic jumps may widen, kept for undo.
typedef _ViewFilters = ({
  ReaderMode mode,
  Set<String> categories,
  bool showDirections,
  bool showTechnical,
});

/// The scene shown in the title bar (and highlighted on desktops).
typedef _VisibleScene = ({String? id, String label});

/// The reader's stage theme per app theme, derived once.
final _stageThemes = Expando<ThemeData>('stage reader theme');

class _ScriptReaderScreenState extends State<ScriptReaderScreen>
    with WidgetsBindingObserver {
  final _itemScroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _saveTimer;

  /// The last cue in view, written at most every [_cueSaveInterval].
  String? _pendingCueId;

  /// The member who opened the reader; their place is never saved into
  /// another account that signed in meanwhile.
  String? _readerId;

  /// The production's script stamp last seen (see [_stampChanged]).
  String? _stamp;
  static const _cueSaveInterval = Duration(seconds: 5);
  Timer? _searchTimer;
  late final LiveFocusController _live;
  late final CommentsRepository _comments;
  ScriptDocument? _document;
  List<ReaderEntry> _entries = [];
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
  // Shared cues ("ROMEO & JULIA") are own text for every role speaking them.
  bool _own(ScriptCue cue) => cue.kind == 'dialogue' && cue.spokenByAny(_roles);
  bool get _hasRoles => _roles.isNotEmpty;
  ReaderMode _mode = ReaderMode.read;
  String? _activeCueId;
  String? _firstVisibleCueId;
  String? _loadError;

  /// Changes while scrolling; only the widgets showing it rebuild.
  final _scene = ValueNotifier<_VisibleScene>((id: null, label: ''));
  String? get _visibleSceneId => _scene.value.id;
  String? _pinnedSceneId, _pinnedAtCueId;
  bool _autoScrolling = false;
  double _fontScale = 1;
  int _contextLines = 2;
  int _searchResultIndex = 0;
  bool _showDirections = true;
  bool _showTechnical = true;
  bool _loading = true;
  bool _searching = false;
  bool _printing = false;
  bool _hintDismissed = false;

  bool get _stage => _mode == ReaderMode.stage;
  String get _title {
    for (final production in widget.controller.productions) {
      if (production.id == widget.productionId) return production.title;
    }
    return 'Drehbuch';
  }

  /// False once another account took over; the reader closes shortly after.
  bool get _sameMember => widget.controller.user?.id == _readerId;

  /// Lets the part files rebuild; `setState` is protected.
  void _update(VoidCallback change) => setState(change);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final saved = ReaderPreferences.read(
      widget.controller.preferences,
      widget.productionId,
    );
    _role = saved.role;
    _roles = saved.roles;
    _assignedRoles = saved.assignedRoles;
    _notes = saved.notes;
    _categories = saved.categories;
    _categoryContext = saved.categoryContext;
    _mode = saved.mode;
    _fontScale = saved.fontScale;
    _contextLines = saved.contextLines;
    _showDirections = saved.showDirections;
    _showTechnical = saved.showTechnical;
    _bookmarks = saved.bookmarks;
    _activeCueId = widget.initialCueId ?? saved.lastCueId;
    _live = LiveFocusController(
      controller: widget.controller,
      productionId: widget.productionId,
      revision: () => _document?.revision,
      onFollow: _followFocus,
      onPublishFailed: _notice,
    )..addListener(_rebuild);
    _comments = CommentsRepository(
      controller: widget.controller,
      productionId: widget.productionId,
    )..addListener(_rebuild);
    _positions.itemPositions.addListener(_onPositionsChanged);
    _readerId = widget.controller.user?.id;
    _stamp = widget.controller.scriptStamp(widget.productionId);
    widget.controller.addListener(_stampChanged);
    _document = widget.controller.scripts[widget.productionId];
    _loading = _document == null;
    _selectAssignedRoles();
    _rebuildEntries();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (_document == null) {
        _load();
      } else {
        // The stored script shows at once; whether the server has a newer
        // one is checked once the page is in place.
        _jumpToStart();
        await routeTransitionDone(context);
        if (mounted) _checkForUpdate();
      }
      _comments.ensureLoaded();
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveCue();
    widget.controller.removeListener(_stampChanged);
    _scene.dispose();
    _searchTimer?.cancel();
    _live.dispose();
    _comments.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _positions.itemPositions.removeListener(_onPositionsChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// A sync while the reader is open can bring a new revision or version
  /// (a cached snapshot at app start is the usual case): check once more,
  /// or comments and live focus would refer to an outdated version.
  void _stampChanged() {
    if (!mounted || !_sameMember || _document == null) return;
    final stamp = widget.controller.scriptStamp(widget.productionId);
    if (stamp == null || stamp == _stamp) return;
    _stamp = stamp;
    _checkForUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _live.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _saveCue();
    }
  }

  Future<void> _followFocus(String? cueId) async {
    if (cueId != null) {
      await _jumpToCue(cueId);
    } else if (mounted) {
      setState(() => _activeCueId = null);
    }
  }

  /// Stores a reader setting. Settings only the reader shows pass
  /// [notify] false, so changing them does not rebuild the app below.
  Future<void> _preference(
    String key,
    Object? value, {
    bool notify = true,
  }) async {
    try {
      await widget.controller.setPreference(
        ReaderPreferences.key(widget.productionId, key),
        value,
        notify: notify,
      );
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
      _jumpToStart();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Verbindung fehlgeschlagen. Bitte erneut versuchen.';
        });
      }
    }
  }

  /// Scrolls to the requested scene or cue, else to the last place read.
  void _jumpToStart() {
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
  }

  /// Fetches the script again only if it changed on the server, without a
  /// progress bar. A new version replaces the text in place, keeping the
  /// cue at the top in view.
  Future<void> _checkForUpdate() async {
    try {
      await widget.controller.loadScript(widget.productionId, ifChanged: true);
    } catch (_) {
      return;
    }
    final loaded = widget.controller.scripts[widget.productionId];
    if (!mounted || loaded == null || identical(loaded, _document)) return;
    final anchor = _firstVisibleCueId;
    setState(() {
      _document = loaded;
      _selectAssignedRoles();
      _rebuildEntries();
    });
    await WidgetsBinding.instance.endOfFrame;
    final index = _cueIndices[anchor];
    if (mounted && index != null && _itemScroll.isAttached) {
      _itemScroll.jumpTo(index: index);
    }
  }

  void _rebuildEntries() {
    final doc = _document;
    if (doc == null) return;
    final cues = visibleScriptCues(
      doc,
      roles: _roles,
      mode: _mode == ReaderMode.cues ? 'technical' : _mode.code,
      technicalFullText: _mode == ReaderMode.technical,
      categories: _categories,
      categoryContext: _categoryContext,
      contextLines: _contextLines,
      showDirections: _showDirections,
      showTechnical: _showTechnical || _mode.technicalFocus,
    );
    final entries = readerEntries(doc, cues);
    _entries = entries;
    _cueIndices = {
      for (var i = 0; i < entries.length; i++)
        if (entries[i].cue != null) entries[i].cue!.id: i,
    };
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
    final visible = [
      for (final position in positions)
        if (position.index < _entries.length) _entries[position.index],
    ];
    final cue = visible.map((entry) => entry.cue).nonNulls.firstOrNull;
    if (cue == null || _firstVisibleCueId == cue.id) return;
    _firstVisibleCueId = cue.id;
    // After a jump the target scene stays highlighted, even when the list
    // cannot scroll it to the top, until the member scrolls on.
    if (_pinnedSceneId != null && !_autoScrolling && cue.id != _pinnedAtCueId) {
      _pinnedSceneId = null;
    }
    final sceneId =
        _pinnedSceneId != null &&
            visible.any(
              (entry) =>
                  (entry.cue?.sceneId ?? entry.scene?.id) == _pinnedSceneId,
            )
        ? _pinnedSceneId!
        : cue.sceneId;
    final label = sceneTitle(_document!, sceneId);
    if (mounted) _scene.value = (id: sceneId, label: label);
    _pendingCueId = cue.id;
    _saveTimer ??= Timer(_cueSaveInterval, _saveCue);
  }

  /// Stores the last cue in view (see [_onPositionsChanged]), silently.
  void _saveCue() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final cueId = _pendingCueId;
    _pendingCueId = null;
    if (cueId != null) _saveLastCue(cueId);
  }

  void _saveLastCue(String cueId) {
    if (!_sameMember) return;
    if (widget.controller.preferences[ReaderPreferences.key(
          widget.productionId,
          'lastCueId',
        )] ==
        cueId) {
      return;
    }
    _preference('lastCueId', cueId, notify: false);
  }

  _ViewFilters _viewFilters() => (
    mode: _mode,
    categories: Set.of(_categories),
    showDirections: _showDirections,
    showTechnical: _showTechnical,
  );

  Future<void> _persistView() async {
    await _preference('mode', _mode.code, notify: false);
    await _preference('categories', _categories.toList(), notify: false);
    await _preference('showDirections', _showDirections, notify: false);
    await _preference('showTechnical', _showTechnical, notify: false);
  }

  /// Tells the member that a jump widened the view, with an undo.
  void _announceReveal(_ViewFilters before) {
    if (!mounted) return;
    final message = before.mode != _mode
        ? 'Ansicht auf „${_mode.label}“ umgestellt, damit die Textstelle sichtbar ist'
        : 'Weitere Hinweise eingeblendet, damit die Textstelle sichtbar ist';
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    showDone(
      context,
      message,
      actionLabel: 'Rückgängig',
      onAction: () => _restoreView(before),
    );
  }

  Future<void> _restoreView(_ViewFilters view) async {
    if (!mounted) return;
    setState(() {
      _mode = view.mode;
      _categories = Set.of(view.categories);
      _showDirections = view.showDirections;
      _showTechnical = view.showTechnical;
      _revealed.clear();
      _rebuildEntries();
    });
    await _persistView();
  }

  Future<void> _jumpToCue(String cueId, {bool animate = true}) async {
    if (!mounted) return;
    if (!_cueIndices.containsKey(cueId)) {
      final cue = _document?.cues.where((cue) => cue.id == cueId).firstOrNull;
      if (cue == null || !isReadableCue(cue)) {
        _notice('Diese Textstelle ist in dieser Fassung nicht vorhanden.');
        return;
      }
      final before = _viewFilters();
      setState(() {
        _mode = ReaderMode.read;
        if (cue.kind == 'direction') _showDirections = true;
        if (cue.isTechnical) _showTechnical = true;
        if (cue.kind != 'dialogue') _categories.add(cueCategory(cue));
        _rebuildEntries();
      });
      await _persistView();
      _announceReveal(before);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final index = _cueIndices[cueId];
    if (index == null) {
      _notice('Diese Textstelle ist in dieser Fassung nicht vorhanden.');
      return;
    }
    final sceneId = _document!.cues
        .firstWhere((cue) => cue.id == cueId)
        .sceneId;
    setState(() => _activeCueId = cueId);
    _scene.value = (id: sceneId, label: _scene.value.label);
    await _scrollTo(index, alignment: 0.08, animate: animate);
    _pendingCueId = null;
    _saveLastCue(cueId);
  }

  /// Scrolls to a scene. The reading mode changes only when the scene has
  /// nothing to show in the current one.
  Future<void> _jumpToScene(String sceneId, {bool animate = true}) async {
    int sceneIndex() =>
        _entries.indexWhere((entry) => entry.scene?.id == sceneId);
    var index = sceneIndex();
    if (index < 0 && _mode != ReaderMode.read) {
      final before = _viewFilters();
      setState(() {
        _mode = ReaderMode.read;
        _revealed.clear();
        _rebuildEntries();
      });
      await _preference('mode', _mode.code, notify: false);
      _announceReveal(before);
      await WidgetsBinding.instance.endOfFrame;
      index = sceneIndex();
    }
    if (!mounted || index < 0) return;
    _scene.value = (id: sceneId, label: sceneTitle(_document!, sceneId));
    await _scrollTo(index, alignment: 0.02, animate: animate);
  }

  /// Scrolls to [index] and keeps the scene of that entry highlighted.
  Future<void> _scrollTo(
    int index, {
    required double alignment,
    bool animate = true,
  }) async {
    if (!mounted || !_itemScroll.isAttached) return;
    final entry = _entries[index];
    _pinnedSceneId = entry.cue?.sceneId ?? entry.scene?.id;
    _autoScrolling = true;
    try {
      if (animate && !MediaQuery.disableAnimationsOf(context)) {
        await _itemScroll.scrollTo(
          index: index,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: alignment,
        );
      } else {
        _itemScroll.jumpTo(index: index, alignment: alignment);
      }
      await WidgetsBinding.instance.endOfFrame;
    } finally {
      _autoScrolling = false;
      _pinnedAtCueId = _firstVisibleCueId;
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _toggleBookmark(String cueId) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_bookmarks.add(cueId)) _bookmarks.remove(cueId);
    });
    _preference('bookmarks', _bookmarks.toList(), notify: false);
  }

  void _selectAssignedRoles() {
    if (!_assignedRoles || _document == null) return;
    _roles = assignedRoleIds(
      _document!.roles,
      widget.controller.user?.personId,
    );
    _role = _roles.firstOrNull ?? '';
  }

  void _changeMode(ReaderMode mode) {
    setState(() {
      _mode = mode;
      _revealed.clear();
      if (mode.technicalFocus) {
        _showTechnical = true;
        _categories.addAll(cueCategories.keys);
      }
      _rebuildEntries();
    });
    _preference('mode', mode.code, notify: false);
    _preference('categories', _categories.toList(), notify: false);
    if (mode.needsRoles && !_hasRoles) _showRoles();
  }

  bool _desktopReader(BuildContext context, double width) =>
      width >= Breakpoints.readerDesktop &&
      MediaQuery.textScalerOf(context).scale(16) <= 22 &&
      _fontScale <= 1.5;

  ScriptCue? get _currentCue =>
      _document?.cues
          .where((c) => c.id == (_activeCueId ?? _firstVisibleCueId))
          .firstOrNull ??
      _document?.cues.where((c) => c.kind == 'dialogue').firstOrNull;

  ThemeData _readerTheme(ThemeData parent) {
    if (!_stage) return parent;
    const stageSurface = Color(0xFF151719);
    final dark = StageTheme.build(Brightness.dark);
    return _stageThemes[dark] ??= dark.copyWith(
      colorScheme: dark.colorScheme.copyWith(surface: stageSurface),
      scaffoldBackgroundColor: stageSurface,
      appBarTheme: dark.appBarTheme.copyWith(backgroundColor: stageSurface),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final desktopHeader =
        width >= Breakpoints.extendedRail && _desktopReader(context, width);
    final readerTheme = _readerTheme(Theme.of(context));
    return Theme(
      data: readerTheme,
      child: Builder(
        builder: (context) => DesktopRouteFrame(
          controller: widget.controller,
          selectedIndex: AppSection.scripts.index,
          enabled: !_stage,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ): () =>
                  _setSearching(true),
              const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
                  _setSearching(true),
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (_searching) _setSearching(false);
              },
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                backgroundColor: readerTheme.scaffoldBackgroundColor,
                appBar: _buildAppBar(context, readerTheme, desktopHeader),
                body: Column(
                  children: [
                    if (_searching) _buildSearch(context),
                    if (_document != null) _buildToolbar(context),
                    if (_live.active) _buildLiveBanner(context),
                    if (_document != null &&
                        !_hintDismissed &&
                        widget.controller.preferences[ReaderPreferences
                                .hintCueActionsKey] !=
                            true &&
                        !_desktopReader(context, width))
                      _buildCueHint(context),
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
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    ThemeData readerTheme,
    bool desktopHeader,
  ) => AppBar(
    titleSpacing: 0,
    title: ValueListenableBuilder(
      valueListenable: _scene,
      builder: (context, scene, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: desktopHeader ? 20 : 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (scene.label.isNotEmpty)
            Text(
              scene.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: readerTheme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    ),
    actions: [
      if (desktopHeader && _document != null) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.offline_pin_outlined,
                size: 18,
                color: readerTheme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Offline verfügbar',
                style: readerTheme.textTheme.labelMedium,
              ),
            ],
          ),
        ),
        TextButton.icon(
          key: const ValueKey('reader-desktop-pdf'),
          onPressed: _printing ? null : _exportPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
          label: Text(_printing ? 'PDF wird erstellt …' : 'PDF'),
        ),
        const SizedBox(width: 8),
      ],
      IconButton(
        tooltip: 'Im Drehbuch suchen',
        onPressed: () => _setSearching(!_searching),
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
            case 'learn':
              openPage(
                context,
                LineLearningScreen(
                  controller: widget.controller,
                  productionId: widget.productionId,
                ),
              );
            case 'notes':
              _showNotes();
            case 'bookmarks':
              _showBookmarks();
            case 'export':
              _exportPdf();
            case 'refresh':
              _refreshScript();
            case 'focus':
              _showLive();
            case 'casting':
              openPage(
                context,
                ProductionOverviewScreen(
                  controller: widget.controller,
                  productionId: widget.productionId,
                ),
              );
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'settings',
            child: Text('Leseeinstellungen'),
          ),
          PopupMenuItem(
            value: 'learn',
            enabled: _document != null,
            child: const Text('Text lernen'),
          ),
          const PopupMenuItem(value: 'notes', child: Text('Private Notizen')),
          PopupMenuItem(
            value: 'focus',
            enabled: _document != null,
            child: const Text('Gemeinsamer Fokus'),
          ),
          const PopupMenuItem(value: 'bookmarks', child: Text('Lesezeichen')),
          PopupMenuItem(
            value: 'export',
            enabled: _document != null && !_printing,
            child: Text(_printing ? 'PDF wird erstellt …' : 'Drucken / PDF'),
          ),
          const PopupMenuItem(
            value: 'refresh',
            child: Text('Fassung aktualisieren'),
          ),
          const PopupMenuItem(
            value: 'casting',
            child: Text('Besetzung & Team'),
          ),
        ],
      ),
    ],
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
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(
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
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(
            icon: Icons.filter_alt_off_outlined,
            title: 'Hier ist es gerade still.',
            message:
                'Für diese Auswahl sind keine Textstellen vorhanden. Passe deine Rolle oder die Leseeinstellungen an.',
            action: OutlinedButton(
              onPressed: _showSettings,
              child: const Text('Einstellungen öffnen'),
            ),
          ),
        ),
      );
    }
    final desktop = _desktopReader(context, MediaQuery.sizeOf(context).width);
    return ScrollablePositionedList.builder(
      itemScrollController: _itemScroll,
      itemPositionsListener: _positions,
      itemCount: _entries.length,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 36),
      minCacheExtent: 600,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        if (entry.scene != null) {
          return SceneHeading(
            key: ValueKey('scene-${entry.scene!.id}'),
            scene: entry.scene!,
          );
        }
        final cue = entry.cue!;
        return CueCard(
          key: ValueKey(cue.id),
          cue: cue,
          own: _own(cue),
          hidden:
              _mode == ReaderMode.practice &&
              _own(cue) &&
              !_revealed.contains(cue.id),
          hasNote: _notes.containsKey(cue.id),
          commentCount: _comments.countFor(cue.id),
          active: cue.id == _live.activeCueId,
          bookmarked: _bookmarks.contains(cue.id),
          fontScale: _fontScale * (_stage ? 1.2 : 1),
          dark: _stage,
          query: _searchController.text.trim(),
          showActionsButton: desktop,
          onTap: () {
            setState(() {
              _activeCueId = cue.id;
              if (_mode == ReaderMode.practice && _own(cue)) {
                if (!_revealed.add(cue.id)) _revealed.remove(cue.id);
              }
            });
            _pendingCueId = null;
            _saveLastCue(cue.id);
            if (_live.directing) _live.publish(cue.id);
          },
          onBookmark: () => _toggleBookmark(cue.id),
          onActions: () => _showCueActions(cue),
          onNote: () => _editNote(cue),
          onComments: () => _showComments(cue),
        );
      },
    );
  }
}
