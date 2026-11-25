import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../app/shell/app_navigation.dart';
import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/breakpoints.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../data/leaderboard_api.dart';
import '../data/missions_api.dart';
import '../data/runner_menu_preferences.dart';
import '../data/runner_motion_preferences.dart';
import '../data/score_outbox.dart';
import '../data/wardrobe_api.dart';
import '../data/weekly_api.dart';
import '../domain/runner_ghost.dart';
import '../domain/stage_runner.dart';
import 'ensemble_card.dart' show EnsembleStrip;
import 'gala.dart';
import 'missions_card.dart';
import 'next_drop.dart';
import 'runner_menu.dart';
import 'runner_news.dart';
import 'runner_volume_settings.dart';
import 'runner_weekly.dart';
import 'stage_runner_art.dart';
import 'stage_runner_fx.dart';
import 'stage_runner_ghosts.dart';
import 'stage_runner_look.dart';
import 'stage_runner_music.dart';
import 'stage_runner_perf.dart';
import 'stage_runner_sound.dart';
import 'wardrobe_screen.dart';

/// Android draws the app behind its navigation bar (edge-to-edge, enforced
/// from Android 15); the three-button bar, at the left or right edge in
/// landscape, lays a translucent veil over it. During a run the stage passes
/// right to the screen's edge, so the veil would half hide whatever runs
/// out there: the bar stays clear while running, only its light buttons
/// lie on the dark stage. Elsewhere the system's veil keeps the buttons
/// readable. Light buttons are what the app bar asks for anyway.
@visibleForTesting
const runnerBarsPlaying = SystemUiOverlayStyle(
  systemNavigationBarContrastEnforced: false,
  systemNavigationBarIconBrightness: Brightness.light,
);
@visibleForTesting
const runnerBarsDefault = SystemUiOverlayStyle(
  systemNavigationBarContrastEnforced: true,
  systemNavigationBarIconBrightness: Brightness.light,
);

/// Opens the stage runner.
Future<void> openStageRunner(BuildContext context, AppController controller) =>
    openPage<void>(context, StageRunnerScreen(controller: controller));

enum _Phase { intro, playing, finished }

/// Whether the screen is a phone's: its shorter side below
/// [Breakpoints.compact] (600 logical pixels, Material's "compact" window
/// class). Turned sideways a large phone is wider than [Breakpoints.rail],
/// and the route frame would put the section rail beside the game; on
/// phones the Bühnenlauf covers it and uses the whole screen instead.
/// Tablets and desktop windows keep the rail.
@visibleForTesting
bool runnerCoversRail(Size size) => size.shortestSide < Breakpoints.compact;

/// From this width the menu shows the hero (or the result) beside the rest,
/// e.g. on a phone held sideways (844 × 390) and on tablets.
const _twoColumns = 720.0;

/// "Bühnenlauf": an endless run on the flying wire with the ensemble's
/// shared leaderboard.
class StageRunnerScreen extends StatefulWidget {
  const StageRunnerScreen({
    super.key,
    required this.controller,
    this.random,
    this.onRun,
    this.sound,
    this.motionPreferences,
    this.menuPreferences,
    this.news = runnerNews,
  });
  final AppController controller;

  /// The entries of "Neu im Bühnenlauf"; replaced in tests.
  @visibleForTesting
  final List<RunnerNews> news;

  /// Where the menu's small choices are kept; by default on this device.
  @visibleForTesting
  final RunnerMenuPreferences? menuPreferences;

  /// Replaced in tests; by default the [RunnerSound] of this platform.
  @visibleForTesting
  final RunnerSound? sound;

  @visibleForTesting
  final RunnerMotionPreferences? motionPreferences;

  /// Fixed in tests for reproducible courses.
  final Random? random;

  /// Gets each new run, so tests can follow it.
  @visibleForTesting
  final ValueChanged<StageRunner>? onRun;

  /// Step duration for the 3-2-1 countdown when resuming from pause.
  @visibleForTesting
  static Duration resumeCountdownStep = const Duration(milliseconds: 500);

  @override
  State<StageRunnerScreen> createState() => _StageRunnerScreenState();
}

class _StageRunnerScreenState extends State<StageRunnerScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastFrame = Duration.zero;
  _Phase _phase = _Phase.intro;
  StageRunner _game = StageRunner();
  RunnerFx _fx = RunnerFx();

  /// Frame times of the current run for the performance telemetry.
  RunnerPerf? _perf;

  /// The art in the worn costume (see [dressArt]); the default art until
  /// the wardrobe is known.
  RunnerArt? _art = RunnerArt.loaded;
  RunnerTrail _trail = RunnerTrail();
  late final RunnerSound _sound = widget.sound ?? RunnerSound();
  late final RunnerMotionPreferences _motion =
      widget.motionPreferences ?? RunnerMotionPreferences();
  bool _systemReducedMotion = false,
      _settingsOpen = false,
      _overlayActive = false,
      _newsChecked = false;

  late final RunnerMenuPreferences _menu =
      widget.menuPreferences ?? RunnerMenuPreferences();
  late final RunnerScoreOutbox _outbox = runnerScoreOutbox(controller);
  RoundResult? _seenOutboxResult;

  bool get _sceneryMotion =>
      _motion.ready && _motion.sceneryMotion && !_systemReducedMotion;

  /// The wardrobe, if the server offers it, and the progress after the last
  /// run.
  Wardrobe? _wardrobe;
  RunnerProgress? _progress;

  /// The day's Tagesmissionen (`runnerMissions`), the watch of the current
  /// run, its live progress pill and its banner when the run makes one.
  DailyMissions? _missions;
  MissionWatch? _watch;
  final _missionBanner = ValueNotifier<DailyMission?>(null);
  final _liveMission = ValueNotifier<String?>(null);
  double _bannerUntil = 0;
  bool get _missionsOn => missionsAvailable(controller);

  /// What the worn backdrop calls the pickups, for the missions' texts.
  Map<String, String> get _pickupNames =>
      _wardrobe?.worn(WardrobeKind.backdrop)?.collectibleNames ?? const {};

  /// The closing line of the last run; its own dice, so courses stay
  /// reproducible.
  final _lines = Random();
  String _line = '';

  /// Repaints the stage without rebuilding widgets; the HUD only rebuilds
  /// when its numbers change.
  final _frame = _FrameSignal();
  final _hud = ValueNotifier<(int, int)>((0, 0));
  int _lastHudScore = 0, _lastHudMeters = 0;
  // Cached mission live-pill state so _tick does zero string/RegExp work when
  // mission counters have not changed.
  Map<DailyMission, String> _missionUnits = const {};
  int _lastMissionMeters = -1,
      _lastMissionScore = -1,
      _lastMissionCollected = -1,
      _lastMissionGround = -1,
      _lastMissionCeiling = -1,
      _lastMissionPassed = -1;
  DailyMission? _lastLiveMission;
  int _lastLiveValue = -1;
  final _activePointers = <int>{};
  final _resumeIgnoredKeys = <LogicalKeyboardKey>{};
  final _playFocus = FocusNode(debugLabel: 'runner-stage');
  final _startFocus = FocusNode(debugLabel: 'runner-start');
  bool _didAutoFocusStart = false;

  /// Increases with every run, so late server replies of an earlier run are
  /// ignored.
  int _run = 0;
  Future<String?>? _start;
  Leaderboard? _board;
  String? _boardError, _saveError;
  bool _loadingBoard = false,
      _saving = false,
      _improved = false,
      _unrankedOffline = false;

  /// The collection ranking; [_collectionMissing] once the server answered
  /// that it does not know it (404): the menu then leaves it out.
  CollectionBoard? _collection;
  String? _collectionError;
  bool _loadingCollection = false, _collectionMissing = false;
  bool get _collectionShown =>
      collectionBoardAvailable(controller) && !_collectionMissing;

  /// The Monatsrangliste; [_monthlyFailed] once it could not be loaded
  /// without a list in hand: the menu then shows the all-time list as before.
  Leaderboard? _monthly;
  bool _monthlyFailed = false;
  bool get _monthShown => monthlyBoardAvailable(controller) && !_monthlyFailed;

  /// Whether the last run's result waits in the outbox for a connection.
  bool _queued = false;

  /// The Wochenprobe (`runnerWeekly`): this week as last loaded, for the
  /// menu's entry; the mode of the current (or last) run, null for a normal
  /// one; the ghost a ranked run records and the figure it runs in; the
  /// ghosts it shows with their figures; and what its result changed.
  WeeklyChallenge? _weekly;
  WeeklyPlay? _weeklyPlay;
  GhostRecorder? _recorder;
  String? _runFigure;
  RunnerGhosts? _ghosts;
  GhostSkins? _ghostSkins;
  WeeklyRunResult? _weeklyResult;
  bool get _weeklyShown => weeklyAvailable(controller);

  /// "Neu im Bühnenlauf", offered once as the menu opens; completes with
  /// whether it led to another page (the gala's celebration then waits for
  /// the next visit).
  Future<bool>? _news;

  /// The stage's size in this run, whether the run waits in pause, and the
  /// remaining 3-2-1 countdown steps before flying on.
  Size? _stageSize;
  bool _paused = false;
  int _resumeCountdown = 0;
  Timer? _countdownTimer;
  // Staggered idle pre-warming of Web GPU decoration textures while on the
  // intro menu, eliminating the synchronous first-frame bake spike on Start.
  Timer? _prewarmTimer;
  Size? _prewarmSize;
  double _prewarmRatio = 0;
  int _prewarmStep = 0;

  AppController get controller => widget.controller;
  bool get _ranked => leaderboardAvailable(controller);
  bool get _dressable => wardrobeAvailable(controller);

  /// Whether to point out today's open Tagesbonus before the next run: as
  /// the last run left it, else as the wardrobe said.
  bool get _bonusOpen =>
      dailyBonusAvailable(controller) &&
      (_progress ?? _wardrobe?.progress)?.bonusOpen == true;

  /// The music holds while the app is in the background.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _outbox.addListener(_outboxChanged);
    _lifecycle = AppLifecycleListener(
      // Control Center, a call or another app in front: the run waits for a
      // resume, as after a new size, instead of flying on unsteered (a ranked
      // attempt of the Wochenprobe has no second try).
      onInactive: _pauseRun,
      onHide: () {
        if (_pauseRun()) return;
        if (_sound case final RunnerMusic music) music.pauseMusic();
      },
      onShow: () {
        if (_ranked && _outbox.waiting > 0) {
          unawaited(_retryOutbox(silent: true));
        }
        if (_paused || _resumeCountdown > 0) return;
        if (_sound case final RunnerMusic music) music.resumeMusic();
      },
    );
    if (_ranked) {
      unawaited(_initRanked());
    } else if (_weeklyShown) {
      unawaited(_loadWeekly());
    }
    if (_collectionShown) _loadCollection();
    _menu.addListener(_menuChanged);
    if (_art == null) {
      RunnerArt.load().then((art) {
        if (mounted && art != null) {
          setState(() => _art = art);
          // A run that started without art: its ghosts' figures now.
          _ghostSkins?.artReady(art);
        }
        _dress();
      });
    }
    if (_dressable) _loadWardrobe();
    // Native players load during the intro; browsers preload only bytes.
    // The browser's audio context still opens in the start gesture.
    _sound.enabled.addListener(_soundChanged);
    _motion.addListener(_motionChanged);
    if (_sound case final RunnerMusic music) music.warmUp();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _news = _offerNews();
    });
  }

  /// Sends waiting offline scores before loading the boards so newly delivered
  /// scores show up right away; without any waiting, loads immediately.
  Future<void> _initRanked() async {
    if (_outbox.waiting > 0) {
      await _retryOutbox(silent: true);
    }
    if (!mounted) return;
    unawaited(_loadBoard());
    if (_monthShown) unawaited(_loadMonthly());
    if (_weeklyShown) unawaited(_loadWeekly());
  }

  void _outboxChanged() {
    if (!mounted) return;
    final latest = _outbox.lastResult;
    final applyResult = latest != null && !identical(latest, _seenOutboxResult);
    if (applyResult) _seenOutboxResult = latest;
    setState(() {
      if (applyResult && _phase != _Phase.playing) {
        _board = latest.leaderboard;
        _boardError = null;
        if (latest.progress case final p?) _progress = p;
        if (latest.progress?.missions case final m?) _missions = m;
        if (latest.weekly case final w? when _weeklyPlay != null) {
          _weeklyResult = w;
        }
      }
      if (_outbox.waiting == 0 && _queued) {
        _queued = false;
        _saveError = null;
      }
    });
  }

  Future<void> _retryOutbox({bool silent = false}) async {
    if (_outbox.waiting == 0) return;
    final sent = await _outbox.retry();
    if (!mounted) return;
    if (sent > 0) {
      final latest = _outbox.lastResult;
      if (latest != null) _seenOutboxResult = latest;
      setState(() {
        if (latest != null) {
          _board = latest.leaderboard;
          _boardError = null;
          if (latest.progress case final p?) _progress = p;
          if (latest.progress?.missions case final m?) _missions = m;
          if (latest.weekly case final w? when _weeklyPlay != null) {
            _weeklyResult = w;
          }
        }
        if (_outbox.waiting == 0) {
          _queued = false;
          _saveError = null;
        }
      });
      if (_monthShown) unawaited(_loadMonthly());
      if (_weeklyShown) unawaited(_loadWeekly());
      if (_dressable) unawaited(_refreshWardrobe());
      if (!silent) {
        showDone(
          context,
          sent == 1
              ? '1 gespeicherter Lauf wurde nachgetragen.'
              : '$sent gespeicherte Läufe wurden nachgetragen.',
        );
      }
    } else if (!silent) {
      showProblem(
        context,
        'Gerade keine Verbindung. Die gespeicherten Läufe bleiben in der Warteschlange.',
      );
    }
  }

  /// Shows the newest entry of "Neu im Bühnenlauf" not seen on this device,
  /// once the menu is free: not during a run, nor over another dialog or
  /// page. It counts as seen as soon as it shows.
  Future<bool> _offerNews() async {
    try {
      await _menu.loaded;
      if (!mounted ||
          !_menu.newsKnown ||
          _phase != _Phase.intro ||
          _settingsOpen ||
          ModalRoute.of(context)?.isCurrent == false) {
        return false;
      }
      final pending = pendingRunnerNews(
        widget.news,
        _menu.newsSeen,
        (news) => news.offered?.call(controller) ?? true,
      );
      if (pending == null) return false;
      _menu.markNewsSeen(pending.seen);
      setState(() => _overlayActive = true);
      final RunnerNewsAction? action;
      try {
        action = await showRunnerNews(context, pending.news);
      } finally {
        if (mounted) setState(() => _overlayActive = false);
      }
      if (!mounted || _phase != _Phase.intro) return false;
      switch (action) {
        case RunnerNewsAction.weekly:
          unawaited(_openWeekly());
          return true;
        case null:
          return false;
      }
    } finally {
      if (mounted) {
        if (!_newsChecked) setState(() => _newsChecked = true);
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFocusStart());
      }
    }
  }

  void _maybeFocusStart() {
    if (_didAutoFocusStart ||
        !mounted ||
        !_newsChecked ||
        _phase != _Phase.intro ||
        _overlayActive ||
        _settingsOpen ||
        !_motion.ready ||
        !_startFocus.canRequestFocus ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _didAutoFocusStart = true;
    _startFocus.requestFocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (_systemReducedMotion != reduced) {
      _systemReducedMotion = reduced;
      _frame.tick();
    }
  }

  void _menuChanged() {
    if (!mounted) return;
    setState(() {});
    // "Geister: Aus / Wenige / Alle", also changed during a run (its
    // pause): it applies at once, and only figures now shown load.
    final ghosts = _ghosts;
    if (ghosts != null && ghosts.mode != _menu.ghostMode) {
      ghosts.mode = _menu.ghostMode;
      _ghostSkins?.want(ghosts.wanted, _art);
      _frame.tick();
    }
  }

  void _motionChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFocusStart());
    // The painter is kept across builds; a paused stage needs a repaint too.
    _frame.tick();
  }

  Future<void> _showSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    if (_phase == _Phase.playing && !_paused) {
      _pauseRun();
    }
    if (_sound case final RunnerMusicPreview preview) {
      preview.refreshOtherMusic();
    }
    String? saveError;
    var saveRequest = 0;
    final ghosts = _weeklyShown;
    final volumes = _sound is RunnerVolumes ? _sound as RunnerVolumes : null;
    // More than the scenery's motion: a section each.
    final sections = ghosts || volumes != null;
    // Turning the music slider lets the music be heard right away: in a paused
    // run it resumes the run's music while the dialog is open; in the menu it
    // starts a short preview. Adjusting only effects does not resume music.
    var musicHeard = false;
    var previewedMusic = false;
    void hearMusic() {
      if (_phase == _Phase.playing && _paused) {
        if (musicHeard) return;
        musicHeard = true;
        if (_sound case final RunnerMusic music) music.resumeMusic();
      } else if (_phase != _Phase.playing) {
        if (previewedMusic) return;
        previewedMusic = true;
        if (_sound case final RunnerMusicPreview preview) {
          preview.startMusicPreview();
        }
      }
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, updateDialog) => ListenableBuilder(
            listenable: _motion,
            builder: (context, _) {
              final reduced = MediaQuery.disableAnimationsOf(context);
              return AlertDialog(
                scrollable: true,
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                // The volumes, and with the Wochenprobe its ghosts, are
                // chosen here too, also in the pause of a run: they apply
                // at once.
                title: Text(sections ? 'Spieleinstellungen' : 'Bewegung'),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (volumes != null) ...[
                        RunnerVolumeSettings(
                          key: const ValueKey('runner-volumes'),
                          sound: _sound,
                          volumes: volumes,
                          onMusicAdjust: hearMusic,
                        ),
                        const Divider(height: 32),
                      ],
                      if (sections)
                        Text(
                          'Bewegung',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      SwitchListTile(
                        key: const ValueKey('runner-scenery-motion'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Bühne bewegen'),
                        value:
                            _motion.ready && _motion.sceneryMotion && !reduced,
                        onChanged: !_motion.ready || reduced
                            ? null
                            : (value) async {
                                final request = ++saveRequest;
                                updateDialog(() => saveError = null);
                                try {
                                  await _motion.setSceneryMotion(value);
                                } catch (_) {
                                  if (!dialogContext.mounted ||
                                      request != saveRequest) {
                                    return;
                                  }
                                  updateDialog(
                                    () => saveError =
                                        'Die Auswahl gilt für jetzt, konnte aber nicht auf diesem Gerät gespeichert werden.',
                                  );
                                }
                              },
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Gilt für Hintergrund, Vorhänge, Licht und Publikum. Hindernisse und Sammelobjekte bewegen sich weiter.',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        reduced
                            ? 'Auf deinem Gerät ist „Bewegung reduzieren“ aktiv.'
                            : 'Deine Auswahl wird auf diesem Gerät gespeichert.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (saveError != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          saveError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      if (ghosts) ...[
                        const Divider(height: 32),
                        GhostModeChoice(
                          key: const ValueKey('runner-ghosts'),
                          preferences: _menu,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Gilt für Wertungsläufe und Training der Wochenprobe.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Fertig'),
                  ),
                ],
              );
            },
          ),
        ),
      );
    } finally {
      _settingsOpen = false;
    }
    if (previewedMusic) {
      if (_sound case final RunnerMusicPreview preview) {
        preview.stopMusicPreview();
      }
    }
    if (musicHeard && mounted && _phase == _Phase.playing && _paused) {
      if (_sound case final RunnerMusic music) music.pauseMusic();
    }
    if (mounted && _phase == _Phase.playing) {
      _playFocus.requestFocus();
    }
    // An interrupted run stays paused until the player resumes it.
  }

  /// Only the worn costume is loaded; without it the default one plays.
  Future<void> _loadWardrobe() async {
    try {
      final w = await loadWardrobe(controller);
      // A late reply must not undo what was worn in the wardrobe meanwhile.
      if (!mounted || _wardrobe != null) return;
      setState(() => _wardrobe = w);
      await _dress();
      // Not over the news; after it, unless that led elsewhere.
      if (await (_news ?? Future.value(false))) return;
      if (mounted && _phase == _Phase.intro) {
        setState(() => _overlayActive = true);
        try {
          await celebrateGala(
            context,
            controller: controller,
            wardrobe: w,
            sound: _sound,
            onChanged: (next) {
              if (mounted) setState(() => _wardrobe = next);
            },
          );
        } finally {
          if (mounted) setState(() => _overlayActive = false);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Garderobe nicht geladen: $e');
    }
  }

  /// Refreshes the wardrobe after a run or outbox sync so freshly earned
  /// crates and progress are already present when opening the wardrobe.
  Future<void> _refreshWardrobe() async {
    if (!_dressable) return;
    try {
      final w = await loadWardrobe(controller);
      if (!mounted) return;
      final worn = _wardrobe;
      setState(() => _wardrobe = w);
      if (worn == null || outfitOf(w) != outfitOf(worn)) {
        unawaited(_dress());
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Bühnenlauf: Garderobe nicht aktualisiert: $e');
      }
    }
  }

  /// A fresh wardrobe when the drop countdown reaches zero: the new
  /// costumes join the catalog. Not during a run, where it would only wait:
  /// the countdown asks again once the menu shows it. False when none came.
  Future<bool> _reloadWardrobe() async {
    if (!_dressable || _phase == _Phase.playing) return false;
    try {
      final w = await loadWardrobe(controller);
      if (!mounted || _phase == _Phase.playing) return false;
      final worn = _wardrobe;
      setState(() {
        _wardrobe = w;
        if (_progress != null) _progress = w.progress;
      });
      if (worn == null || outfitOf(w) != outfitOf(worn)) {
        await _dress();
      }
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Garderobe nicht neu geladen: $e');
      return false;
    }
  }

  Future<void> _dress() async {
    unawaited(_tune());
    final base = RunnerArt.loaded, w = _wardrobe;
    if (base == null || w == null) return;
    final art = await dressArt(base, w, controller);
    if (mounted && identical(w, _wardrobe)) {
      setState(() => _art = art);
      _ghostSkins?.artReady(art);
      _outfit = dressedOutfit(w);
      _perf?.skin();
    }
  }

  /// The costume [_art] is dressed in, as [outfitOf] says; null for none yet.
  String? _outfit;

  int _tuneRequest = 0;

  void _soundChanged() {
    if (_sound.enabled.value) unawaited(_tune());
  }

  /// Gives the sound the worn backdrop's music; without one (or until it
  /// is loaded) the game's own tune plays.
  Future<void> _tune() async {
    if (_sound is! RunnerMusic) return;
    final request = ++_tuneRequest;
    await runnerSoundSettingsReady(_sound);
    if (!mounted || !_sound.enabled.value || request != _tuneRequest) return;
    final path = RunnerTunes.of(_wardrobe);
    final tune = await RunnerTunes.load(controller, path);
    if (!mounted ||
        !_sound.enabled.value ||
        request != _tuneRequest ||
        path != RunnerTunes.of(_wardrobe)) {
      return;
    }
    if (_sound case final RunnerMusic music) music.useTune(tune);
  }

  Future<void> _openWardrobe({int initialTab = 0}) async {
    var changed = false;
    final worn = _wardrobe;
    await openWardrobe(
      context,
      controller,
      wardrobe: worn,
      dressed: worn != null && outfitOf(worn) == _outfit ? _art : null,
      sound: _sound,
      initialTab: initialTab,
      onChanged: (w) {
        if (!mounted) return;
        changed = true;
        setState(() {
          _wardrobe = w;
          if (_progress != null) _progress = w.progress;
        });
        // [_outfit] moves with a finished dress only: back on the costume
        // still shown, the dress on its way is dropped, but the music of
        // that other backdrop may already be playing.
        if (outfitOf(w) != _outfit) {
          _dress();
        } else {
          unawaited(_tune());
        }
      },
    );
    // Opened crates move the own place in the collection ranking.
    if (mounted && changed && _collectionShown) unawaited(_loadCollection());
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _prewarmTimer?.cancel();
    _outbox.removeListener(_outboxChanged);
    // Left during a run: the rest of the app gets the usual bar back. Only
    // Android has that bar; in browsers the call would only drop the
    // page's theme colour.
    if (_phase == _Phase.playing) {
      _perf?.finish(_wardrobe, end: 'quit');
      // Crashed, but left before the curtain had closed: that run is over
      // and counts like any other. The outbox outlives this page. A run
      // left in mid-flight stays abandoned.
      if (_game.over) {
        if (_runScore() case final score?) {
          unawaited(
            runnerScoreOutbox(
              controller,
            ).send(score).then<void>((_) {}, onError: (Object _) {}),
          );
        }
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        SystemChrome.setSystemUIOverlayStyle(runnerBarsDefault);
      }
    }
    _lifecycle.dispose();
    _sound.enabled.removeListener(_soundChanged);
    _motion.removeListener(_motionChanged);
    if (widget.motionPreferences == null) _motion.dispose();
    _menu.removeListener(_menuChanged);
    if (widget.menuPreferences == null) _menu.dispose();
    _painter?.dispose();
    _ghostSkins?.dispose();
    _sound.stopMusic();
    if (widget.sound == null) _sound.dispose();
    _ticker.dispose();
    _playFocus.dispose();
    _startFocus.dispose();
    _frame.dispose();
    _hud.dispose();
    _missionBanner.dispose();
    _liveMission.dispose();
    super.dispose();
  }

  Future<void> _loadBoard() async {
    setState(() {
      _loadingBoard = true;
      _boardError = null;
    });
    try {
      final board = await loadLeaderboard(controller);
      if (mounted) setState(() => _board = board);
    } catch (e) {
      if (mounted) setState(() => _boardError = userMessage(e));
    } finally {
      if (mounted) setState(() => _loadingBoard = false);
    }
  }

  /// Loads the Monatsrangliste quietly: a failure without a list in hand
  /// leaves the all-time list alone; a list in hand stays.
  Future<void> _loadMonthly() async {
    if (!monthlyBoardAvailable(controller)) return;
    try {
      final board = await loadMonthlyLeaderboard(controller);
      if (mounted) {
        setState(() {
          _monthly = board;
          _monthlyFailed = false;
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Monatsrangliste fehlt: $e');
      if (mounted && _monthly == null) setState(() => _monthlyFailed = true);
    }
  }

  Future<void> _loadCollection() async {
    setState(() {
      _loadingCollection = true;
      _collectionError = null;
    });
    try {
      final board = await loadCollectionBoard(controller);
      if (!mounted) return;
      setState(() {
        if (board == null) {
          _collectionMissing = true;
        } else {
          _collection = board;
        }
      });
    } catch (e) {
      // A list that loaded once stays; the card shows the error only
      // without one.
      if (mounted) setState(() => _collectionError = userMessage(e));
    } finally {
      if (mounted) setState(() => _loadingCollection = false);
    }
  }

  /// This week's Wochenprobe for the menu, quietly: without it the entry
  /// still leads there.
  Future<void> _loadWeekly() async {
    try {
      final week = await loadWeekly(controller);
      if (mounted) setState(() => _weekly = week);
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Wochenprobe fehlt: $e');
    }
  }

  Future<void> _openWeekly() async {
    final play = await openRunnerWeekly(
      context,
      controller,
      initial: _weekly,
      preferences: _menu,
      // Keep lastWeek intact until the weekly screen itself marks it seen
      // (explicit close or opening the weekly crate).
      onLoaded: (week) {
        if (mounted) setState(() => _weekly = week);
      },
    );
    if (!mounted) return;
    if (play != null) {
      _play(play);
    } else if (_phase != _Phase.playing) {
      // A reward dismissed or claimed there updates the menu entry.
      unawaited(_loadWeekly());
    }
  }

  /// Starts a run: a normal one on a fresh course, or one of the
  /// Wochenprobe ([weekly]) on this week's course. A ranked attempt was
  /// started on the server already and plays even before the motion
  /// setting is known, as it counts.
  void _play([WeeklyPlay? weekly]) {
    if (!_motion.ready && weekly?.ranked != true) return;
    final run = ++_run;
    final game = _game = weekly == null
        ? StageRunner(random: widget.random)
        : StageRunner(seed: weekly.seed);
    _weeklyPlay = weekly;
    _weeklyResult = null;
    _recorder = weekly?.ranked ?? false
        ? (GhostRecorder()..record(game))
        : null;
    // The figure the ghost is run in, if the game is dressed in it; else the
    // server takes the selected one.
    _runFigure = _recorder != null && _outfit != null
        ? _wardrobe?.worn(WardrobeKind.character)?.id
        : null;
    final ghosts = _ghosts = weekly == null
        ? null
        : RunnerGhosts(
            weekly.challenge.ghosts,
            mode: _menu.ghostMode,
            ownRank: weekly.challenge.own?.rank,
          );
    _ghostSkins?.dispose();
    _ghostSkins = null;
    if (ghosts != null && ghosts.ghosts.isNotEmpty) {
      // The named ones first: they show from the start. With the ghosts
      // off nothing loads until they are turned on.
      _ghostSkins = GhostSkins(controller, onLoaded: _frame.tick)
        ..want(ghosts.wanted, _art);
    }
    final perf = _perf = RunnerPerf(
      game,
      curtainStart: _curtainStart,
      sound: () => _sound.enabled.value,
    );
    final fx = _fx = RunnerFx(
      // Training counts for no list: no record to break.
      best: _runBest(weekly),
      onSound: (sfx) {
        perf.played();
        _sound.play(sfx);
      },
    );
    // Its own dice, so courses stay reproducible.
    _trail = RunnerTrail();
    _progress = null;
    _watch = _missionsOn ? MissionWatch(_missions) : null;
    _missionBanner.value = null;
    _resetMissionCache();
    _updateLiveMission(game);
    game.onPickup = (kind, x, y) {
      perf.pickup();
      fx.pickup(kind, x - game.distance, y);
    };
    // Called from the tap on "Vorhang auf", so browsers allow the sound.
    _sound
      ..prepare()
      ..startMusic();
    perf.start();
    widget.onRun?.call(_game);
    _lastHudScore = 0;
    _lastHudMeters = 0;
    _hud.value = (0, 0);
    _activePointers.clear();
    _resumeIgnoredKeys.clear();
    _heldOver.clear();
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _prewarmTimer?.cancel();
    _prewarmTimer = null;
    _resumeCountdown = 0;
    _saveError = null;
    _unrankedOffline = false;
    _improved = false;
    _saving = false;
    _queued = false;
    _stageSize = null;
    _paused = false;
    // The server times the run; a failed start only means it is not ranked.
    // A ranked weekly run was started before (and counted).
    final Future<String>? starting = weekly?.start != null
        ? Future.value(weekly!.start!.roundId)
        : !_ranked
        ? null
        : weekly != null
        ? startWeeklyRound(
            controller,
            week: weekly.challenge.week,
            ranked: false,
          ).then((s) => s.roundId)
        : startRound(controller);
    _start = starting?.then<String?>(
      (id) => id,
      onError: (Object e) {
        if (mounted && run == _run) {
          setState(() {
            _saveError = userMessage(e);
            _unrankedOffline = true;
          });
        }
        return null;
      },
    );
    setState(() => _phase = _Phase.playing);
    _lastFrame = Duration.zero;
    _ticker
      ..stop()
      ..start();
  }

  static final _holdKeys = {
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.keyW,
  };

  void _resetMissionCache() {
    _lastMissionMeters = -1;
    _lastMissionScore = -1;
    _lastMissionCollected = -1;
    _lastMissionGround = -1;
    _lastMissionCeiling = -1;
    _lastMissionPassed = -1;
    _lastLiveMission = null;
    _lastLiveValue = -1;
    final list = _missions?.missions;
    if (!_missionsOn || list == null || list.isEmpty) {
      _missionUnits = const {};
      return;
    }
    final names = _pickupNames;
    _missionUnits = {
      for (final m in list)
        if (!m.done && (m.type == 'collect' || m.type == 'pass'))
          m: m.unitFor(names),
    };
  }

  /// Updates [_liveMission] only when at least one mission counter changed,
  /// avoiding per-frame string/RegExp allocations during a run.
  void _updateLiveMission(StageRunner game) {
    final list = _missions?.missions;
    if (!_missionsOn || list == null || list.isEmpty) {
      if (_liveMission.value != null) _liveMission.value = null;
      return;
    }
    final meters = game.meters;
    final score = game.score;
    final collected = game.collected;
    final ground = game.groundMeters;
    final ceiling = game.ceilingMeters;
    var passed = 0;
    final passedBy = game.passedBy;
    for (var i = 0; i < passedBy.length; i++) {
      passed += passedBy[i];
    }
    if (meters == _lastMissionMeters &&
        score == _lastMissionScore &&
        collected == _lastMissionCollected &&
        ground == _lastMissionGround &&
        ceiling == _lastMissionCeiling &&
        passed == _lastMissionPassed) {
      return;
    }
    _lastMissionMeters = meters;
    _lastMissionScore = score;
    _lastMissionCollected = collected;
    _lastMissionGround = ground;
    _lastMissionCeiling = ceiling;
    _lastMissionPassed = passed;

    DailyMission? best;
    double bestRatio = -1;
    int? bestLive;
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.done || m.reachedBy(game)) continue;
      final live = m.live(game);
      if (live == null) continue;
      // Active noPickup mission gets top priority while no pickup was taken.
      if (m.type == 'noPickup' && collected == 0) {
        best = m;
        bestLive = live;
        break;
      }
      if (m.type == 'noPickup' && collected > 0) continue;
      final ratio = m.target > 0 ? live / m.target : 0.0;
      if (best == null || ratio > bestRatio) {
        best = m;
        bestRatio = ratio;
        bestLive = live;
      }
    }
    if (best == null || bestLive == null) {
      _lastLiveMission = null;
      _lastLiveValue = -1;
      if (_liveMission.value != null) _liveMission.value = null;
      return;
    }
    final displayValue = best.type == 'runs' && best.min > 0
        ? meters
        : bestLive;
    if (identical(best, _lastLiveMission) && displayValue == _lastLiveValue) {
      return;
    }
    _lastLiveMission = best;
    _lastLiveValue = displayValue;
    final text = switch (best.type) {
      'noPickup' => 'Ohne Requisite: $bestLive/${best.target} m',
      'ground' => 'Boden: $bestLive/${best.target} m',
      'ceiling' => 'Oben: $bestLive/${best.target} m',
      'collect' || 'pass' =>
        '${_missionUnits[best] ?? best.unitFor(_pickupNames)}: $bestLive/${best.target}'
            .trim(),
      'points' || 'debut' => 'Mission: $bestLive/${best.target} Pkt.',
      'runs' =>
        best.min > 0
            ? 'Mission: $meters/${best.min} m'
            : 'Mission: $bestLive/${best.target}',
      _ => 'Mission: $bestLive/${best.target} m',
    };
    if (text != _liveMission.value) _liveMission.value = text;
  }

  /// Checks touch pointers and hold keys without allocating a pressed-key Set.
  bool _isHolding() {
    final kb = HardwareKeyboard.instance;
    if (_resumeIgnoredKeys.isNotEmpty) {
      if (_resumeIgnoredKeys.contains(LogicalKeyboardKey.space) &&
          !kb.isLogicalKeyPressed(LogicalKeyboardKey.space)) {
        _resumeIgnoredKeys.remove(LogicalKeyboardKey.space);
      }
      if (_resumeIgnoredKeys.contains(LogicalKeyboardKey.arrowUp) &&
          !kb.isLogicalKeyPressed(LogicalKeyboardKey.arrowUp)) {
        _resumeIgnoredKeys.remove(LogicalKeyboardKey.arrowUp);
      }
      if (_resumeIgnoredKeys.contains(LogicalKeyboardKey.keyW) &&
          !kb.isLogicalKeyPressed(LogicalKeyboardKey.keyW)) {
        _resumeIgnoredKeys.remove(LogicalKeyboardKey.keyW);
      }
    }
    if (_activePointers.isNotEmpty) return true;
    return (kb.isLogicalKeyPressed(LogicalKeyboardKey.space) &&
            !_resumeIgnoredKeys.contains(LogicalKeyboardKey.space)) ||
        (kb.isLogicalKeyPressed(LogicalKeyboardKey.arrowUp) &&
            !_resumeIgnoredKeys.contains(LogicalKeyboardKey.arrowUp)) ||
        (kb.isLogicalKeyPressed(LogicalKeyboardKey.keyW) &&
            !_resumeIgnoredKeys.contains(LogicalKeyboardKey.keyW));
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastFrame).inMicroseconds / 1e6;
    _lastFrame = elapsed;
    _perf?.step(dt);
    _game
      ..holding = _isHolding()
      ..update(dt);
    _recorder?.record(_game);
    _fx.update(dt, _game);
    _trail.update(dt, _game, _systemReducedMotion ? null : _art?.effect);
    _perf?.observe();
    if (_watch?.check(_game) case final made?) {
      _missionBanner.value = made;
      _bannerUntil = _game.time + 2.5;
    } else if (_missionBanner.value != null && _game.time > _bannerUntil) {
      _missionBanner.value = null;
    }
    _updateLiveMission(_game);
    _frame.tick();
    final score = _game.score, meters = _game.meters;
    if (score != _lastHudScore || meters != _lastHudMeters) {
      _lastHudScore = score;
      _lastHudMeters = meters;
      _hud.value = (score, meters);
    }
    // Let the curtain close before showing the result.
    if (_game.over && _game.sinceOver >= _curtainEnd) {
      _ticker.stop();
      _sound.stopMusic();
      _perf?.finish(_wardrobe);
      _perf = null;
      _finish(_run);
    }
  }

  /// The run as it ended, with its own server round; null when the server
  /// does not time it (no shared list, the demo).
  RunScore? _runScore() {
    final start = _start;
    if (start == null) return null;
    return RunScore(
      round: start,
      score: _game.score,
      meters: _game.meters,
      hitBy: _game.hitBy,
      missionStats: _game.missionStats,
      ghost: _recorder?.encode(crashed: _game.over),
      character: _runFigure,
    );
  }

  /// The best score of this visit's ranked runs (normal or weekly) that went
  /// to the server. The list ([_board]) knows a run only once its result is
  /// back, which a quick "Nochmal" does not wait for (and a result in the
  /// outbox may take long): the next run would break the old record once more.
  int _localBest = 0;

  /// Likewise the best ranked run of a week of the Wochenprobe.
  ({String week, int score})? _localWeeklyBest;

  /// The own best a normal run has to beat, as far as known.
  int? get _knownBest {
    final board = _board;
    return board == null ? null : max(board.own?.score ?? 0, _localBest);
  }

  /// The own best of [week] a ranked run has to beat; 0 for none yet.
  int _knownWeeklyBest(WeeklyChallenge week) {
    final local = _localWeeklyBest;
    return max(
      week.best?.score ?? 0,
      local != null && local.week == week.week ? local.score : 0,
    );
  }

  /// The score threshold whose crossing celebrates a new record during a run:
  /// all-time best for normal runs, null for weekly training, and the lower
  /// positive best of weekly and all-time for a ranked weekly run.
  int? _runBest(WeeklyPlay? weekly) {
    if (weekly == null) return _knownBest;
    if (!weekly.ranked) return null;
    final weekBest = _knownWeeklyBest(weekly.challenge);
    final allBest = _knownBest ?? 0;
    if (weekBest > 0 && allBest > 0) return min(weekBest, allBest);
    return weekBest > 0 ? weekBest : allBest;
  }

  /// Hold keys that were still down when the run ended. Their repeats must
  /// not press the focused button of the result ("Nochmal"): whoever still
  /// holds the space bar would skip the result and fly on at once.
  final _heldOver = <LogicalKeyboardKey>{};

  KeyEventResult _menuKey(FocusNode node, KeyEvent event) {
    if (_heldOver.isNotEmpty) {
      if (event is KeyRepeatEvent) {
        return _heldOver.contains(event.logicalKey)
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
      // Let go, or pressed afresh (its release went elsewhere): from now on
      // the key acts as usual.
      _heldOver.remove(event.logicalKey);
      if (event is KeyUpEvent) return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent ||
        _overlayActive ||
        _settingsOpen ||
        ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyR) {
      return _triggerMenuPrimaryRun();
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final primary = FocusManager.instance.primaryFocus;
      // Only handle Enter here when focus is not on another specific button
      // or control (otherwise let that control handle Enter itself).
      if (primary == null ||
          primary == node ||
          primary == FocusScope.of(context)) {
        return _triggerMenuPrimaryRun();
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _triggerMenuPrimaryRun() {
    if (_phase == _Phase.intro) {
      if (!_motion.ready) return KeyEventResult.ignored;
      _play();
      return KeyEventResult.handled;
    }
    if (_phase == _Phase.finished) {
      final weekly = _weeklyPlay;
      if (weekly == null) {
        if (!_motion.ready) return KeyEventResult.ignored;
        _play();
        return KeyEventResult.handled;
      }
      if (!weekly.ranked) {
        _trainAgain();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _finish(int run) async {
    _heldOver
      ..clear()
      ..addAll(
        HardwareKeyboard.instance.logicalKeysPressed.where(_holdKeys.contains),
      );
    setState(() {
      _phase = _Phase.finished;
      _line = curtainLine(
        _game.hitBy,
        _lines,
        obstacleCrashLines:
            _art?.crashLines(tall: _game.hitTall, gap: _game.hitGap) ??
            const {},
      );
    });
    // Fixed now, before anything is awaited: a quick "Nochmal" replaces
    // `_game` and `_start`, and this run must still be sent as it ended,
    // with its own round. The outbox sends it even when the next run plays.
    final score = _runScore();
    if (score == null) return;
    final outbox = runnerScoreOutbox(controller);
    final weekly = _weeklyPlay;
    if (weekly == null) {
      _localBest = max(_localBest, score.score);
    } else if (weekly.ranked) {
      final week = weekly.challenge.week;
      _localBest = max(_localBest, score.score);
      _localWeeklyBest = (
        week: week,
        score: max(_knownWeeklyBest(weekly.challenge), score.score),
      );
    }
    setState(() => _saving = true);
    try {
      final result = await outbox.send(score);
      if (result == null || !mounted) return;
      if (run != _run) {
        // Counted while the next run plays: its list is the newest so far.
        if (_phase == _Phase.playing) _board = result.leaderboard;
        if ((weekly == null || weekly.ranked) &&
            monthlyBoardAvailable(controller)) {
          unawaited(_loadMonthly());
        }
        return;
      }
      // Ranked weekly runs count for both the weekly and normal rankings;
      // training counts for neither.
      final weeklyImproved =
          weekly != null && weekly.ranked && (result.weekly?.improved ?? false);
      final personalImproved =
          (weekly == null || weekly.ranked) && result.improved;
      final anyImproved = weeklyImproved || personalImproved;
      // The fanfare, unless it already played when the record fell.
      if (anyImproved && !_fx.recordBroken) {
        _sound.play(RunnerSfx.record);
      } else if ((result.progress?.newCrates ?? 0) > 0) {
        _sound.play(RunnerSfx.reveal);
      }
      if (result.progress?.missions?.justCompletedAll ?? false) {
        _sound.play(RunnerSfx.jackpot);
      }
      setState(() {
        _improved = personalImproved;
        _weeklyResult = result.weekly;
        _progress = result.progress;
        if (result.progress?.missions case final m?) _missions = m;
        _board = result.leaderboard;
        _boardError = null;
      });
      // The run may have moved the own place in this month's list, in this
      // week's, or both, and may have earned crates/progress for the wardrobe.
      if (weekly != null) unawaited(_loadWeekly());
      if ((weekly == null || weekly.ranked) &&
          monthlyBoardAvailable(controller)) {
        unawaited(_loadMonthly());
      }
      if (_dressable) unawaited(_refreshWardrobe());
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Ergebnis nicht gesendet: $e');
      if (mounted && run == _run) {
        setState(() {
          _saveError = userMessage(e);
          _queued = outbox.waits(score);
        });
      }
    } finally {
      if (mounted && run == _run) setState(() => _saving = false);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.keyP) {
      if (_game.over || _settingsOpen) return KeyEventResult.ignored;
      if (event is KeyDownEvent) {
        if (_paused) {
          _startResumeCountdown();
        } else {
          _pauseRun();
        }
      }
      return KeyEventResult.handled;
    }
    if (!_holdKeys.contains(key)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      if (_paused) {
        _resumeIgnoredKeys.add(key);
        _startResumeCountdown();
      } else if (_resumeCountdown > 0) {
        _resumeIgnoredKeys.add(key);
      } else {
        _resumeIgnoredKeys.remove(key);
      }
    } else if (event is KeyUpEvent) {
      _resumeIgnoredKeys.remove(key);
    }
    return KeyEventResult.handled;
  }

  /// Pauses an active run and asks before abandoning it (mobile back swipe,
  /// AppBar back button, or desktop NavigationRail switch).
  Future<bool> _confirmLeaveRun(BuildContext context) async {
    if (_phase != _Phase.playing || _game.over) return true;
    _pauseRun();
    final ranked = _weeklyPlay?.ranked == true;
    return confirmDestructive(
      context,
      title: ranked ? 'Wertungslauf abbrechen?' : 'Lauf abbrechen?',
      message: ranked
          ? 'Dieser Versuch der Wochenprobe wurde beim Start gezählt und geht beim Abbruch verloren.'
          : 'Dein aktueller Lauf wird abgebrochen und nicht gewertet.',
      confirmLabel: 'Abbrechen',
      cancelLabel: 'Weiterspielen',
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = runnerCoversRail(MediaQuery.sizeOf(context));
    final playing = _phase == _Phase.playing;
    final scaffold = Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ExcludeFocus(
          excluding: playing,
          child: AppBar(
            title: const Text('Bühnenlauf'),
            actions: [
              if (playing && !_game.over)
                IconButton(
                  key: const ValueKey('runner-pause-button'),
                  tooltip: _paused ? 'Fortsetzen' : 'Pause',
                  icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                  onPressed: () {
                    if (_paused) {
                      _startResumeCountdown();
                    } else {
                      _pauseRun();
                    }
                    _playFocus.requestFocus();
                  },
                ),
              IconButton(
                key: const ValueKey('runner-settings'),
                tooltip: 'Spieleinstellungen',
                icon: const Icon(Icons.settings_outlined),
                onPressed: _showSettings,
              ),
              ValueListenableBuilder(
                valueListenable: _sound.enabled,
                builder: (context, on, _) => IconButton(
                  key: const ValueKey('runner-sound'),
                  tooltip: on ? 'Ton aus' : 'Ton an',
                  isSelected: on,
                  icon: const Icon(Icons.volume_off_outlined),
                  selectedIcon: const Icon(Icons.volume_up_outlined),
                  onPressed: () {
                    _sound.setEnabled(!on);
                    if (playing) _playFocus.requestFocus();
                  },
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
      body: AnnotatedRegion(
        value: playing ? runnerBarsPlaying : runnerBarsDefault,
        child: playing ? _stage(context) : _menuBody(context),
      ),
    );
    final guarded = DiscardGuard(
      dirty: playing && !_game.over,
      confirm: _confirmLeaveRun,
      child: playing
          ? Focus(
              key: const ValueKey('runner-play-keys'),
              focusNode: _playFocus,
              autofocus: true,
              onKeyEvent: _key,
              child: scaffold,
            )
          // Its own key: not the stage's focus node kept for the menu.
          : Focus(
              key: const ValueKey('runner-menu-keys'),
              skipTraversal: true,
              onKeyEvent: _menuKey,
              child: scaffold,
            ),
    );
    // On phones the game covers the section rail the route frame would
    // show beside it once the phone is turned (see [runnerCoversRail]).
    final controller = AppNavigationScope.controllerOf(context);
    final selection = AppNavigationScope.maybeOf(context);
    if (controller == null || selection == null) return guarded;
    return DesktopRouteFrame(
      controller: controller,
      selectedIndex: selection.value,
      enabled: !phone,
      child: guarded,
    );
  }

  /// The menu before and after a run: the countdown to a content drop less
  /// than a day away, the hero (or the last run's result), then the own
  /// standing, the Ensemble-Strecke, the Tagesmissionen and the rankings.
  /// Wide enough, the hero stays on the left and the rest scrolls beside it.
  Widget _menuBody(BuildContext context) {
    final lead = _phase == _Phase.intro ? _hero(context) : _result(context);
    // The drop countdown comes first: above the hero on phones, on top of
    // the column beside it on wide screens.
    final drop = _nextDropCard();
    final outboxBanner = _phase == _Phase.intro ? _outboxBanner(context) : null;
    final rest = [
      ?outboxBanner,
      if (_weeklyShown) _weeklyCard(),
      ?_stand(context),
      ?_ensembleStrip(),
      if (_missionsOn && (_phase == _Phase.intro || _missions != null))
        _missionsCard(),
      _ranking(context),
      if (_phase == _Phase.intro) _rules(context),
    ];
    List<Widget> spaced(List<Widget> items) => [
      for (final (i, w) in items.indexed) ...[
        if (i > 0) const SizedBox(height: 16),
        w,
      ],
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (kIsWeb && _phase == _Phase.intro) {
          _schedulePrewarm(
            constraints.biggest,
            MediaQuery.devicePixelRatioOf(context),
          );
        }
        if (constraints.maxWidth < _twoColumns) {
          return ListView(
            padding: pagePadding(context, maxWidth: 640, top: 16),
            children: spaced([?drop, lead, ...rest]),
          );
        }
        final pad = pagePadding(context, maxWidth: 1040, top: 16);
        final leadWidth = constraints.maxWidth >= 960 ? 380.0 : 320.0;
        return Padding(
          padding: EdgeInsets.only(left: pad.left, right: pad.right),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: leadWidth,
                child: SingleChildScrollView(
                  key: const ValueKey('runner-lead'),
                  padding: EdgeInsets.only(top: pad.top, bottom: 16),
                  child: lead,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
                  children: spaced([?drop, ...rest]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Banner for scores waiting in the offline outbox, with manual retry.
  Widget? _outboxBanner(BuildContext context) {
    final waiting = _outbox.waiting;
    if (!_ranked || waiting == 0) return null;
    final theme = Theme.of(context);
    final busy = _outbox.retrying;
    return Card(
      key: const ValueKey('runner-outbox-banner'),
      color: StageTheme.orange.withValues(alpha: StageTheme.tintAlpha),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            const Icon(Icons.cloud_upload_outlined, color: StageTheme.orange),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                waiting == 1
                    ? '1 Lauf wartet auf Verbindung.'
                    : '$waiting Läufe warten auf Verbindung.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const ValueKey('runner-outbox-retry'),
              onPressed: busy ? null : () => _retryOutbox(),
              child: Text(busy ? 'Sende …' : 'Jetzt senden'),
            ),
          ],
        ),
      ),
    );
  }

  /// The worn figure and the big start.
  Widget _hero(BuildContext context) {
    final name = _wardrobe?.wornCharacterName() ?? 'Engel Logge';
    final crates = _wardrobe?.progress.waiting ?? 0;
    return RunnerHero(
      figure: _art == null
          ? const Icon(Icons.theater_comedy, size: 56, color: StageTheme.orange)
          : CustomPaint(painter: _SpritePainter(_art!, RunnerSprite.cheer)),
      // Names whoever is worn in the worn role ("Elena als Lucy"), as the
      // picture beside it shows them.
      name: name,
      story:
          '$name hängt zum ersten Mal am Flugseil – und die Technik hat die Bühne nicht aufgeräumt.',
      onStart: _motion.ready ? _play : null,
      startFocusNode: _startFocus,
      autofocusStart:
          _phase == _Phase.intro &&
          _newsChecked &&
          !_overlayActive &&
          !_settingsOpen &&
          _motion.ready,
      note: _bonusOpen ? _dailyBonusHint(context, onDark: true) : null,
      wardrobe: _dressable
          ? WardrobeButton(
              crates: crates,
              onPressed: () => _openWardrobe(initialTab: crates > 0 ? 1 : 0),
            )
          : null,
    );
  }

  /// "Dein Stand", once there is something to tell.
  Widget? _stand(BuildContext context) {
    final w = _wardrobe;
    final own = _board?.own;
    final best =
        own?.score ?? ((w?.stats.best ?? 0) > 0 ? w!.stats.best : null);
    final crates = w == null
        ? null
        : (_progress?.waiting ?? w.progress.waiting);
    if (!RunnerStandCard.has(
      best: best,
      crates: crates,
      collectible: w?.collectible,
    )) {
      return null;
    }
    // After a run its result shows the way to the next crate already.
    final p = _phase == _Phase.intro ? w?.progress : null;
    final next = p != null && p.nextAt > 0 ? nextCrateText(p) : null;
    return RunnerStandCard(
      best: best,
      rank: own?.rank,
      players: _board?.players ?? 0,
      gage: w != null && dupesAvailable(controller) ? w.gage : null,
      crates: crates,
      collected: w?.collected,
      collectible: w?.collectible,
      collectionRank: _collectionShown ? _collection?.own?.rank : null,
      monthRank: _monthShown ? _monthly?.own?.rank : null,
      monthShown: _monthShown,
      nextCrate: next,
      nextCrateFraction: next == null || p!.complete ? null : p.fraction,
      onWardrobe: _dressable ? () => _openWardrobe(initialTab: 0) : null,
      onCrates: _dressable ? () => _openWardrobe(initialTab: 1) : null,
    );
  }

  /// The countdown to the next content drop, while one is less than a day
  /// away (`nextDrop`).
  Widget? _nextDropCard() {
    final drop = _wardrobe?.nextDrop;
    if (drop == null || !_dressable) return null;
    return NextDropCard(
      drop: drop,
      onDue: _reloadWardrobe,
      onTap: drop.ready ? () => _openWardrobe(initialTab: 0) : null,
    );
  }

  /// The way into the Wochenprobe.
  Widget _weeklyCard() {
    final w = _weekly;
    return RunnerWeeklyCard(
      onOpen: _openWeekly,
      week: w?.week,
      startsAt: w?.startsAt,
      endsAt: w?.endsAt,
      used: w?.used ?? 0,
      max: w?.max ?? 3,
      rank: w?.own?.rank,
      reward: w?.lastWeek != null,
      now: controller.now,
    );
  }

  /// The Ensemble-Strecke in short; the full card is in the wardrobe.
  Widget? _ensembleStrip() {
    final e = _wardrobe?.ensemble;
    if (e == null || !ensembleAvailable(controller)) return null;
    return EnsembleStrip(
      ensemble: e,
      run: _progress?.ensemble,
      onOpen: _openWardrobe,
    );
  }

  /// How the game is played and what counts, folded away under the menu.
  Widget _rules(BuildContext context) {
    final theme = Theme.of(context);
    Widget legend(PickupKind? kind, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CustomPaint(painter: _LegendPainter(kind, _art)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(value, style: theme.textTheme.titleMedium),
        ],
      ),
    );
    return Card(
      key: const ValueKey('runner-rules'),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          // Its own key: without one the tile would keep its state under
          // the list's id, which holds the scroll offset.
          key: const PageStorageKey('runner-rules-tile'),
          leading: const Icon(Icons.help_outline, color: StageTheme.orange),
          title: Text('So wird gespielt', style: theme.textTheme.titleMedium),
          subtitle: Text(
            'Halten zum Steigen, Loslassen zum Sinken',
            style: theme.textTheme.bodySmall,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Vorbei an Kisten, Kulissen, Scheinwerfern und fallenden Requisiten, immer schneller, bis der Vorhang fällt.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            legend(null, 'Jeder Meter', '+1'),
            for (final kind in PickupKind.values)
              legend(
                kind,
                // A backdrop's own collectible keeps the plain name the
                // missions use: "Bonbon (Rose)".
                switch (_art?.pickupNames[kind]) {
                  final name? => '$name (${_pickupLabel(kind)})',
                  null => _pickupLabel(kind),
                },
                '+${kind.points}',
              ),
            const SizedBox(height: 12),
            Text(
              'Halten zieht dich nach oben, Loslassen lässt dich sinken: Finger oder Maustaste auf der Bühne, am Rechner auch Leertaste oder Pfeil nach oben. Ein Zusammenstoß beendet den Lauf.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// The day's missions; loads them on first sight.
  Widget _missionsCard() {
    final crates =
        _progress?.missionCrates ?? _wardrobe?.progress.missionCrates ?? 0;
    return DailyMissionsCard(
      controller: controller,
      missions: _missions,
      collectibleNames: _pickupNames,
      crates: crates,
      onOpenCrate: _dressable && crates > 0
          ? () => _openWardrobe(initialTab: 1)
          : null,
      onChanged: (m) {
        if (!mounted) return;
        setState(() => _missions = m);
        if (m.justCompletedAll &&
            m.dailyReward?.isItem == true &&
            _dressable) {
          unawaited(_refreshWardrobe());
        }
      },
    );
  }

  /// A quiet note while today's first run still counts twice for the crates.
  Widget _dailyBonusHint(BuildContext context, {bool onDark = false}) {
    final theme = Theme.of(context);
    final color = onDark ? const Color(0xFFFFD58A) : theme.hintColor;
    return Row(
      key: const ValueKey('runner-daily-bonus'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.wb_sunny_outlined, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            dailyBonusHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: onDark ? color : null,
            ),
          ),
        ),
      ],
    );
  }

  /// The way to the next costume crate after a run.
  Widget _crateProgress(BuildContext context, RunnerProgress p) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('runner-progress'),
      children: [
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: p.complete ? 1 : p.fraction,
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          runProgressText(p, showBonus: dailyBonusAvailable(controller)),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        if (p.newCrates > 0) ...[
          const SizedBox(height: 8),
          Text(
            p.newCrates == 1
                ? 'Neue Kostümkiste! Ab in die Garderobe.'
                : '${p.newCrates} neue Kostümkisten! Ab in die Garderobe.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: StageTheme.orange,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        if (p.ensemble case final e? when ensembleAvailable(controller))
          EnsembleRunNote(e),
      ],
    );
  }

  /// Another training run on this week's course, with the newest ghosts;
  /// once the week is over the Wochenprobe shows the next one.
  void _trainAgain() {
    final last = _weeklyPlay;
    if (last == null) return;
    final week = _weekly?.week == last.challenge.week
        ? _weekly!
        : last.challenge;
    if (!week.currentAt(controller.now)) {
      unawaited(_openWeekly());
      return;
    }
    _play(WeeklyPlay(challenge: week));
  }

  /// What a weekly run's result adds: which run it was, and for a ranked
  /// one the week's best and place.
  List<Widget> _weeklyLines(BuildContext context, WeeklyPlay play) {
    final theme = Theme.of(context);
    final r = _weeklyResult;
    final max = r?.max ?? play.challenge.max;
    final used = r?.used ?? play.attempt;
    final best = r?.best;
    return [
      if (play.ranked && best != null) ...[
        const SizedBox(height: 8),
        Text(
          r?.rank == null
              ? 'Dein Wochenbestwert: ${best.score} Punkte'
              : 'Dein Wochenbestwert: ${best.score} Punkte · Platz ${r!.rank}',
          key: const ValueKey('runner-weekly-result'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleSmall,
        ),
      ],
      if (play.ranked && r?.ranked != false && used > 0 && !_saving) ...[
        const SizedBox(height: 4),
        Text(
          used >= max
              ? 'Alle Versuche dieser Woche genutzt'
              : max - used == 1
              ? 'Noch 1 Versuch diese Woche'
              : 'Noch ${max - used} Versuche diese Woche',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
      if (play.ranked && r?.ranked == false) ...[
        const SizedBox(height: 8),
        const Text(
          'Die Woche ist bereits abgeschlossen. Dieser Lauf zählt als Training; dein Fortschritt bleibt erhalten.',
          textAlign: TextAlign.center,
        ),
      ],
      if (!play.ranked) ...[
        const SizedBox(height: 8),
        Text(
          'Training zählt nicht für die Wochenwertung.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    ];
  }

  Widget _result(BuildContext context) {
    final theme = Theme.of(context);
    final weekly = _weeklyPlay;
    final narrow = MediaQuery.sizeOf(context).width < _twoColumns;
    final waitingCrates = _progress?.waiting ?? _wardrobe?.progress.waiting ?? 0;
    final earnedCrate =
        (_progress?.newCrates ?? 0) > 0 ||
        ((_progress?.missions?.justCompletedAll ?? false) &&
            (_progress?.missions?.dailyReward?.isItem != true));
    final outboxWaiting = _ranked ? _outbox.waiting : 0;
    final weeklyImproved =
        weekly != null && weekly.ranked && (_weeklyResult?.improved ?? false);
    final anyImproved = _improved || weeklyImproved;
    final status = !_ranked
        ? null
        : weekly != null
        ? _saving
              ? weekly.ranked
                    ? 'Der Wertungslauf wird eingetragen …'
                    : null
              : _queued
              ? 'Gerade keine Verbindung: Der Lauf wird nachgetragen, sobald der Server erreichbar ist.'
              : _saveError != null
              ? '${weekly.ranked ? 'Nicht gewertet' : 'Nicht eingetragen'}: $_saveError'
              : weeklyImproved && _improved
              ? 'Neuer Wochen- und persönlicher Bestwert!'
              : weeklyImproved
              ? 'Neuer Wochenbestwert!'
              : _improved
              ? 'Neuer persönlicher Bestwert!'
              : null
        : _saving
        ? 'Punkte werden eingetragen …'
        : _queued
        ? 'Gerade keine Verbindung: Die Punkte werden nachgetragen, sobald der Server erreichbar ist.'
        : _saveError != null
        ? 'Nicht in der Bestenliste: $_saveError'
        : _improved
        ? 'Neuer persönlicher Bestwert!'
        : null;
    final actions = Wrap(
      key: const ValueKey('runner-result-actions'),
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        if (weekly == null)
          FilledButton.icon(
            autofocus: true,
            onPressed: _play,
            icon: const Icon(Icons.replay),
            label: const Text('Nochmal'),
          )
        else ...[
          if (!weekly.ranked)
            FilledButton.icon(
              key: const ValueKey('runner-train-again'),
              autofocus: true,
              onPressed: _trainAgain,
              icon: const Icon(Icons.replay),
              label: const Text('Nochmal trainieren'),
            ),
          (weekly.ranked ? FilledButton.icon : OutlinedButton.icon)(
            key: const ValueKey('runner-to-weekly'),
            autofocus: weekly.ranked,
            onPressed: _openWeekly,
            icon: const Icon(Icons.event_repeat),
            label: const Text('Zur Wochenprobe'),
          ),
          if (weekly.ranked)
            OutlinedButton.icon(
              key: const ValueKey('runner-weekly-train'),
              onPressed: _trainAgain,
              icon: const Icon(Icons.fitness_center),
              label: const Text('Training'),
            ),
          OutlinedButton(
            key: const ValueKey('runner-free-run'),
            onPressed: _motion.ready ? _play : null,
            child: const Text('Freier Lauf'),
          ),
        ],
        if (_dressable && earnedCrate)
          FilledButton.tonalIcon(
            key: const ValueKey('runner-result-open-crate'),
            onPressed: () => _openWardrobe(initialTab: 1),
            icon: const Icon(Icons.inventory_2_outlined),
            label: Text(
              waitingCrates > 1
                  ? 'Kisten öffnen ($waitingCrates)'
                  : 'Kiste öffnen',
            ),
          ),
        if (_dressable)
          WardrobeButton(
            crates: waitingCrates,
            onPressed: () =>
                _openWardrobe(initialTab: waitingCrates > 0 ? 1 : 0),
          ),
        OutlinedButton(
          onPressed: () => Navigator.maybePop(context),
          child: const Text('Zurück in die App'),
        ),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (_art case final art?)
              SizedBox(
                width: 120,
                height: 74,
                child: CustomPaint(
                  painter: _SpritePainter(art, RunnerSprite.crash),
                ),
              )
            else
              const Icon(
                Icons.theater_comedy,
                size: 48,
                color: StageTheme.orange,
              ),
            const SizedBox(height: 12),
            if (weekly != null) ...[
              Text(
                weekly.ranked
                    ? 'Wertungslauf · Versuch ${weekly.attempt} von ${weekly.challenge.max}'
                    : 'Training · Wochenprobe',
                key: const ValueKey('runner-weekly-mode'),
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 2),
            ],
            Text(
              'Der Vorhang fällt!',
              style: theme.textTheme.labelLarge?.copyWith(
                color: StageTheme.orange,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _line,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              _game.score == 1 ? '1 Punkt' : '${_game.score} Punkte',
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${_game.meters} m · ${_game.collected} ${_game.collected == 1 ? 'Requisite' : 'Requisiten'} gesammelt',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            if (weekly != null) ..._weeklyLines(context, weekly),
            if (status != null) ...[
              const SizedBox(height: 12),
              Text(
                status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _saveError != null
                      ? theme.colorScheme.error
                      : anyImproved
                      ? StageTheme.green
                      : null,
                  fontWeight: anyImproved ? FontWeight.w700 : null,
                ),
              ),
            ],
            if (outboxWaiting > 0 && !_saving) ...[
              const SizedBox(height: 8),
              if (!_queued || outboxWaiting > 1)
                Text(
                  outboxWaiting == 1
                      ? '1 Lauf wartet auf Verbindung.'
                      : '$outboxWaiting Läufe warten auf Verbindung.',
                  key: const ValueKey('runner-outbox-count'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                key: const ValueKey('runner-outbox-retry'),
                onPressed: _outbox.retrying ? null : () => _retryOutbox(),
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text(_outbox.retrying ? 'Sende …' : 'Jetzt senden'),
              ),
            ],
            if (narrow) ...[const SizedBox(height: 16), actions],
            if (_progress case final p?) _crateProgress(context, p),
            if (_progress?.missions case final m? when _missionsOn)
              MissionRunNote(m, names: _pickupNames),
            // A run of 0 m leaves the bonus open for the next one.
            if (_bonusOpen && !_saving) ...[
              const SizedBox(height: 12),
              _dailyBonusHint(context),
            ],
            if (!narrow) ...[const SizedBox(height: 20), actions],
          ],
        ),
      ),
    );
  }

  /// The rankings: this month, all time, and who has the most complete
  /// collection.
  Widget _ranking(BuildContext context) => RunnerRankingCard(
    view: _menu.board,
    onView: _menu.setBoard,
    monthShown: _ranked && _monthShown,
    monthly: _monthly,
    board: _board,
    boardNote: _ranked
        ? null
        : controller.isDemo
        ? 'In der Demo gibt es keine Bestenliste.'
        : 'Die Bestenliste ist auf diesem Server noch nicht verfügbar.',
    boardLoading: _loadingBoard,
    boardError: _boardError,
    onRetryBoard: _loadBoard,
    me: controller.user?.personId,
    collectionShown: _collectionShown,
    collection: _collection,
    collectionLoading: _loadingCollection,
    collectionError: _collectionError,
    onRetryCollection: _loadCollection,
    maskOf: (trophy) => GalaMask(
      trophy: trophy,
      path: _wardrobe?.gala.masks[trophy],
      controller: controller,
      size: 20,
    ),
  );

  /// Incrementally pre-bakes Web GPU decoration textures across idle frames
  /// while the user views the intro menu so "Vorhang auf" starts with zero
  /// synchronous `toImageSync` spikes.
  void _schedulePrewarm(Size size, double ratio) {
    if (!kIsWeb || _phase != _Phase.intro || size.isEmpty || ratio <= 0) return;
    if (_prewarmSize == size && _prewarmRatio == ratio) return;
    _prewarmTimer?.cancel();
    _prewarmSize = size;
    _prewarmRatio = ratio;
    _prewarmStep = 0;
    _scheduleNextPrewarmStep(size, ratio);
  }

  void _scheduleNextPrewarmStep(Size size, double ratio) {
    _prewarmTimer = Timer(const Duration(milliseconds: 24), () {
      _prewarmTimer = null;
      if (!mounted ||
          _phase != _Phase.intro ||
          _prewarmSize != size ||
          _prewarmRatio != ratio) {
        return;
      }
      final painter = _stagePainter(ratio);
      final more = painter.prewarmStep(size, _prewarmStep++);
      if (more) _scheduleNextPrewarmStep(size, ratio);
    });
  }

  /// The stage's painter, kept across rebuilds (its laid-out texts and
  /// shader stay); a new one only for another pixel ratio.
  StageRunnerPainter? _painter;
  StageRunnerPainter _stagePainter(double ratio) {
    final kept = _painter;
    if (kept != null && kept.pixelRatio == ratio) return kept;
    kept?.dispose();
    return _painter = StageRunnerPainter._(
      () => _game,
      () => _fx,
      () => _art,
      _frame,
      () => _trail,
      pixelRatio: ratio,
      sceneryMotion: () => _sceneryMotion,
      reducedMotion: () => _systemReducedMotion,
      ghosts: () => _ghosts,
      ghostSkins: () => _ghostSkins,
    );
  }

  /// The weekly line under the numbers: which run this is and how far the
  /// best of the week is ahead (or behind).
  String _weeklyHud(WeeklyPlay play, int score) {
    final mode = play.ranked
        ? 'Wertungslauf · Versuch ${play.attempt}/${play.challenge.max}'
        : 'Training';
    final top = play.challenge.leaderboard.firstOrNull;
    if (top == null) return mode;
    final gap = top.score - score;
    if (top.me) {
      return gap > 0
          ? '$mode · Bestwert: noch $gap'
          : gap == 0
          ? '$mode · gleichauf mit deinem Bestwert'
          : '$mode · ${-gap} über deinem Bestwert';
    }
    return gap > 0
        ? '$mode · ${top.name}: noch $gap'
        : gap == 0
        ? '$mode · gleichauf mit ${top.name}'
        : '$mode · ${-gap} vor ${top.name}';
  }

  /// The stage fills the whole area below the app bar, in every
  /// orientation, and all of it takes the touch, so a thumb anywhere flies.
  /// The numbers and the hint lie on the picture, inside the safe area.
  Widget _stage(BuildContext context) {
    final theme = Theme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // A sharp shadow: a blurred one costs Impeller an offscreen pass with a
    // blur each time the numbers change, several times a second.
    const shadow = [Shadow(color: Color(0xCC000000), offset: Offset(0, 1.5))];
    final number = theme.textTheme.titleLarge?.copyWith(
      color: const Color(0xFFFFF1D6),
      shadows: shadow,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final weekly = _weeklyPlay;
    final missionRowTop = scaler.scale(weekly != null ? 58 : 38);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (_paused || _resumeCountdown > 0) return;
        _activePointers.add(event.pointer);
        if (kIsWeb) {
          if (_sound case final RunnerMusic music) {
            music.resumeMusic();
          }
        }
      },
      onPointerUp: (event) => _activePointers.remove(event.pointer),
      onPointerCancel: (event) => _activePointers.remove(event.pointer),
      // Only the picture is built by its size. The numbers live outside the
      // LayoutBuilder: a rebuild inside it (each new number) would lay out
      // the builder again, and with it the page, which then repaints whole.
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                _resized(size, stageLayout(size, ratio).view);
                return RepaintBoundary(
                  child: Semantics(
                    label: 'Bühnenlauf-Spielfläche',
                    hint: 'Gedrückt halten zum Steigen',
                    child: CustomPaint(
                      key: const ValueKey('runner-stage'),
                      size: Size.infinite,
                      painter: _stagePainter(ratio),
                    ),
                  ),
                );
              },
            ),
          ),
          // Layers of their own with a fixed size: new numbers lay out and
          // repaint only them, not the page with its app bar (and the rail
          // on wide screens).
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _HudLayout(pad, ratio, scaler.scale(36)),
              child: RepaintBoundary(
                key: const ValueKey('runner-hud'),
                child: ValueListenableBuilder(
                  valueListenable: _hud,
                  builder: (context, hud, _) => Row(
                    children: [
                      Expanded(
                        child: Text(
                          hud.$1 == 1 ? '1 Punkt' : '${hud.$1} Punkte',
                          maxLines: 1,
                          softWrap: false,
                          style: number,
                        ),
                      ),
                      Text(
                        '${hud.$2} m',
                        maxLines: 1,
                        softWrap: false,
                        style: number,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // The Wochenprobe's line right below the numbers, a layer of its
          // own like them.
          if (weekly != null)
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _HudLayout(
                  pad,
                  ratio,
                  scaler.scale(20),
                  below: scaler.scale(36),
                ),
                child: RepaintBoundary(
                  key: const ValueKey('runner-weekly-hud'),
                  child: ValueListenableBuilder(
                    valueListenable: _hud,
                    builder: (context, hud, _) => Text(
                      _weeklyHud(weekly, hud.$1),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: const Color(0xE6FFF1D6),
                        shadows: shadow,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Mission completion banner or compact live mission pill below the
          // numbers (and below the weekly line when active), never colliding
          // with score/metres.
          if (_missionsOn)
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _HudLayout(
                  pad,
                  ratio,
                  scaler.scale(30),
                  below: missionRowTop,
                ),
                child: RepaintBoundary(
                  child: ValueListenableBuilder(
                    valueListenable: _missionBanner,
                    builder: (context, made, _) => AnimatedSwitcher(
                      duration: _systemReducedMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 250),
                      child: made != null
                          ? Align(
                              key: ValueKey('banner-${made.slot}'),
                              alignment: AlignmentDirectional.centerStart,
                              child: MissionBanner(made, names: _pickupNames),
                            )
                          : ValueListenableBuilder(
                              key: const ValueKey('live-slot'),
                              valueListenable: _liveMission,
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.flag_outlined,
                                    size: 14,
                                    color: StageTheme.orange,
                                  ),
                                  SizedBox(width: 5),
                                ],
                              ),
                              builder: (context, live, icon) => live == null
                                  ? const SizedBox.shrink()
                                  : Align(
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: DecoratedBox(
                                        key: const ValueKey(
                                          'runner-mission-live',
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xB3151A17),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 3,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              icon!,
                                              Flexible(
                                                child: Text(
                                                  live,
                                                  maxLines: 1,
                                                  softWrap: false,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme
                                                      .labelMedium
                                                      ?.copyWith(
                                                        color: const Color(
                                                          0xFFFFF1D6,
                                                        ),
                                                        shadows: shadow,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          if (_unrankedOffline && weekly?.ranked != true)
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _HudLayout(
                  pad,
                  ratio,
                  scaler.scale(24),
                  below: missionRowTop + (_missionsOn ? scaler.scale(32) : 0),
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: DecoratedBox(
                    key: const ValueKey('runner-offline-warning'),
                    decoration: BoxDecoration(
                      color: const Color(0xCC5E1714),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: Text(
                        'Offline · zählt nicht für die Bestenliste',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: const Color(0xFFFFF1D6),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: pad.left + 20,
            right: pad.right + 20,
            bottom: pad.bottom + 10,
            child: RepaintBoundary(
              child: Text(
                'Halten zum Steigen',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xCCFFF1D6),
                  shadows: shadow,
                ),
              ),
            ),
          ),
          // Over everything. Laid out after the picture, so a pause that its
          // new size caused (see [_resized]) shows in the very same frame.
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (_paused) {
                  return _pauseOverlay(
                    context,
                    theme,
                    number,
                    shadow,
                    constraints,
                  );
                }
                if (_resumeCountdown > 0) {
                  return _countdownOverlay(context, theme, shadow);
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _pauseOverlay(
    BuildContext context,
    ThemeData theme,
    TextStyle? number,
    List<Shadow> shadow,
    BoxConstraints constraints,
  ) {
    final openMissions = _missionsOn
        ? [
            for (final m in _missions?.missions ?? const <DailyMission>[])
              if (!m.done) m,
          ]
        : const <DailyMission>[];
    final canRestart = _weeklyPlay?.ranked != true;
    final hasWeeklyGhosts = _weeklyPlay != null;
    final hasSecondary = hasWeeklyGhosts || openMissions.isNotEmpty;
    final wide = hasSecondary && constraints.maxWidth >= 560;
    final primary = <Widget>[
      Text('Pause', textAlign: TextAlign.center, style: number),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('runner-resume'),
        style: FilledButton.styleFrom(
          backgroundColor: StageTheme.orange,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
        ),
        onPressed: _startResumeCountdown,
        icon: const Icon(Icons.play_arrow),
        label: Semantics(
          label: 'Lauf fortsetzen',
          excludeSemantics: true,
          child: const Text('Weiter'),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        'Tippen, Leertaste oder Esc zum Weiterlaufen · Esc/P für Pause',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: const Color(0xCCFFF1D6),
          shadows: shadow,
        ),
      ),
      if (canRestart) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('runner-pause-restart'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFFF1D6),
            side: const BorderSide(color: Color(0x66FFF1D6)),
          ),
          onPressed: _restartFromPause,
          icon: const Icon(Icons.replay, size: 18),
          label: const Text('Neu starten'),
        ),
      ],
    ];
    final secondary = <Widget>[
      if (hasWeeklyGhosts) ...[
        Text(
          'Geister',
          style: theme.textTheme.labelMedium?.copyWith(
            color: const Color(0xCCFFF1D6),
          ),
        ),
        const SizedBox(height: 6),
        Theme(
          data: StageTheme.build(Brightness.dark),
          child: SegmentedButton<GhostMode>(
            key: const ValueKey('runner-pause-ghosts'),
            showSelectedIcon: false,
            segments: [
              for (final m in GhostMode.values)
                ButtonSegment(
                  value: m,
                  label: Text(m.label, key: ValueKey('pause-ghosts-${m.name}')),
                ),
            ],
            selected: {_menu.ghostMode},
            onSelectionChanged: (chosen) => _menu.setGhostMode(chosen.first),
          ),
        ),
      ],
      if (hasWeeklyGhosts && openMissions.isNotEmpty)
        const SizedBox(height: 14),
      if (openMissions.isNotEmpty)
        Column(
          key: const ValueKey('runner-pause-missions'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Offene Tagesmissionen',
              style: theme.textTheme.labelMedium?.copyWith(
                color: const Color(0xCCFFF1D6),
              ),
            ),
            const SizedBox(height: 6),
            for (final m in openMissions) _pauseMissionRow(theme, m),
          ],
        ),
    ];
    return GestureDetector(
      key: const ValueKey('runner-paused'),
      behavior: HitTestBehavior.opaque,
      onTap: _startResumeCountdown,
      child: ColoredBox(
        color: const Color(0x66000000),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 640 : 360),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xD9151A17),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _gold.withValues(alpha: .45),
                    width: 1.2,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: primary,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: secondary,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...primary,
                            if (hasSecondary) ...[
                              const SizedBox(height: 14),
                              ...secondary,
                            ],
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pauseMissionRow(ThemeData theme, DailyMission m) {
    final made = m.reachedBy(_game);
    final live = m.live(_game);
    final unit = m.unitFor(_pickupNames);
    final progress = made
        ? 'Geschafft!'
        : m.type == 'noPickup' && _game.collected > 0
        ? 'Requisite gesammelt'
        : live != null
        ? '$live/${m.target}${unit.isEmpty ? '' : ' $unit'}'
        : '${m.progress}/${m.target}${unit.isEmpty ? '' : ' $unit'}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            made ? Icons.check_circle : Icons.flag_outlined,
            size: 16,
            color: made ? StageTheme.green : StageTheme.orange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              m.textFor(_pickupNames),
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFFFFF1D6),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            progress,
            style: theme.textTheme.labelSmall?.copyWith(
              color: made ? StageTheme.green : const Color(0xFFFFD58A),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _countdownOverlay(
    BuildContext context,
    ThemeData theme,
    List<Shadow> shadow,
  ) {
    final step = _resumeCountdown;
    return ColoredBox(
      key: const ValueKey('runner-countdown'),
      color: const Color(0x26000000),
      child: Center(
        child: Semantics(
          liveRegion: true,
          label: 'Weiter in $step',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$step',
                style: theme.textTheme.displayLarge?.copyWith(
                  color: const Color(0xFFFFE7A3),
                  fontWeight: FontWeight.w900,
                  shadows: shadow,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Gleich geht’s weiter …',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFFFF1D6),
                  shadows: shadow,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _restartFromPause() {
    final weekly = _weeklyPlay;
    if (weekly != null && weekly.ranked) return;
    if (weekly != null) {
      _trainAgain();
    } else {
      _play();
    }
  }

  /// The stage got its size: the course is laid out to the picture's right
  /// edge at once. When the size changes during a run (a turned phone, a
  /// resized window), the run pauses until resumed. The game counts in
  /// stage heights, so the new size only scales the picture; nothing jumps.
  void _resized(Size size, double view) {
    _game.view = view;
    final last = _stageSize;
    _stageSize = size;
    if (last == null ||
        last == size ||
        _phase != _Phase.playing ||
        _game.over ||
        _paused) {
      return;
    }
    // Called while building: the pause shows in this very build.
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _prewarmTimer?.cancel();
    _prewarmTimer = null;
    _resumeCountdown = 0;
    _paused = true;
    _activePointers.clear();
    _ticker.stop();
    if (_sound case final RunnerMusic music) music.pauseMusic();
  }

  /// Pauses a run in play (or cancels an active resume countdown), with its
  /// music; returns whether it transitioned into pause.
  bool _pauseRun() {
    if (_phase != _Phase.playing || _game.over || _paused) return false;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    setState(() {
      _paused = true;
      _resumeCountdown = 0;
    });
    _activePointers.clear();
    _ticker.stop();
    if (_sound case final RunnerMusic music) music.pauseMusic();
    return true;
  }

  /// Starts the 3-2-1 countdown from pause without triggering lift on resume.
  void _startResumeCountdown() {
    if (!_paused || _settingsOpen || _phase != _Phase.playing || _game.over) {
      return;
    }
    _countdownTimer?.cancel();
    _activePointers.clear();
    _resumeIgnoredKeys.addAll(
      HardwareKeyboard.instance.logicalKeysPressed.where(_holdKeys.contains),
    );
    final step = StageRunnerScreen.resumeCountdownStep;
    if (step <= Duration.zero) {
      setState(() {
        _paused = false;
        _resumeCountdown = 0;
      });
      _finishResume();
      return;
    }
    setState(() {
      _paused = false;
      _resumeCountdown = 3;
    });
    _countdownTimer = Timer.periodic(step, (timer) {
      if (!mounted || _phase != _Phase.playing || _game.over || _paused) {
        timer.cancel();
        if (identical(_countdownTimer, timer)) _countdownTimer = null;
        return;
      }
      if (_resumeCountdown > 1) {
        setState(() => _resumeCountdown--);
      } else {
        timer.cancel();
        if (identical(_countdownTimer, timer)) _countdownTimer = null;
        _finishResume();
      }
    });
  }

  /// Runs on after the resume countdown, from the first fresh frame.
  void _finishResume() {
    if (!mounted || _phase != _Phase.playing || _game.over) return;
    if (_resumeCountdown != 0) setState(() => _resumeCountdown = 0);
    _activePointers.clear();
    _lastFrame = Duration.zero;
    _ticker.start();
    if (_sound case final RunnerMusic music) music.resumeMusic();
    _playFocus.requestFocus();
  }
}

/// Puts the numbers right above the playing field when the house has room
/// for them (tall pictures), else over its top edge, inside the safe area;
/// always [height] high, so they are their own relayout boundary.
class _HudLayout extends SingleChildLayoutDelegate {
  _HudLayout(this.pad, this.pixelRatio, this.height, {this.below = 0});
  final EdgeInsets pad;
  final double pixelRatio, height;

  /// How far below the numbers a further line goes.
  final double below;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tight(
        Size(max(0, constraints.maxWidth - pad.horizontal - 40), height),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    pad.left + 20,
    max(pad.top + 4, stageLayout(size, pixelRatio).top - 52) + below,
  );

  @override
  bool shouldRelayout(_HudLayout old) =>
      old.pad != pad ||
      old.pixelRatio != pixelRatio ||
      old.height != height ||
      old.below != below;
}

String _pickupLabel(PickupKind kind) => switch (kind) {
  PickupKind.rose => 'Rose',
  PickupKind.mask => 'Maske',
  PickupKind.star => 'Stern des Abends',
};

/// Seconds from the crash until the result shows: a comic fall, then the
/// curtain closes.
const _curtainEnd = 1.0, _curtainStart = .2;

const _stageDark = Color(0xFF151A17), _wall = Color(0xFF1D2420);
const _velvet = Color(0xFF8E2420), _velvetDark = Color(0xFF5E1714);
const _gold = Color(0xFFD9A441);
const _floorColor = Color(0xFF3B2A1E), _plank = Color(0xFF2C1F16);
const _floorEdge = Color(0xFF6B4A30);
const _wood = Color(0xFFB07A45), _woodDark = Color(0xFF7D532C);
const _canvas = Color(0xFFD9CBB0), _canvasEdge = Color(0xFF8E7D62);
const _metal = Color(0xFF59605C), _beam = Color(0xFFFFF1C9);
const _sack = Color(0xFF8A6A48), _rope = Color(0xFFBDB29C);
const _roseColor = Color(0xFFE5486B), _starColor = Color(0xFFFFC94A);
const _crowd = Color(0xFF07090A), _house = Color(0xFF231412);

Paint _fill(Color color) => Paint()..color = color;
Paint _stroke(Color color, double width) => Paint()
  ..color = color
  ..strokeWidth = width
  ..style = PaintingStyle.stroke;

/// Each sprite comes from the atlas of its layer in the worn costume (see
/// [RunnerArt.imageOf]), with that layer's paint.
void _sprite(Canvas canvas, RunnerArt art, RunnerSprite sprite, Rect dst) =>
    canvas.drawImageRect(
      art.imageOf(sprite),
      sprite.rect,
      dst,
      art.paintOf(sprite),
    );

/// [sprite] centred in [size], as large as it fits.
Rect _fit(RunnerSprite sprite, Size size) {
  final scale = min(size.width / sprite.width, size.height / sprite.height);
  return Rect.fromCenter(
    center: size.center(Offset.zero),
    width: sprite.width * scale,
    height: sprite.height * scale,
  );
}

IconData _pickupIcon(PickupKind kind) => switch (kind) {
  PickupKind.rose => Icons.local_florist,
  PickupKind.mask => Icons.theater_comedy,
  PickupKind.star => Icons.star_rounded,
};

Color _pickupColor(PickupKind kind) => switch (kind) {
  PickupKind.rose => _roseColor,
  PickupKind.mask => StageTheme.onInkAccent,
  PickupKind.star => _starColor,
};

/// Laid-out text by content and size, reused across frames until the stage
/// size changes. Popups, banners and the sandbag label share one frame, so
/// different sizes must not push each other out.
@visibleForTesting
class RunnerGlyphs {
  /// On the web the labels name the bundled font. For a style without a
  /// family, CanvasKit takes every character from U+00A0 on (the "–" and
  /// "×" of the banners) as missing and searches the Noto fallback fonts;
  /// the first time it downloads one, and then lays out all text again.
  static const _font = kIsWeb ? 'Roboto' : null;

  double _stage = 0;
  final Map<Object, TextPainter> _cache = {};

  /// Called once per paint with the stage size; a new size drops the cache.
  void stage(double s) {
    if (s == _stage) return;
    _clear();
    _stage = s;
  }

  TextPainter icon(PickupKind kind, double size) {
    _bound();
    return _cache[(kind, size)] ??= _layout(
      String.fromCharCode(_pickupIcon(kind).codePoint),
      TextStyle(
        fontFamily: _pickupIcon(kind).fontFamily,
        package: _pickupIcon(kind).fontPackage,
        fontSize: size,
        color: _pickupColor(kind),
      ),
    );
  }

  TextPainter kg(double size) {
    _bound();
    return _cache[('kg', size)] ??= _layout(
      'kg',
      TextStyle(
        fontFamily: _font,
        color: const Color(0xFFF3E6CF),
        fontSize: size * .45,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  /// A popup or banner line; [shadow] is the dark copy drawn behind it.
  TextPainter label(String text, double size, {bool shadow = false}) {
    _bound();
    return _cache[(text, size, shadow)] ??= _layout(
      text,
      TextStyle(
        fontFamily: _font,
        color: shadow ? const Color(0xE6000000) : const Color(0xFFFFE7A3),
        fontSize: size,
        fontWeight: FontWeight.w900,
        letterSpacing: -.3,
      ),
    );
  }

  /// The name beside a ghost: one of the best three in its medal's colour.
  TextPainter tag(String text, double size, int rank) {
    _bound();
    return _cache[('tag', text, size)] ??= _layout(
      text,
      TextStyle(
        fontFamily: _font,
        color: _ghostTagColors[rank >= 1 && rank <= 3 ? rank - 1 : 3],
        fontSize: size,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  /// Short label above a highlighted ghost crash marker (top 3 or own run).
  TextPainter crashTag(String text, double size, int rank, bool me) {
    _bound();
    final color = rank >= 1 && rank <= 3
        ? _ghostTagColors[rank - 1]
        : me
        ? const Color(0xF0FF8A5C)
        : _ghostTagColors[3];
    return _cache[('crashTag', text, size, rank, me)] ??= _layout(
      text,
      TextStyle(
        fontFamily: _font,
        color: color,
        fontSize: size,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  static const _ghostTagColors = [
    Color(0xE6F2C45A),
    Color(0xE6D5DCE2),
    Color(0xE6D9A06A),
    Color(0xE6E6EDF2),
  ];

  /// A safety net: sizes that keep changing must not grow the cache forever.
  void _bound() {
    if (_cache.length > 64) _clear();
  }

  void _clear() {
    for (final p in _cache.values) {
      p.dispose();
    }
    _cache.clear();
  }

  static TextPainter _layout(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
}

void _paintCentered(Canvas canvas, TextPainter p, Offset center) =>
    p.paint(canvas, center - Offset(p.width / 2, p.height / 2));

class _SpritePainter extends CustomPainter {
  _SpritePainter(this.art, this.sprite);
  final RunnerArt art;
  final RunnerSprite sprite;
  @override
  void paint(Canvas canvas, Size size) =>
      _sprite(canvas, art, sprite, _fit(sprite, size));

  @override
  bool shouldRepaint(_SpritePainter old) =>
      old.art != art || old.sprite != sprite;
}

class _LegendPainter extends CustomPainter {
  _LegendPainter(this.kind, this.art);
  final PickupKind? kind;
  final RunnerArt? art;
  final _glyphs = RunnerGlyphs();
  @override
  void paint(Canvas canvas, Size size) {
    _glyphs.stage(size.width);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(size.width * .3),
      ),
      _fill(_stageDark),
    );
    final c = size.center(Offset.zero);
    final kind = this.kind, art = this.art;
    if (kind != null && art != null) {
      final sprite = RunnerSprite.of(kind);
      _sprite(canvas, art, sprite, _fit(sprite, size * .8).shift(c * .2));
    } else if (kind != null) {
      _paintCentered(canvas, _glyphs.icon(kind, size.width * .7), c);
    } else {
      // Two floor planks for "metres".
      final y = size.height * .62;
      canvas.drawLine(
        Offset(size.width * .2, y),
        Offset(size.width * .8, y),
        _stroke(_wood, 3),
      );
      canvas.drawLine(
        Offset(size.width * .35, y - 7),
        Offset(size.width * .65, y - 7),
        _stroke(_wood, 3),
      );
    }
  }

  @override
  bool shouldRepaint(_LegendPainter old) => old.kind != kind || old.art != art;
}

/// The painter for a fixed game state, also used for wardrobe previews.
StageRunnerPainter stagePainterFor(
  StageRunner game,
  RunnerArt? art, {
  RunnerFx? fx,
  RunnerTrail? trail,
  double pixelRatio = 1,
  bool sceneryMotion = true,
  bool reducedMotion = false,
  RunnerGhosts? ghosts,
  GhostSkins? ghostSkins,
  @visibleForTesting bool rasterizeDecorations = kIsWeb,
}) {
  final f = fx ?? RunnerFx(), t = trail ?? RunnerTrail();
  return StageRunnerPainter._(
    () => game,
    () => f,
    () => art,
    _never,
    () => t,
    pixelRatio: pixelRatio,
    sceneryMotion: () => sceneryMotion,
    reducedMotion: () => reducedMotion,
    ghosts: ghosts == null ? null : () => ghosts,
    ghostSkins: ghostSkins == null ? null : () => ghostSkins,
    rasterizeDecorations: rasterizeDecorations,
  );
}

/// Where the stage sits in a picture of [size]: one stage height [s] in
/// pixels, the top of the playing field and the visible width in stage
/// heights. Wide pictures scale the stage to their height and fill the
/// width with the passing set; tall ones keep [StageRunner.viewWidth] in
/// view and fill the rest with the house: the drapes above, the stalls
/// below. [top] lies on whole device pixels.
@visibleForTesting
({double s, double top, double view}) stageLayout(
  Size size, [
  double pixelRatio = 1,
]) {
  final s = min(size.height, size.width / StageRunner.viewWidth);
  if (!(s > 0)) return (s: 0, top: 0, view: StageRunner.viewWidth);
  final top = ((size.height - s) * .4 * pixelRatio).floor() / pixelRatio;
  return (s: s, top: top, view: size.width / s);
}

final _never = ValueNotifier(0);

/// Paints the run. Paints, paths and text are created once; per frame it
/// issues a few dozen rectangles, circles and sprite copies from one atlas.
/// Without the pictures (offline on the web) it draws simple shapes.
class StageRunnerPainter extends CustomPainter {
  StageRunnerPainter._(
    this.game,
    this.fx,
    this.art,
    Listenable repaint,
    this.trail, {
    this.pixelRatio = 1,
    required this.sceneryMotion,
    required this.reducedMotion,
    this.ghosts,
    this.ghostSkins,
    bool rasterizeDecorations = kIsWeb,
  }) : _decoration = _DecorationCache(rasterize: rasterizeDecorations),
       super(repaint: repaint);
  final StageRunner Function() game;

  /// The ghosts of a Wochenprobe run and their figures; null otherwise.
  final RunnerGhosts? Function()? ghosts;
  final GhostSkins? Function()? ghostSkins;
  final RunnerFx Function() fx;
  final RunnerArt? Function() art;

  /// Only decorative movement; the course and the player's hitboxes keep
  /// moving at the same speed in either setting.
  final bool Function() sceneryMotion;

  /// System "Bewegung reduzieren": additionally quiets pickup bobbing,
  /// trail/shine flashes, particle bursts and crash bounce/rotation.
  final bool Function() reducedMotion;

  /// The trail of the worn effect.
  final RunnerTrail Function() trail;

  /// Device pixels per logical pixel; the stage moves in whole device
  /// pixels.
  final double pixelRatio;

  static final _bg = _fill(_stageDark), _wallPaint = _fill(_wall);
  static final _velvetPaint = _fill(_velvet);
  static final _foldPaint = _fill(_velvetDark);
  // The border in the colour of the worn backdrop, set when it changes.
  static final _borderPaint = _fill(_velvet),
      _borderFoldPaint = _fill(_velvetDark);
  static final _goldPaint = _fill(_gold);
  static final _floorPaint = _fill(_floorColor);
  static final _plankPaint = _stroke(_plank, 2);
  static final _edgePaint = _stroke(_floorEdge, 2);
  static final _woodPaint = _fill(_wood), _woodLine = _stroke(_woodDark, 2);
  static final _canvasPaint = _fill(_canvas);
  static final _canvasLine = _stroke(_canvasEdge, 2);
  static final _metalPaint = _fill(_metal), _sackPaint = _fill(_sack);
  static final _beamPaint = _fill(_beam.withValues(alpha: .07));
  static final _conePaint = _fill(_beam.withValues(alpha: .045));
  static final _poolPaint = _fill(_beam.withValues(alpha: .07));
  static final _lensPaint = _fill(_beam);
  static final _ropePaint = _stroke(_rope, 1.5);
  static final _flyLinePaint = _stroke(_rope, 5);
  static final _flyLineEdge = _stroke(const Color(0xFF4A3F33), 8);
  static final _crowdPaint = _fill(_crowd);
  static final _housePaint = _fill(_house), _seatPaint = _fill(_velvetDark);
  static final _seatEdgePaint = _fill(_velvet);
  static final _sheenPaint = _fill(const Color(0x1FFFFFFF));
  final _shadePaint = Paint();
  double? _shadeTop;
  static final _platePaint = _fill(const Color(0xDD151A17));
  static final _plateEdge = _stroke(_gold, 2);
  static final _bodyPaint = _fill(StageTheme.onInkAccent);
  static final _headPaint = _fill(const Color(0xFFF2D3B8));
  static final _limbPaint = _stroke(const Color(0xFFF2F3ED), 3)
    ..strokeCap = StrokeCap.round;
  static final _particlePaints = [
    _fill(_roseColor),
    _fill(_starColor),
    _fill(const Color(0xFFFFF4C2)),
    _fill(const Color(0xFFBFA88A)),
  ];
  static const _particleArgb = [0xFFE5486B, 0xFFFFC94A, 0xFFFFF4C2, 0xFFBFA88A];
  static final _beamArgb = _beam.withValues(alpha: .07).toARGB32();
  static const _sandbagShadowArgb = 0x8007090A;
  static const _sandbagWarnShadowArgb = 0x66E96131;
  static const _sandbagWarnFillArgb = 0xFFE96131;
  static const _drumDustArgb = 0x55D9CBB0;
  static const _goldArgb = 0xFFD9A441;
  static const _velvetArgb = 0xFF8E2420;
  static const _velvetDarkArgb = 0xFF5E1714;
  static const _ropeArgb = 0xFFBDB29C;
  static const _flyLineEdgeArgb = 0xFF4A3F33;
  // Ghosts: all alike and faint ([ghostAlpha]), in their figures or, until
  // those are loaded, as a plain silhouette. Their opacity changes every
  // frame, so its steps are made once: a frame only picks a colour.
  static const _ghostSteps = 24;
  static final _ghostFigure = _plainFigure();
  static final _ghostSilhouettes = [
    for (var i = 0; i <= _ghostSteps; i++)
      Color.fromRGBO(220, 230, 240, ghostOpacity * i / _ghostSteps),
  ];
  static final _ghostOpacities = [
    for (var i = 0; i <= _ghostSteps; i++)
      Color.fromRGBO(0, 0, 0, ghostOpacity * i / _ghostSteps),
  ];
  static final _ghostPaint = Paint();
  static final _ghostSkinPaint = Paint()
    ..filterQuality = kIsWeb ? FilterQuality.low : FilterQuality.medium;
  static final _ghostMark = _stroke(const Color(0x40DCE6F0), 1.5)
    ..strokeCap = StrokeCap.round;
  static final _ghostMedalMarks = [
    _stroke(const Color(0xCCF2C45A), 2.2)..strokeCap = StrokeCap.round,
    _stroke(const Color(0xCCD5DCE2), 2.2)..strokeCap = StrokeCap.round,
    _stroke(const Color(0xCCD9A06A), 2.2)..strokeCap = StrokeCap.round,
  ];
  static final _ghostOwnMark = _stroke(const Color(0xDDE96131), 2.4)
    ..strokeCap = StrokeCap.round;
  static final _sandbagShadowPaint = _fill(const Color(0x8007090A));
  static final _sandbagWarnShadowPaint = _fill(const Color(0x66E96131));
  static final _sandbagWarnRopePaint = _stroke(const Color(0xFFE96131), 2.2)
    ..strokeCap = StrokeCap.round;
  static final _sandbagWarnFill = _fill(const Color(0xFFE96131));
  static final _drumDustPaint = _fill(const Color(0x55D9CBB0));
  static final _ghostTagLayer = Paint();
  static final _tagOpacities = [
    for (var i = 0; i <= _ghostSteps; i++)
      Color.fromRGBO(0, 0, 0, i / _ghostSteps),
  ];
  // The name tags of a frame (at most the three of [RunnerGhosts.named]).
  final _tagGhosts = List<RunnerGhost?>.filled(3, null);
  final _tagTops = Float64List(3);
  final _tagPainters = List<TextPainter?>.filled(3, null);
  final _tagPlacedTops = Float64List(3);
  final _glyphs = RunnerGlyphs();
  final _path = Path();
  final _DecorationCache _decoration;
  final _rim = RunnerRimCache();
  final _spriteBatch = _SpriteBatch();
  final _discBatch = _DiscBatch();
  ui.Image? _backdropImage;
  double _backdropTile = 0, _backdropH = 0;
  FilterQuality? _backdropQuality;
  ui.ImageShader? _backdropShader;
  final _backdropShaderPaint = Paint();

  /// Pre-warms one slice of Web GPU decoration textures and shaders for [size]
  /// so "Vorhang auf" starts without a first-frame `toImageSync` spike.
  /// Returns true while more steps remain.
  bool prewarmStep(Size size, int step) {
    if (!_decoration.rasterize) return false;
    final (:s, :top, view: _) = stageLayout(size, pixelRatio);
    if (s <= 0) return false;
    _decoration.resize(size, pixelRatio);
    final w = size.width, below = size.height - top - s;
    final floorY = s * StageRunner.floor;
    if (step < 4) {
      _decoration.prewarmStep(s, w, top, below, floorY, step);
      return true;
    }
    final a = art();
    if (a != null) _ensureBackdropShader(a, s, floorY);
    return false;
  }

  void dispose() {
    _decoration.dispose();
    _rim.dispose();
    _backdropShader?.dispose();
    _backdropShader = null;
    _backdropShaderPaint.shader = null;
    _backdropImage = null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = game(), f = fx(), a = art();
    final movingScenery = sceneryMotion();
    final reduced = reducedMotion();
    // One stage height in pixels; the playing field is [view] heights wide
    // and starts [top] pixels down (see [stageLayout]).
    final (:s, :top, view: _) = stageLayout(size, pixelRatio);
    if (s <= 0) return;
    _decoration.resize(size, pixelRatio);
    final w = size.width, below = size.height - top - s;
    final floorY = s * StageRunner.floor;
    _glyphs.stage(s);

    final (dx, dy) = movingScenery ? f.shake(g) : (0.0, 0.0);
    final shaking = dx != 0 || dy != 0;

    // The set is drawn beyond the picture on purpose (tiles and wings from
    // off-screen, the crash nudge), and neither CustomPaint nor its
    // RepaintBoundary clip: without this cut the stage would paint over
    // whatever lies next to it, e.g. the section rail on wide screens.
    canvas
      ..save()
      ..clipRect(Offset.zero & size, doAntiAlias: false);
    // Avoid full-screen overdraw when drapes and stalls cover the house area;
    // keep 1 logical px of margin around the stage edges so fractional stage
    // heights (e.g. s = 243.75) never leave a semi-transparent seam.
    if (shaking) {
      canvas.drawRect(Offset.zero & size, _bg);
    } else {
      canvas.drawRect(Rect.fromLTRB(0, top - 1, w, top + s + 1), _bg);
    }
    canvas.save();
    canvas.translate(dx * s, dy * s + top);

    // Moving scenery passes at the running pace, without a separate
    // parallax speed. With it off only obstacles and pickups travel; the
    // backdrop and house stay still. Round the course to device pixels so
    // consecutive frames do not shimmer.
    final course = (g.distance * s * pixelRatio).round() / pixelRatio;
    final sceneryScroll = movingScenery ? course : 0.0;
    // The house around a tall picture's playing field; the field itself
    // ends at its edges, as on a picture of its own shape.
    if (top > 0) _drapes(canvas, s, w, top, sceneryScroll, shaking);
    if (below > 0) _stalls(canvas, s, w, below, sceneryScroll, shaking);
    final exactStageClip = (s * pixelRatio) == (s * pixelRatio).roundToDouble();
    canvas
      ..save()
      ..clipRect(
        Rect.fromLTRB(-s, 0, w + s, s),
        doAntiAlias: !exactStageClip,
      );
    _backdrop(canvas, a, s, w, floorY, sceneryScroll, shaking);
    _spotlights(canvas, s, w, floorY, sceneryScroll);
    _wings(canvas, s, w, sceneryScroll);
    _floor(canvas, s, w, floorY, sceneryScroll, shaking);
    // Behind everything that matters for the run.
    if (ghosts?.call() case final gh?) {
      _ghostRuns(canvas, g, gh, ghostSkins?.call(), a, s, w, course);
    }

    if (_decoration.rasterize && a != null) {
      _paintBatchedStage(canvas, g, f, a, s, w, floorY, course, reduced);
    } else {
      final obstacles = g.obstacles;
      final margin = s * .1;
      for (var i = 0, len = obstacles.length; i < len; i++) {
        final o = obstacles[i];
        final rect = Rect.fromLTRB(
          o.left * s - course,
          o.top * s,
          o.right * s - course,
          o.bottom * s,
        );
        if (rect.right < -margin || rect.left > w + margin) continue;
        if (o.kind == ObstacleKind.sandbag) {
          _sandbagShadow(canvas, g, o, rect, s, floorY);
        }
        if (a == null) {
          _plainObstacle(canvas, o, rect, s, floorY);
        } else {
          _obstacle(canvas, a, o, rect, s, floorY);
        }
      }

      _pickups(canvas, g, a, s, w, course, reduced);
      if (!reduced) trail().paint(canvas, s, a?.effect);
      if (a == null) {
        _plainRunner(canvas, g, s);
      } else {
        _runner(canvas, g, f, a, s, reduced);
      }
    }
    _particles(canvas, f, s, reduced);
    _audience(canvas, s, w, sceneryScroll, shaking);
    _bannerAndValance(canvas, f, s, w, sceneryScroll, movingScenery, shaking);
    _sandbagWarnings(canvas, g, s, w, course, reduced);
    canvas
      ..restore()
      ..restore();

    if (g.over) _curtain(canvas, g, s, w, size.height, movingScenery);
    canvas.restore();
  }

  /// Ensures [_backdropShader] matches [a.backdrop] and [s]/[floorY], returning
  /// the tile width or 0 if invalid.
  double _ensureBackdropShader(RunnerArt a, double s, double floorY) {
    final image = a.backdrop, top = s * .04, h = floorY - top;
    if (h <= 0 || image.width <= 0 || image.height <= 0) return 0;
    final tile = max(
      1 / pixelRatio,
      (h * image.width / image.height * pixelRatio).round() / pixelRatio,
    );
    final quality = a.backdropPaint.filterQuality;
    if (!identical(image, _backdropImage) ||
        tile != _backdropTile ||
        h != _backdropH ||
        quality != _backdropQuality ||
        _backdropShader == null) {
      _backdropShader?.dispose();
      _backdropImage = image;
      _backdropTile = tile;
      _backdropH = h;
      _backdropQuality = quality;
      _backdropShader = _createImageShader(
        image,
        TileMode.mirror,
        TileMode.clamp,
        _DecorationCache.scaleMatrix(tile / image.width, h / image.height),
        filterQuality: quality,
      );
      _backdropShaderPaint.shader = _backdropShader;
    }
    _backdropShaderPaint.colorFilter = a.backdropPaint.colorFilter;
    return tile;
  }

  /// The painted backdrop passes [scroll] pixels to the left, tiled in turn
  /// as painted and mirrored via a cached [ui.ImageShader] with
  /// [TileMode.mirror], so the seams match in a single textured quad without
  /// off-screen tile draws or mirrored canvas transforms.
  void _backdrop(
    Canvas canvas,
    RunnerArt? a,
    double s,
    double w,
    double floorY,
    double scroll,
    bool shaking,
  ) {
    if (a == null) {
      canvas.drawRect(Rect.fromLTRB(0, s * .1, w, floorY), _wallPaint);
      return;
    }
    final tile = _ensureBackdropShader(a, s, floorY);
    if (tile <= 0) return;
    final top = s * .04, h = floorY - top;
    final shift = scroll % (2 * tile);
    final pad = shaking ? s * .02 : 0.0;
    canvas
      ..save()
      ..translate(-shift, top)
      ..drawRect(
        Rect.fromLTRB(shift - pad, 0, shift + w + pad, h),
        _backdropShaderPaint,
      )
      ..restore();
  }

  /// Light cones hung every .72 stage heights, passing with the stage:
  /// flat translucent shapes, no blur.
  void _spotlights(
    Canvas canvas,
    double s,
    double w,
    double floorY,
    double scroll,
  ) => _decoration.paintSpotlights(canvas, s, w, floorY, scroll);

  /// Velvet wings every .51 stage heights, passing with the stage.
  void _wings(Canvas canvas, double s, double w, double scroll) =>
      _decoration.paintWings(canvas, s, w, scroll);

  /// The floor; its planks pass exactly with the course.
  void _floor(
    Canvas canvas,
    double s,
    double w,
    double floorY,
    double scroll,
    bool shaking,
  ) {
    if (_decoration.paintFloor(canvas, s, w, floorY, scroll, shaking)) return;
    canvas.drawRect(Rect.fromLTRB(0, floorY, w, s), _floorPaint);
    _decoration.paintFloorPlanks(canvas, s, w, floorY, scroll);
    canvas.drawLine(Offset(0, floorY), Offset(w, floorY), _edgePaint);
  }

  /// Web-batched obstacle, pickup and runner pass:
  /// 1. Background vectors (shadows, lamp beams, drum dust, velvet borders,
  ///    ropes/fly lines) batched into [_discBatch] so no mid-run Circle/Oval
  ///    shaders compile.
  /// 2. Same-atlas obstacle sprites, pickup sprites and (when no trail/shine
  ///    separates them) the runner sprite batched into `drawRawAtlas`.
  void _paintBatchedStage(
    Canvas canvas,
    StageRunner g,
    RunnerFx f,
    RunnerArt a,
    double s,
    double w,
    double floorY,
    double course,
    bool reduced,
  ) {
    final obstacles = g.obstacles;
    final obsLen = obstacles.length;
    final margin = s * .1;

    // Pass 1: obstacle background vectors (shadows, beams, dust, ropes, borders).
    for (var i = 0; i < obsLen; i++) {
      final o = obstacles[i];
      final left = o.left * s - course;
      final right = o.right * s - course;
      if (right < -margin || left > w + margin) continue;
      final top = o.top * s, bottom = o.bottom * s;
      final width = right - left;
      final centerX = (left + right) * .5;
      switch (o.kind) {
        case ObstacleKind.sandbag:
          final waiting = _sandbagTelegraphing(g, o);
          final falling = o.falling && o.bottom < StageRunner.floor - .01;
          if (waiting || falling) {
            final progress = falling
                ? ((o.bottom - StageRunner.ceiling) /
                          (StageRunner.floor - StageRunner.ceiling))
                      .clamp(0.0, 1.0)
                : 0.35;
            _discBatch.addOval(
              canvas,
              centerX,
              floorY + s * .006,
              width * (.7 + .65 * progress) * .5,
              s * (.014 + .014 * progress) * .5,
              waiting ? _sandbagWarnShadowArgb : _sandbagShadowArgb,
            );
          }
          final bagW = width * 1.25;
          final bagH =
              bagW * RunnerSprite.sandbag.height / RunnerSprite.sandbag.width;
          final bagTop = bottom - bagH;
          _discBatch.addRect(
            canvas,
            centerX - .75,
            0,
            centerX + .75,
            bagTop + bagH * .1,
            _ropeArgb,
          );
        case ObstacleKind.lamp:
          final lampW = width * 1.05;
          final lampH =
              lampW * RunnerSprite.lamp.height / RunnerSprite.lamp.width;
          final bodyTop = bottom - lampH;
          final lensY = bottom - lampH * .06;
          _discBatch
            ..addQuad(
              canvas,
              centerX - lampW * .3,
              lensY,
              centerX + lampW * .3,
              lensY,
              centerX + lampW * .9,
              floorY,
              centerX - lampW * .9,
              floorY,
              _beamArgb,
            )
            ..addRect(canvas, centerX - .75, 0, centerX + .75, bodyTop, _ropeArgb);
        case ObstacleKind.truss:
          final bar = a.ownTruss
              ? RunnerSprite.trussAssembly
              : RunnerSprite.truss;
          final barH = width * bar.height / bar.width;
          var suspensionY = bottom;
          if (!a.ownTruss) {
            final lampW = width * .19;
            final lampH =
                lampW * RunnerSprite.lamp.height / RunnerSprite.lamp.width;
            suspensionY = bottom - lampH - barH * .5;
            final lensY = bottom - lampH * .06;
            for (var k = 0; k < 4; k++) {
              final lx = left + lampW * .5 + k * (width - lampW) / 3;
              _discBatch.addQuad(
                canvas,
                lx - lampW * .3,
                lensY,
                lx + lampW * .3,
                lensY,
                lx + lampW * .9,
                floorY,
                lx - lampW * .9,
                floorY,
                _beamArgb,
              );
            }
          }
          final leftRope = left + s * .012, rightRope = right - s * .012;
          _discBatch
            ..addRect(
              canvas,
              leftRope - .75,
              0,
              leftRope + .75,
              suspensionY,
              _ropeArgb,
            )
            ..addRect(
              canvas,
              rightRope - .75,
              0,
              rightRope + .75,
              suspensionY,
              _ropeArgb,
            );
        case ObstacleKind.drum:
          if (o.falling) {
            final baseY = bottom - s * .012;
            _discBatch
              ..addCircle(
                canvas,
                right + s * .022,
                baseY - s * .004,
                s * .012,
                _drumDustArgb,
              )
              ..addCircle(
                canvas,
                right + s * .048,
                baseY - s * .009,
                s * .009,
                _drumDustArgb,
              )
              ..addCircle(
                canvas,
                right + s * .072,
                baseY - s * .005,
                s * .006,
                _drumDustArgb,
              );
          }
        case ObstacleKind.drop:
          final frameH = width * RunnerSprite.drop.height / RunnerSprite.drop.width;
          final frameTop = bottom - frameH;
          final inset = width * .18;
          final lineBottom = frameTop + frameH * .04;
          final lx = left + inset, rx = right - inset;
          _discBatch
            ..addRect(canvas, lx - 4, 0, lx + 4, lineBottom, _flyLineEdgeArgb)
            ..addRect(canvas, lx - 2.5, 0, lx + 2.5, lineBottom, _ropeArgb)
            ..addRect(canvas, rx - 4, 0, rx + 4, lineBottom, _flyLineEdgeArgb)
            ..addRect(canvas, rx - 2.5, 0, rx + 2.5, lineBottom, _ropeArgb);
        case ObstacleKind.border when !a.ownScenery:
          _velvetPieceBatched(
            canvas,
            Rect.fromLTRB(left, top, right, bottom),
            s,
            a.border,
          );
        default:
      }
    }
    _discBatch.flush(canvas);

    // Pass 2: all obstacle sprites + all pickup sprites batched via drawRawAtlas.
    for (var i = 0; i < obsLen; i++) {
      final o = obstacles[i];
      final left = o.left * s - course;
      final right = o.right * s - course;
      if (right < -margin || left > w + margin) continue;
      final rect = Rect.fromLTRB(left, o.top * s, right, o.bottom * s);
      _obstacleSpritesBatched(canvas, a, o, rect, s);
    }

    final pickups = g.pickups;
    final glyph = s * .075, pickupH = s * .085;
    final pickupImg = a.pickupAtlas;
    final pickupPaint = RunnerArt.pickupPaint;
    for (var i = 0, len = pickups.length; i < len; i++) {
      final p = pickups[i];
      if (p.taken) continue;
      final x = p.x * s - course;
      if (x < -glyph || x > w + glyph) continue;
      final y = reduced
          ? p.y * s
          : p.y * s + sin(g.time * 4 + p.x * 7) * s * .008;
      final sprite = RunnerSprite.of(p.kind);
      final scale = pickupH / max(sprite.width, sprite.height);
      final pw = sprite.width * scale, ph = sprite.height * scale;
      _spriteBatch.addRect(
        canvas,
        pickupImg,
        sprite.rect,
        Rect.fromLTWH(x - pw * .5, y - ph * .5, pw, ph),
        pickupPaint,
      );
    }
    _spriteBatch.flush(canvas);

    if (!reduced) trail().paint(canvas, s, a.effect);
    _runner(canvas, g, f, a, s, reduced, batched: true);
  }

  /// Like [_velvetPiece], but pushes the velvet panels, gold trim and 4 gold
  /// tassels into [_discBatch] so borders compile zero Circle shaders and add
  /// zero extra draw calls.
  void _velvetPieceBatched(
    Canvas canvas,
    Rect rect,
    double s, [
    Color? color,
  ]) {
    final baseArgb = color == null ? _velvetArgb : color.toARGB32();
    final foldArgb = color == null
        ? _velvetDarkArgb
        : Color.lerp(color, const Color(0xFF000000), .34)!.toARGB32();
    final fold = rect.width / 5;
    _discBatch
      ..addRect(canvas, rect.left, rect.top, rect.right, rect.bottom, baseArgb)
      ..addRect(
        canvas,
        rect.left + fold,
        rect.top,
        rect.left + fold * 1.7,
        rect.bottom,
        foldArgb,
      )
      ..addRect(
        canvas,
        rect.left + fold * 3,
        rect.top,
        rect.left + fold * 3.7,
        rect.bottom,
        foldArgb,
      )
      ..addRect(
        canvas,
        rect.left,
        rect.bottom - s * .014,
        rect.right,
        rect.bottom,
        _goldArgb,
      );
    final ty = rect.bottom + s * .006, tr = s * .006;
    for (var i = 0; i < 4; i++) {
      _discBatch.addCircle(
        canvas,
        rect.left + rect.width * (i + .5) / 4,
        ty,
        tr,
        _goldArgb,
      );
    }
  }

  void _addSprite(Canvas canvas, RunnerArt a, RunnerSprite sprite, Rect dst) =>
      _spriteBatch.addRect(
        canvas,
        a.imageOf(sprite),
        sprite.rect,
        dst,
        a.paintOf(sprite),
      );

  void _obstacleSpritesBatched(
    Canvas canvas,
    RunnerArt a,
    Obstacle o,
    Rect rect,
    double s,
  ) {
    switch (o.kind) {
      case ObstacleKind.crate when a.ownScenery && o.tall:
        _addSprite(canvas, a, RunnerSprite.twoCrates, rect);
      case ObstacleKind.crate when a.ownScenery:
        final width = rect.width * 1.12;
        _addSprite(
          canvas,
          a,
          RunnerSprite.crate,
          Rect.fromLTRB(
            rect.center.dx - width / 2,
            rect.top,
            rect.center.dx + width / 2,
            rect.bottom,
          ),
        );
      case ObstacleKind.crate when a.ownTallCrate && o.tall:
        _addSprite(canvas, a, RunnerSprite.tallCrate, rect);
      case ObstacleKind.crate when a.ownTallCrate:
        _spriteBatch.addRect(
          canvas,
          a.atlas,
          RunnerSprite.crate.rect,
          rect,
          a.obstaclePaint,
        );
      case ObstacleKind.crate when a.ownPile && o.tall:
        _addSprite(canvas, a, RunnerSprite.pile, rect);
      case ObstacleKind.crate:
        if (o.tall) {
          final half = rect.height / 2;
          _addSprite(
            canvas,
            a,
            RunnerSprite.crate,
            rect.topLeft & Size(rect.width, half),
          );
          _addSprite(
            canvas,
            a,
            RunnerSprite.crate,
            Rect.fromLTWH(rect.left, rect.top + half, rect.width, half),
          );
        } else {
          _addSprite(canvas, a, RunnerSprite.crate, rect);
        }
      case ObstacleKind.flat when a.ownScenery && o.gap:
        final width = rect.width * _guillotineWidth;
        final left = rect.center.dx - width / 2;
        _addSprite(
          canvas,
          a,
          RunnerSprite.guillotine,
          Rect.fromLTRB(left, rect.top, left + width, rect.bottom),
        );
        final block = RunnerSprite.guillotineBlock;
        final height = width * block.height / block.width;
        final shown = min(1.0, rect.height / height);
        _spriteBatch.addRect(
          canvas,
          a.imageOf(block),
          Rect.fromLTWH(block.x, block.y, block.width, block.height * shown),
          Rect.fromLTWH(left, rect.top, width, height * shown),
          a.paintOf(block),
        );
      case ObstacleKind.flat when a.ownScenery:
        _shelvesBatched(canvas, a, rect);
      case ObstacleKind.flat:
        _flatBatched(canvas, a, rect);
      case ObstacleKind.border when a.ownScenery:
        final gap = (o.anchor - o.bottom) * s;
        final width = rect.width * _guillotineWidth;
        final left = rect.center.dx - width / 2;
        final cell = RunnerSprite.guillotine;
        final blade = RunnerSprite.guillotineBlade;
        final height = width * blade.height / blade.width;
        final back = rect.bottom - height * .75;
        const upright = RunnerSprite.guillotineUpright;
        if (back > rect.top) {
          _addSprite(
            canvas,
            a,
            cell,
            Rect.fromLTRB(left, rect.top, left + width, back),
          );
          if (a.border != null) {
            _spriteBatch.flush(canvas);
            _velvetPieceBatched(
              canvas,
              Rect.fromLTRB(
                left + width * upright,
                rect.top,
                left + width * (1 - upright),
                back,
              ),
              s,
              a.border,
            );
            _discBatch.flush(canvas);
          }
        }
        const sides = [0.0, 1 - upright];
        final cellImg = a.imageOf(cell), cellPaint = a.paintOf(cell);
        final dstTop = max(rect.top, back), dstBottom = rect.bottom + max(0.0, gap);
        for (final side in sides) {
          _spriteBatch.addRect(
            canvas,
            cellImg,
            Rect.fromLTWH(
              cell.x + cell.width * side,
              cell.y,
              cell.width * upright,
              cell.height,
            ),
            Rect.fromLTRB(
              left + width * side,
              dstTop,
              left + width * (side + upright),
              dstBottom,
            ),
            cellPaint,
          );
        }
        _addSprite(
          canvas,
          a,
          blade,
          Rect.fromLTWH(left, rect.bottom - height, width, height),
        );
      case ObstacleKind.border:
        break;
      case ObstacleKind.lamp:
        final width = rect.width * 1.05;
        final height = width * RunnerSprite.lamp.height / RunnerSprite.lamp.width;
        _addSprite(
          canvas,
          a,
          RunnerSprite.lamp,
          Rect.fromLTWH(
            rect.center.dx - width / 2,
            rect.bottom - height,
            width,
            height,
          ),
        );
      case ObstacleKind.sandbag:
        final sprite = RunnerSprite.sandbag;
        final width = rect.width * 1.25;
        final height = width * sprite.height / sprite.width;
        _addSprite(
          canvas,
          a,
          sprite,
          Rect.fromLTWH(
            rect.center.dx - width / 2,
            rect.bottom - height,
            width,
            height,
          ),
        );
      case ObstacleKind.drum:
        final r = rect.width * .56;
        final center = Offset(rect.center.dx, rect.bottom - r);
        _spriteBatch.addRotated(
          canvas,
          a.imageOf(RunnerSprite.drum),
          RunnerSprite.drum.rect,
          center,
          (2 * r) / RunnerSprite.drum.width,
          o.left * s / r,
          a.paintOf(RunnerSprite.drum),
        );
      case ObstacleKind.pile when a.ownPile || a.ownScenery:
        if (o.bottom >= StageRunner.floor) {
          _addSprite(
            canvas,
            a,
            a.ownScenery ? RunnerSprite.threeCrates : RunnerSprite.pile,
            Rect.fromLTRB(
              rect.left,
              rect.top - rect.height,
              rect.right,
              rect.bottom,
            ),
          );
        }
      case ObstacleKind.pile:
        final count = max(1, (rect.width / rect.height).round());
        final width = rect.width / count;
        for (var i = 0; i < count; i++) {
          _addSprite(
            canvas,
            a,
            RunnerSprite.crate,
            Rect.fromLTWH(rect.left + i * width, rect.top, width, rect.height),
          );
        }
      case ObstacleKind.truss:
        final bar = a.ownTruss
            ? RunnerSprite.trussAssembly
            : RunnerSprite.truss;
        final barHeight = rect.width * bar.height / bar.width;
        var barTop = rect.bottom - barHeight;
        if (!a.ownTruss) {
          final lampWidth = rect.width * .19;
          final lampHeight =
              lampWidth * RunnerSprite.lamp.height / RunnerSprite.lamp.width;
          barTop = rect.bottom - lampHeight - barHeight * .5;
          for (var i = 0; i < 4; i++) {
            final x =
                rect.left + lampWidth / 2 + i * (rect.width - lampWidth) / 3;
            _addSprite(
              canvas,
              a,
              RunnerSprite.lamp,
              Rect.fromLTWH(
                x - lampWidth / 2,
                rect.bottom - lampHeight,
                lampWidth,
                lampHeight,
              ),
            );
          }
        }
        _addSprite(
          canvas,
          a,
          bar,
          Rect.fromLTWH(rect.left, barTop, rect.width, barHeight),
        );
      case ObstacleKind.drop:
        final sprite = RunnerSprite.drop;
        final height = rect.width * sprite.height / sprite.width;
        _addSprite(
          canvas,
          a,
          sprite,
          Rect.fromLTWH(rect.left, rect.bottom - height, rect.width, height),
        );
    }
  }

  void _flatBatched(Canvas canvas, RunnerArt a, Rect rect) {
    final sprite = RunnerSprite.flat, src = sprite.rect;
    final width = rect.width * 1.35, scale = width / sprite.width;
    final left = rect.center.dx - width / 2;
    const topCap = 36.0, footCap = 64.0;
    final top = topCap * scale, foot = footCap * scale;
    final image = a.imageOf(sprite), paint = a.paintOf(sprite);
    if (rect.height <= top + foot) {
      _spriteBatch.addRect(
        canvas,
        image,
        src,
        Rect.fromLTWH(left, rect.top, width, rect.height),
        paint,
      );
      return;
    }
    _spriteBatch
      ..addRect(
        canvas,
        image,
        Rect.fromLTRB(src.left, src.top, src.right, src.top + topCap),
        Rect.fromLTRB(left, rect.top, left + width, rect.top + top),
        paint,
      )
      ..addRect(
        canvas,
        image,
        Rect.fromLTRB(
          src.left,
          src.top + topCap,
          src.right,
          src.top + sprite.height - footCap,
        ),
        Rect.fromLTRB(left, rect.top + top, left + width, rect.bottom - foot),
        paint,
      )
      ..addRect(
        canvas,
        image,
        Rect.fromLTRB(
          src.left,
          src.top + sprite.height - footCap,
          src.right,
          src.bottom,
        ),
        Rect.fromLTRB(left, rect.bottom - foot, left + width, rect.bottom),
        paint,
      );
  }

  void _shelvesBatched(Canvas canvas, RunnerArt a, Rect rect) {
    final sprite = RunnerSprite.flat, src = sprite.rect;
    final width = rect.width * 1.35;
    final scale = width / sprite.width * RunnerSprite.shelfStretch;
    final left = rect.center.dx - width / 2;
    const rows = RunnerSprite.shelves, rowHeight = RunnerSprite.shelfHeight;
    const topCap = RunnerSprite.shelfTop, footCap = RunnerSprite.shelfFoot;
    final top = topCap * scale, foot = footCap * scale;
    final image = a.imageOf(sprite), paint = a.paintOf(sprite);
    final middle = rect.height - top - foot;
    if (middle <= 0) {
      _spriteBatch.addRect(
        canvas,
        image,
        src,
        Rect.fromLTRB(left, rect.top, left + width, rect.bottom),
        paint,
      );
      return;
    }
    final count = max(1, (middle / (rowHeight * scale)).round());
    final row = middle / count;
    _spriteBatch.addRect(
      canvas,
      image,
      Rect.fromLTRB(src.left, src.top, src.right, src.top + topCap),
      Rect.fromLTRB(left, rect.top, left + width, rect.top + top),
      paint,
    );
    for (var i = 0; i < count; i++) {
      final from = topCap + (i % rows) * rowHeight;
      final y = rect.top + top + i * row;
      _spriteBatch.addRect(
        canvas,
        image,
        Rect.fromLTRB(
          src.left,
          src.top + from,
          src.right,
          src.top + from + rowHeight,
        ),
        Rect.fromLTRB(left, y, left + width, y + row),
        paint,
      );
    }
    _spriteBatch.addRect(
      canvas,
      image,
      Rect.fromLTRB(
        src.left,
        src.top + sprite.height - footCap,
        src.right,
        src.bottom,
      ),
      Rect.fromLTRB(left, rect.bottom - foot, left + width, rect.bottom),
      paint,
    );
  }

  void _obstacle(
    Canvas canvas,
    RunnerArt a,
    Obstacle o,
    Rect rect,
    double s,
    double floorY,
  ) {
    switch (o.kind) {
      case ObstacleKind.crate when a.ownScenery && o.tall:
        // Two crates' height: one tall picture over the whole hitbox.
        _sprite(canvas, a, RunnerSprite.twoCrates, rect);
      case ObstacleKind.crate when a.ownScenery:
        // One crate: the set's picture, as wide as it needs to stay upright.
        final width = rect.width * 1.12;
        _sprite(
          canvas,
          a,
          RunnerSprite.crate,
          Rect.fromLTRB(
            rect.center.dx - width / 2,
            rect.top,
            rect.center.dx + width / 2,
            rect.bottom,
          ),
        );
      case ObstacleKind.crate when a.ownTallCrate && o.tall:
        // One tall picture over the whole hitbox: the cell is as high as
        // the tall crates are on average, so it is never stretched much.
        _sprite(canvas, a, RunnerSprite.tallCrate, rect);
      case ObstacleKind.crate when a.ownTallCrate:
        // The set shows its picture at one height: a low crate is the
        // game's own, not the crate cell of the set.
        canvas.drawImageRect(
          a.atlas,
          RunnerSprite.crate.rect,
          rect,
          a.obstaclePaint,
        );
      case ObstacleKind.crate when a.ownPile && o.tall:
        _sprite(canvas, a, RunnerSprite.pile, rect);
      case ObstacleKind.crate:
        // A tall pile is two crates, so none gets stretched much.
        if (o.tall) {
          final half = rect.height / 2;
          _sprite(
            canvas,
            a,
            RunnerSprite.crate,
            rect.topLeft & Size(rect.width, half),
          );
          _sprite(
            canvas,
            a,
            RunnerSprite.crate,
            Rect.fromLTWH(rect.left, rect.top + half, rect.width, half),
          );
        } else {
          _sprite(canvas, a, RunnerSprite.crate, rect);
        }
      case ObstacleKind.flat when a.ownScenery && o.gap:
        _guillotineBase(canvas, a, rect);
      case ObstacleKind.flat when a.ownScenery:
        _shelves(canvas, a, rect);
      case ObstacleKind.flat:
        _flat(canvas, a, rect);
      case ObstacleKind.border when a.ownScenery:
        _guillotineTop(canvas, a, rect, (o.anchor - o.bottom) * s, s);
      case ObstacleKind.border:
        _velvetPiece(canvas, rect, s, a.border);
      case ObstacleKind.lamp:
        final width = rect.width * 1.05;
        final body = _lamp(
          canvas,
          a,
          rect.center.dx,
          rect.bottom,
          width,
          floorY,
        );
        canvas.drawLine(
          Offset(rect.center.dx, 0),
          Offset(rect.center.dx, body.top),
          _ropePaint,
        );
      case ObstacleKind.sandbag:
        final sprite = RunnerSprite.sandbag;
        final width = rect.width * 1.25;
        final height = width * sprite.height / sprite.width;
        final bag = Rect.fromLTWH(
          rect.center.dx - width / 2,
          rect.bottom - height,
          width,
          height,
        );
        canvas.drawLine(
          Offset(rect.center.dx, 0),
          Offset(rect.center.dx, bag.top + height * .1),
          _ropePaint,
        );
        _sprite(canvas, a, sprite, bag);
      case ObstacleKind.drum:
        if (o.falling) _drumTrail(canvas, rect, s);
        // The spokes turn with the way it rolled.
        final r = rect.width * .56;
        final center = Offset(rect.center.dx, rect.bottom - r);
        canvas
          ..save()
          ..translate(center.dx, center.dy)
          ..rotate(o.left * s / r);
        _sprite(
          canvas,
          a,
          RunnerSprite.drum,
          Rect.fromCircle(center: Offset.zero, radius: r),
        );
        canvas.restore();
      case ObstacleKind.pile when a.ownPile || a.ownScenery:
        // One picture over both parts, drawn with the lower one (the upper
        // one is as high and stands on it); the hitboxes stay the same.
        if (o.bottom >= StageRunner.floor) {
          _sprite(
            canvas,
            a,
            a.ownScenery ? RunnerSprite.threeCrates : RunnerSprite.pile,
            Rect.fromLTRB(
              rect.left,
              rect.top - rect.height,
              rect.right,
              rect.bottom,
            ),
          );
        }
      case ObstacleKind.pile:
        // The lower part holds two crates side by side, the top one.
        final count = max(1, (rect.width / rect.height).round());
        final width = rect.width / count;
        for (var i = 0; i < count; i++) {
          _sprite(
            canvas,
            a,
            RunnerSprite.crate,
            Rect.fromLTWH(rect.left + i * width, rect.top, width, rect.height),
          );
        }
      case ObstacleKind.truss:
        final bar = a.ownTruss
            ? RunnerSprite.trussAssembly
            : RunnerSprite.truss;
        final barHeight = rect.width * bar.height / bar.width;
        var barTop = rect.bottom - barHeight;
        var suspensionY = rect.bottom;
        if (!a.ownTruss) {
          // Four lamps under a plain truss, the outer ones flush with its ends.
          final lampWidth = rect.width * .19;
          final lampHeight =
              lampWidth * RunnerSprite.lamp.height / RunnerSprite.lamp.width;
          barTop = rect.bottom - lampHeight - barHeight * .5;
          suspensionY = barTop;
          for (var i = 0; i < 4; i++) {
            final x =
                rect.left + lampWidth / 2 + i * (rect.width - lampWidth) / 3;
            _lamp(canvas, a, x, rect.bottom, lampWidth, floorY);
          }
        }
        final leftRope = rect.left + s * .012, rightRope = rect.right - s * .012;
        canvas
          ..drawLine(Offset(leftRope, 0), Offset(leftRope, suspensionY), _ropePaint)
          ..drawLine(Offset(rightRope, 0), Offset(rightRope, suspensionY), _ropePaint);
        _sprite(
          canvas,
          a,
          bar,
          Rect.fromLTWH(rect.left, barTop, rect.width, barHeight),
        );
      case ObstacleKind.drop:
        final sprite = RunnerSprite.drop;
        final height = rect.width * sprite.height / sprite.width;
        final frame = Rect.fromLTWH(
          rect.left,
          rect.bottom - height,
          rect.width,
          height,
        );
        // Heavy fly lines all the way up to the loft, like [_plainObstacle],
        // so the solid hitbox column above the painted frame is unmistakable.
        final inset = rect.width * .18;
        final lineBottom = frame.top + height * .04;
        final leftX = frame.left + inset, rightX = frame.right - inset;
        canvas
          ..drawLine(Offset(leftX, 0), Offset(leftX, lineBottom), _flyLineEdge)
          ..drawLine(Offset(leftX, 0), Offset(leftX, lineBottom), _flyLinePaint)
          ..drawLine(Offset(rightX, 0), Offset(rightX, lineBottom), _flyLineEdge)
          ..drawLine(Offset(rightX, 0), Offset(rightX, lineBottom), _flyLinePaint);
        _sprite(canvas, a, sprite, frame);
    }
  }

  /// Whether a waiting sandbag is close enough to telegraph its drop.
  static bool _sandbagTelegraphing(StageRunner g, Obstacle o) =>
      !o.falling &&
      o.bottom <= StageRunner.ceiling + .01 &&
      o.left - g.runnerWorldX < g.speed * 1.4 &&
      o.left > g.runnerWorldX - StageRunner.hitHalfWidth;

  /// Floor target shadow under an impending or falling sandbag.
  void _sandbagShadow(
    Canvas canvas,
    StageRunner g,
    Obstacle o,
    Rect rect,
    double s,
    double floorY,
  ) {
    final waiting = _sandbagTelegraphing(g, o);
    final falling = o.falling && o.bottom < StageRunner.floor - .01;
    if (!waiting && !falling) return;
    final progress = falling
        ? ((o.bottom - StageRunner.ceiling) /
                  (StageRunner.floor - StageRunner.ceiling))
              .clamp(0.0, 1.0)
        : 0.35;
    final width = rect.width * (.7 + .65 * progress);
    final height = s * (.014 + .014 * progress);
    final oval = Rect.fromCenter(
      center: Offset(rect.center.dx, floorY + s * .006),
      width: width,
      height: height,
    );
    canvas.drawOval(
      oval,
      waiting ? _sandbagWarnShadowPaint : _sandbagShadowPaint,
    );
  }

  /// Wobbling warning rope and marker below the opaque valance just before a
  /// sandbag drops (drawn after [_bannerAndValance] so the valance never hides
  /// it).
  void _sandbagWarnings(
    Canvas canvas,
    StageRunner g,
    double s,
    double w,
    double course,
    bool reduced,
  ) {
    final obstacles = g.obstacles;
    for (var i = 0, len = obstacles.length; i < len; i++) {
      final o = obstacles[i];
      if (o.kind != ObstacleKind.sandbag || !_sandbagTelegraphing(g, o)) {
        continue;
      }
      final cx = (o.left + o.width / 2) * s - course;
      if (cx < -s * .1 || cx > w + s * .1) continue;
      final wobble = reduced ? 0.0 : sin(g.time * 42 + o.left * 17) * s * .006;
      final startY = s * StageRunner.ceiling * .9;
      final endY = s * (StageRunner.ceiling + .055);
      canvas.drawLine(
        Offset(cx, startY),
        Offset(cx + wobble, endY),
        _sandbagWarnRopePaint,
      );
      // Small downward pointer at the rope end below the valance.
      final tipX = cx + wobble;
      final r = s * .014;
      if (_decoration.rasterize) {
        _discBatch.addTriangle(
          canvas,
          tipX - r,
          endY - r * .3,
          tipX + r,
          endY - r * .3,
          tipX,
          endY + r * 1.1,
          _sandbagWarnFillArgb,
        );
      } else {
        _path
          ..reset()
          ..moveTo(tipX - r, endY - r * .3)
          ..lineTo(tipX + r, endY - r * .3)
          ..lineTo(tipX, endY + r * 1.1)
          ..close();
        canvas.drawPath(_path, _sandbagWarnFill);
      }
    }
    if (_decoration.rasterize) _discBatch.flush(canvas);
  }

  /// Subtle dust puffs trailing right of a rolling drum.
  void _drumTrail(Canvas canvas, Rect rect, double s) {
    final baseY = rect.bottom - s * .012;
    final baseX = rect.right;
    canvas.drawCircle(
      Offset(baseX + s * .022, baseY - s * .004),
      s * .012,
      _drumDustPaint,
    );
    canvas.drawCircle(
      Offset(baseX + s * .048, baseY - s * .009),
      s * .009,
      _drumDustPaint,
    );
    canvas.drawCircle(
      Offset(baseX + s * .072, baseY - s * .005),
      s * .006,
      _drumDustPaint,
    );
  }

  /// A stage light hanging with its lens at [bottom], with its beam down to
  /// the floor; returns where the lamp is.
  Rect _lamp(
    Canvas canvas,
    RunnerArt a,
    double centerX,
    double bottom,
    double width,
    double floorY,
  ) {
    final sprite = RunnerSprite.lamp;
    final height = width * sprite.height / sprite.width;
    final body = Rect.fromLTWH(
      centerX - width / 2,
      bottom - height,
      width,
      height,
    );
    // The beam from the lens down to the floor.
    final lens = Offset(body.center.dx, body.bottom - height * .06);
    _path
      ..reset()
      ..moveTo(lens.dx - width * .3, lens.dy)
      ..lineTo(lens.dx + width * .3, lens.dy)
      ..lineTo(lens.dx + width * .9, floorY)
      ..lineTo(lens.dx - width * .9, floorY)
      ..close();
    canvas.drawPath(_path, _beamPaint);
    _sprite(canvas, a, sprite, body);
    return body;
  }

  static void _drawSlice(
    Canvas canvas,
    ui.Image image,
    Paint paint,
    Rect src,
    double left,
    double width,
    double srcTop,
    double srcBottom,
    double dstTop,
    double dstBottom,
  ) => canvas.drawImageRect(
    image,
    Rect.fromLTRB(src.left, src.top + srcTop, src.right, src.top + srcBottom),
    Rect.fromLTRB(left, dstTop, left + width, dstBottom),
    paint,
  );

  /// A painted flat in three slices: frame top and feet keep their shape,
  /// only the canvas in between stretches.
  void _flat(Canvas canvas, RunnerArt a, Rect rect) {
    final sprite = RunnerSprite.flat, src = sprite.rect;
    final width = rect.width * 1.35, scale = width / sprite.width;
    final left = rect.center.dx - width / 2;
    const topCap = 36.0, footCap = 64.0;
    final top = topCap * scale, foot = footCap * scale;
    if (rect.height <= top + foot) {
      _sprite(
        canvas,
        a,
        sprite,
        Rect.fromLTWH(left, rect.top, width, rect.height),
      );
      return;
    }
    final image = a.imageOf(sprite), paint = a.paintOf(sprite);
    _drawSlice(canvas, image, paint, src, left, width, 0, topCap, rect.top, rect.top + top);
    _drawSlice(
      canvas,
      image,
      paint,
      src,
      left,
      width,
      topCap,
      sprite.height - footCap,
      rect.top + top,
      rect.bottom - foot,
    );
    _drawSlice(
      canvas,
      image,
      paint,
      src,
      left,
      width,
      sprite.height - footCap,
      sprite.height,
      rect.bottom - foot,
      rect.bottom,
    );
  }

  /// A set's flat as a bookcase: its top and foot keep their shape, and
  /// between them are as many whole shelves as fit, so that no book gets
  /// stretched much at any height.
  void _shelves(Canvas canvas, RunnerArt a, Rect rect) {
    final sprite = RunnerSprite.flat, src = sprite.rect;
    final width = rect.width * 1.35;
    final scale = width / sprite.width * RunnerSprite.shelfStretch;
    final left = rect.center.dx - width / 2;
    const rows = RunnerSprite.shelves, rowHeight = RunnerSprite.shelfHeight;
    const topCap = RunnerSprite.shelfTop, footCap = RunnerSprite.shelfFoot;
    final top = topCap * scale, foot = footCap * scale;
    final image = a.imageOf(sprite), paint = a.paintOf(sprite);
    final middle = rect.height - top - foot;
    if (middle <= 0) {
      _drawSlice(canvas, image, paint, src, left, width, 0, sprite.height, rect.top, rect.bottom);
      return;
    }
    final count = max(1, (middle / (rowHeight * scale)).round());
    final row = middle / count;
    _drawSlice(canvas, image, paint, src, left, width, 0, topCap, rect.top, rect.top + top);
    for (var i = 0; i < count; i++) {
      final from = topCap + (i % rows) * rowHeight;
      final y = rect.top + top + i * row;
      _drawSlice(canvas, image, paint, src, left, width, from, from + rowHeight, y, y + row);
    }
    _drawSlice(
      canvas,
      image,
      paint,
      src,
      left,
      width,
      sprite.height - footCap,
      sprite.height,
      rect.bottom - foot,
      rect.bottom,
    );
  }

  /// How much wider than its hitbox the timber of a guillotine is, like a flat.
  static const _guillotineWidth = 1.35;

  /// The upper part of a guillotine, where a border is: its timber up to the
  /// fly loft and only as far as the back of the blade, so that the blade's
  /// slant shows; the uprights on past it over the [gap] below; and at the
  /// lower edge the blade, the same size at any height of the gap.
  void _guillotineTop(
    Canvas canvas,
    RunnerArt a,
    Rect rect,
    double gap,
    double s,
  ) {
    final width = rect.width * _guillotineWidth;
    final left = rect.center.dx - width / 2;
    final cell = RunnerSprite.guillotine;
    final blade = RunnerSprite.guillotineBlade;
    final height = width * blade.height / blade.width;
    final back = rect.bottom - height * .75;
    const upright = RunnerSprite.guillotineUpright;
    if (back > rect.top) {
      _sprite(
        canvas,
        a,
        cell,
        Rect.fromLTRB(left, rect.top, left + width, back),
      );
      // The backdrop's border hangs above the blade, between the timber
      // uprights. The blade is drawn last, over the fringe.
      if (a.border != null) {
        _velvetPiece(
          canvas,
          Rect.fromLTRB(
            left + width * upright,
            rect.top,
            left + width * (1 - upright),
            back,
          ),
          s,
          a.border,
        );
      }
    }
    const sides = [0.0, 1 - upright];
    final cellImg = a.imageOf(cell), cellPaint = a.paintOf(cell);
    final dstTop = max(rect.top, back), dstBottom = rect.bottom + max(0.0, gap);
    for (final side in sides) {
      canvas.drawImageRect(
        cellImg,
        Rect.fromLTWH(
          cell.x + cell.width * side,
          cell.y,
          cell.width * upright,
          cell.height,
        ),
        Rect.fromLTRB(
          left + width * side,
          dstTop,
          left + width * (side + upright),
          dstBottom,
        ),
        cellPaint,
      );
    }
    _sprite(
      canvas,
      a,
      blade,
      Rect.fromLTWH(left, rect.bottom - height, width, height),
    );
  }

  /// The lower part of a guillotine, where the flat below a border is: its
  /// timber down to the floor, and at its upper edge the block, which stays
  /// the same size; on a flat lower than the block, its lower part is cut.
  void _guillotineBase(Canvas canvas, RunnerArt a, Rect rect) {
    final width = rect.width * _guillotineWidth;
    final left = rect.center.dx - width / 2;
    _sprite(
      canvas,
      a,
      RunnerSprite.guillotine,
      Rect.fromLTRB(left, rect.top, left + width, rect.bottom),
    );
    final block = RunnerSprite.guillotineBlock;
    final height = width * block.height / block.width;
    final shown = min(1.0, rect.height / height);
    canvas.drawImageRect(
      a.imageOf(block),
      Rect.fromLTWH(block.x, block.y, block.width, block.height * shown),
      Rect.fromLTWH(left, rect.top, width, height * shown),
      a.paintOf(block),
    );
  }

  /// A border (short curtain) hanging from the fly loft, with gold fringe.
  /// In [color] if the backdrop gives one (the folds a third darker),
  /// else in the theatre's red.
  void _velvetPiece(Canvas canvas, Rect rect, double s, [Color? color]) {
    if (color != null && color != _borderPaint.color) {
      _borderPaint.color = color;
      _borderFoldPaint.color = Color.lerp(color, const Color(0xFF000000), .34)!;
    }
    canvas.drawRect(rect, color == null ? _velvetPaint : _borderPaint);
    final fold = rect.width / 5;
    for (var i = 1; i < 5; i += 2) {
      canvas.drawRect(
        Rect.fromLTWH(rect.left + fold * i, rect.top, fold * .7, rect.height),
        color == null ? _foldPaint : _borderFoldPaint,
      );
    }
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.bottom - s * .014, rect.width, s * .014),
      _goldPaint,
    );
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(
        Offset(rect.left + rect.width * (i + .5) / 4, rect.bottom + s * .006),
        s * .006,
        _goldPaint,
      );
    }
  }

  void _pickups(
    Canvas canvas,
    StageRunner g,
    RunnerArt? a,
    double s,
    double w,
    double course,
    bool reduced,
  ) {
    final glyph = s * .075, height = s * .085;
    final pickups = g.pickups;
    for (var i = 0, len = pickups.length; i < len; i++) {
      final p = pickups[i];
      if (p.taken) continue;
      final x = p.x * s - course;
      if (x < -glyph || x > w + glyph) continue;
      // A gentle bob unless system reduced motion is on; hitbox stays fixed.
      final y = reduced
          ? p.y * s
          : p.y * s + sin(g.time * 4 + p.x * 7) * s * .008;
      if (a == null) {
        _paintCentered(canvas, _glyphs.icon(p.kind, glyph), Offset(x, y));
        continue;
      }
      final sprite = RunnerSprite.of(p.kind);
      final scale = height / max(sprite.width, sprite.height);
      _sprite(
        canvas,
        a,
        sprite,
        Rect.fromCenter(
          center: Offset(x, y),
          width: sprite.width * scale,
          height: sprite.height * scale,
        ),
      );
    }
  }

  /// Engel Logge: runs on the floor, flies with arms forward, dangles when
  /// sinking, cheers at a pickup and crashes comically.
  void _runner(
    Canvas canvas,
    StageRunner g,
    RunnerFx f,
    RunnerArt a,
    double s,
    bool reduced, {
    bool batched = false,
  }) {
    final onFloor =
        g.y >= StageRunner.floor - StageRunner.runnerHeight / 2 - .001;
    final RunnerSprite sprite;
    var feet = g.y + StageRunner.runnerHeight / 2 + .006;
    var angle = 0.0, wireTop = 0.0;
    if (g.over) {
      sprite = RunnerSprite.crash;
      // Drops to the floor with a little bounce (calm without bounce/rotation
      // under system reduced motion); the wire snaps upwards.
      final t = (g.sinceOver / .35).clamp(0, 1).toDouble();
      final bounce = reduced ? 0.0 : (1 - t) * sin(t * pi) * .06;
      feet =
          feet +
          (StageRunner.floor + .01 - feet) * Curves.easeIn.transform(t) -
          bounce;
      angle = reduced ? 0.0 : (1 - t) * .5;
      wireTop =
          (g.y - StageRunner.runnerHeight / 2) * Curves.easeOut.transform(t);
    } else if (f.cheer > 0) {
      sprite = RunnerSprite.cheer;
    } else if (onFloor) {
      sprite = RunnerSprite.stride(g.distance);
    } else {
      sprite = g.vy < -.05 ? RunnerSprite.fly : RunnerSprite.dangle;
      angle = reduced ? 0.0 : (g.vy * .12).clamp(-.2, .2).toDouble();
    }
    final scale = RunnerSprite.stagePerPixel * s;
    final width = sprite.width * scale, height = sprite.height * scale;
    // Flying flat, the body lies around the middle of the hitbox; every
    // other pose stands on its feet.
    if (sprite == RunnerSprite.fly) feet = g.y + height / s / 2;
    final cx = StageRunner.runnerX * s, bottom = feet * s;
    final dst = Rect.fromLTWH(cx - width / 2, bottom - height, width, height);
    final harness = dst.topLeft + a.harnessOf(sprite) * scale;
    if (!g.over) {
      canvas.drawLine(Offset(harness.dx, 0), harness, _ropePaint);
    } else if (wireTop > 0) {
      canvas.drawLine(
        Offset(cx, 0),
        Offset(
          cx,
          (g.y - StageRunner.runnerHeight / 2) * s - wireTop * s + s * .02,
        ),
        _ropePaint,
      );
    }
    final shine = !reduced && (a.effect?.shine ?? false);
    if (batched && !shine) {
      if (angle == 0) {
        _spriteBatch
          ..addRect(
            canvas,
            a.imageOf(sprite),
            sprite.rect,
            dst,
            a.paintOf(sprite),
          )
          ..flush(canvas);
      } else {
        _spriteBatch
          ..addRotated(
            canvas,
            a.imageOf(sprite),
            sprite.rect,
            dst.center,
            scale,
            angle,
            a.paintOf(sprite),
          )
          ..flush(canvas);
      }
      return;
    }
    if (angle == 0) {
      _figure(canvas, a, sprite, dst, shine);
    } else {
      final pivot = dst.center;
      canvas
        ..save()
        ..translate(pivot.dx, pivot.dy)
        ..rotate(angle)
        ..translate(-pivot.dx, -pivot.dy);
      _figure(canvas, a, sprite, dst, shine);
      canvas.restore();
    }
    if (shine) trail().paintGlints(canvas, dst, s);
  }

  /// The figure; a shiny one with a golden rim and a sheen sweeping over
  /// it, on its own pixels, so it fits every pose. Hitbox and physics stay
  /// the same.
  void _figure(
    Canvas canvas,
    RunnerArt a,
    RunnerSprite sprite,
    Rect dst,
    bool shine,
  ) {
    if (!shine) return _sprite(canvas, a, sprite, dst);
    final image = a.imageOf(sprite), time = trail().time;
    _rim.paint(canvas, image, sprite.rect, dst, time);
    _sprite(canvas, a, sprite, dst);
    paintSheen(canvas, image, sprite.rect, dst, time);
  }

  void _particles(Canvas canvas, RunnerFx f, double s, bool reduced) {
    if (!reduced && f.hasParticles) {
      if (_decoration.rasterize) {
        for (var i = 0; i < RunnerFx.maxParticles; i++) {
          final life = f.life[i];
          if (life <= 0) continue;
          _discBatch.addCircle(
            canvas,
            f.px[i] * s,
            f.py[i] * s,
            f.size[i] * s * min(1, life * 3),
            _particleArgb[f.tint[i]],
          );
        }
        _discBatch.flush(canvas);
      } else {
        for (var i = 0; i < RunnerFx.maxParticles; i++) {
          final life = f.life[i];
          if (life <= 0) continue;
          canvas.drawCircle(
            Offset(f.px[i] * s, f.py[i] * s),
            f.size[i] * s * min(1, life * 3),
            _particlePaints[f.tint[i]],
          );
        }
      }
    }
    if (!f.hasPopups) return;
    final size = s * .045;
    final popups = f.popups;
    final shadowDelta = Offset(s * .003, s * .003);
    for (var i = 0, len = popups.length; i < len; i++) {
      final p = popups[i];
      if (!p.alive) continue;
      final at = Offset(p.x * s, (p.y - (reduced ? 0 : p.age * .12)) * s);
      _paintCentered(
        canvas,
        _glyphs.label(p.text, size, shadow: true),
        at + shadowDelta,
      );
      _paintCentered(canvas, _glyphs.label(p.text, size), at);
    }
  }

  /// Heads in the front row, passing with the stage. They sit calmly, also
  /// while a banner celebrates.
  void _audience(
    Canvas canvas,
    double s,
    double w,
    double scroll,
    bool shaking,
  ) => _decoration.paintAudience(canvas, s, w, scroll, shaking);

  /// Tall pictures: above the playing field the house's velvet drape,
  /// [top] pixels high, its folds passing with the stage, darker towards
  /// the top and hemmed in gold above the valance.
  void _drapes(
    Canvas canvas,
    double s,
    double w,
    double top,
    double scroll,
    bool shaking,
  ) {
    final from = -top - s * .05;
    if (_decoration.paintDrapes(canvas, s, w, top, from, scroll, shaking)) {
      return;
    }
    // The drape fades into the dark of the fly loft; the shader is made
    // again only when the picture changes its size.
    if (_shadeTop != top) {
      _shadeTop = top;
      _shadePaint.shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xCC000000), Color(0x00000000)],
      ).createShader(Rect.fromLTRB(0, -top, 1, -top * .4));
    }
    if (top > s * .2) {
      canvas.drawRect(Rect.fromLTRB(0, from, w, -top * .4), _shadePaint);
    }
    canvas.drawRect(Rect.fromLTRB(0, -s * .012, w, -s * .004), _goldPaint);
  }

  /// Tall pictures: below the stage the stalls, [below] pixels high, rows
  /// of silhouettes behind red seat backs, a little larger the nearer they
  /// sit. They pass with the stage, exactly like the front row.
  void _stalls(
    Canvas canvas,
    double s,
    double w,
    double below,
    double scroll,
    bool shaking,
  ) => _decoration.paintStalls(canvas, s, w, below, scroll, shaking);

  /// The banner pops in below the valance and slides up behind it. The
  /// valance's scallops pass with the stage.
  void _bannerAndValance(
    Canvas canvas,
    RunnerFx f,
    double s,
    double w,
    double scroll,
    bool movingScenery,
    bool shaking,
  ) {
    final text = f.banner;
    if (text != null && f.showsBanner) {
      final t = f.bannerAge;
      final pop = movingScenery && t < .18
          ? Curves.easeOutBack.transform(t / .18)
          : 1.0;
      final leave = movingScenery
          ? max(0.0, t - (RunnerFx.bannerLife - .3)) / .3
          : 0.0;
      final label = _glyphs.label(text, s * .055);
      final center = Offset(w / 2, s * (.2 - leave * .2));
      final plate = Rect.fromCenter(
        center: center,
        width: label.width + s * .08,
        height: label.height + s * .03,
      );
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..scale(pop)
        ..translate(-center.dx, -center.dy);
      final rrect = RRect.fromRectAndRadius(plate, Radius.circular(s * .03));
      canvas
        ..drawRRect(rrect, _platePaint)
        ..drawRRect(rrect, _plateEdge);
      _paintCentered(canvas, label, center);
      canvas.restore();
    }
    // Valance of the stage portal with a scalloped edge.
    _decoration.paintValance(canvas, s, w, scroll, shaking);
  }

  /// The curtain closes from both sides after the crash, over the whole
  /// picture, [height] pixels tall.
  void _curtain(
    Canvas canvas,
    StageRunner g,
    double s,
    double w,
    double height,
    bool movingScenery,
  ) {
    final t = movingScenery
        ? Curves.easeIn.transform(
            ((g.sinceOver - _curtainStart) /
                    (_curtainEnd - _curtainStart - .05))
                .clamp(0, 1)
                .toDouble(),
          )
        : g.sinceOver < _curtainStart
        ? 0.0
        : 1.0;
    if (t == 0) return;
    final half = w * .5 * t, fold = s * .06;
    for (final left in const [true, false]) {
      final rect = left
          ? Rect.fromLTRB(0, 0, half, height)
          : Rect.fromLTRB(w - half, 0, w, height);
      canvas.drawRect(rect, _velvetPaint);
      for (var x = rect.left + fold * .5; x < rect.right; x += fold) {
        canvas.drawRect(Rect.fromLTWH(x, 0, fold * .35, height), _foldPaint);
      }
      final edge = left ? rect.right - s * .012 : rect.left;
      canvas.drawRect(Rect.fromLTWH(edge, 0, s * .012, height), _goldPaint);
    }
  }

  void _plainObstacle(
    Canvas canvas,
    Obstacle o,
    Rect rect,
    double s,
    double floorY,
  ) {
    switch (o.kind) {
      case ObstacleKind.crate:
        canvas.drawRect(rect, _woodPaint);
        canvas.drawRect(rect.deflate(1), _woodLine);
        canvas.drawLine(rect.topLeft, rect.bottomRight, _woodLine);
        canvas.drawLine(rect.topRight, rect.bottomLeft, _woodLine);
      case ObstacleKind.flat:
        canvas.drawRect(rect, _canvasPaint);
        canvas.drawRect(rect.deflate(1), _canvasLine);
      case ObstacleKind.border:
        _velvetPiece(canvas, rect, s);
      case ObstacleKind.lamp:
        final cx = rect.center.dx;
        final body = Rect.fromLTRB(
          rect.left,
          rect.bottom - s * .1,
          rect.right,
          rect.bottom,
        );
        canvas.drawLine(Offset(cx, 0), Offset(cx, body.top), _ropePaint);
        canvas.drawRect(body, _metalPaint);
        canvas.drawRect(
          Rect.fromLTRB(
            body.left + 3,
            body.bottom - 5,
            body.right - 3,
            body.bottom,
          ),
          _lensPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(body.left, body.bottom, body.right, floorY),
          _beamPaint,
        );
      case ObstacleKind.sandbag:
        final cx = rect.center.dx;
        canvas.drawLine(Offset(cx, 0), Offset(cx, rect.top), _ropePaint);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(rect.width * .3)),
          _sackPaint,
        );
        _paintCentered(canvas, _glyphs.kg(rect.width), rect.center);
      case ObstacleKind.drum:
        if (o.falling) _drumTrail(canvas, rect, s);
        canvas
          ..drawCircle(rect.center, rect.width / 2, _woodPaint)
          ..drawCircle(rect.center, rect.width / 2 - 1, _woodLine)
          ..drawCircle(rect.center, rect.width * .15, _metalPaint);
      case ObstacleKind.pile:
        canvas.drawRect(rect, _woodPaint);
        canvas.drawRect(rect.deflate(1), _woodLine);
      case ObstacleKind.truss:
        final bar = Rect.fromLTRB(
          rect.left,
          rect.bottom - s * .1,
          rect.right,
          rect.bottom - s * .06,
        );
        canvas
          ..drawLine(Offset(bar.left + 2, 0), Offset(bar.left + 2, bar.top), _ropePaint)
          ..drawLine(Offset(bar.right - 2, 0), Offset(bar.right - 2, bar.top), _ropePaint)
          ..drawRect(bar, _metalPaint)
          ..drawRect(
            Rect.fromLTRB(rect.left, bar.bottom, rect.right, rect.bottom),
            _metalPaint,
          )
          ..drawRect(
            Rect.fromLTRB(rect.left, rect.bottom, rect.right, floorY),
            _beamPaint,
          );
      case ObstacleKind.drop:
        final frame = Rect.fromLTRB(
          rect.left,
          rect.bottom - rect.width * 1.4,
          rect.right,
          rect.bottom,
        );
        // Two heavy fly lines at the frame's edges: the whole column up to
        // the loft is solid, so it reads as one that cannot be jumped over.
        final inset = rect.width * .16;
        final leftX = frame.left + inset, rightX = frame.right - inset;
        canvas
          ..drawLine(Offset(leftX, 0), Offset(leftX, frame.top), _flyLineEdge)
          ..drawLine(Offset(leftX, 0), Offset(leftX, frame.top), _flyLinePaint)
          ..drawLine(Offset(rightX, 0), Offset(rightX, frame.top), _flyLineEdge)
          ..drawLine(Offset(rightX, 0), Offset(rightX, frame.top), _flyLinePaint)
          ..drawRect(frame, _canvasPaint)
          ..drawRect(frame.deflate(1), _canvasLine);
    }
  }

  /// A plain figure around its centre, in stage heights: head, body and
  /// legs, as [_plainRunner] draws them.
  static Path _plainFigure() {
    const h = StageRunner.runnerHeight, w = StageRunner.runnerWidth;
    return Path()
      ..addOval(
        Rect.fromCircle(center: const Offset(0, -h * .34), radius: h * .14),
      )
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: const Offset(0, -h * .02),
            width: w * .8,
            height: h * .42,
          ),
          const Radius.circular(w * .3),
        ),
      )
      ..addRect(const Rect.fromLTRB(-w * .32, h * .15, -w * .08, h * .5))
      ..addRect(const Rect.fromLTRB(w * .08, h * .15, w * .32, h * .5));
  }

  /// The week's other runs: each ghost [RunnerGhosts.shown] at its height at
  /// this moment (all runs are at the same place at the same time), faint
  /// and fading further near the own figure ([ghostAlpha]); gone after its
  /// crash but for a small cross where it happened. The names of
  /// [RunnerGhosts.named] show for the first seconds ([ghostTagAlpha]).
  void _ghostRuns(
    Canvas canvas,
    StageRunner g,
    RunnerGhosts ghosts,
    GhostSkins? skins,
    RunnerArt? a,
    double s,
    double w,
    double course,
  ) {
    final shown = ghosts.shown, t = g.time, mark = s * .012;
    // Off ([GhostMode.off]): no ghost, no cross and no name.
    if (shown.isEmpty) return;
    final shownLen = shown.length;
    for (var i = 0; i < shownLen; i++) {
      final ghost = shown[i];
      if (!ghost.crashed || t < ghost.end) continue;
      final x = ghost.endX * s - course;
      if (x < -mark || x > w + mark) continue;
      final y = ghost.endY * s;
      final highlight = ghost.highlightCrash;
      final m = highlight ? mark * 1.25 : mark;
      final paint = ghost.top
          ? _ghostMedalMarks[ghost.rank - 1]
          : ghost.me
          ? _ghostOwnMark
          : _ghostMark;
      canvas
        ..drawLine(Offset(x - m, y - m), Offset(x + m, y + m), paint)
        ..drawLine(Offset(x - m, y + m), Offset(x + m, y - m), paint);
      if (highlight) {
        final label = _glyphs.crashTag(
          ghost.crashTag,
          s * .026,
          ghost.rank,
          ghost.me,
        );
        final top = max(s * StageRunner.ceiling, y - m - label.height - s * .006);
        label.paint(canvas, Offset(x - label.width / 2, top));
      }
    }
    final cx = StageRunner.runnerX * s;
    final stride = RunnerSprite.stride(g.distance);
    final scale = RunnerSprite.stagePerPixel * s;
    // The best last, on top.
    for (var i = shownLen - 1; i >= 0; i--) {
      final ghost = shown[i];
      if (t > ghost.end) continue;
      final y = ghost.yAt(t);
      final step = (ghostAlpha(y, g.y) / ghostOpacity * _ghostSteps)
          .round()
          .clamp(0, _ghostSteps);
      if (step == 0) continue;
      final skin = a == null ? null : skins?.of(ghost, a);
      if (skin == null) {
        _ghostPaint.color = _ghostSilhouettes[step];
        canvas
          ..save()
          ..translate(cx, y * s)
          ..scale(s)
          ..drawPath(_ghostFigure, _ghostPaint)
          ..restore();
      } else {
        _ghostSkinPaint.color = _ghostOpacities[step];
        _ghostSprite(canvas, t, ghost, skin, y, s, cx, stride, scale);
      }
    }
    final tags = ghostTagAlpha(t);
    if (tags > 0) _ghostTags(canvas, ghosts, t, s, tags);
  }

  /// A ghost in its figure: the runner's poses, without the wire and
  /// without tilting, so it stays calm.
  void _ghostSprite(
    Canvas canvas,
    double t,
    RunnerGhost ghost,
    ui.Image skin,
    double y,
    double s,
    double cx,
    RunnerSprite stride,
    double scale,
  ) {
    final sprite = RunnerGhost.isOnFloor(y)
        ? stride
        : ghost.vyAtWithY(t, y) < -.05
        ? RunnerSprite.fly
        : RunnerSprite.dangle;
    final width = sprite.width * scale, height = sprite.height * scale;
    final feet = sprite == RunnerSprite.fly
        ? y + height / s / 2
        : y + StageRunner.runnerHeight / 2 + .006;
    final bottom = feet * s;
    canvas.drawImageRect(
      skin,
      sprite.rect,
      Rect.fromLTWH(cx - width / 2, bottom - height, width, height),
      _ghostSkinPaint,
    );
  }

  /// The names left of their ghosts, lowest first and each above the one
  /// below where they would overlap (at the start everyone stands on the
  /// floor); fading as a whole ([alpha]).
  void _ghostTags(
    Canvas canvas,
    RunnerGhosts ghosts,
    double t,
    double s,
    double alpha,
  ) {
    final size = s * .03, gap = StageRunner.runnerWidth * s * .7;
    final cx = StageRunner.runnerX * s;
    var n = 0;
    final shown = ghosts.shown;
    for (var k = 0, len = shown.length; k < len; k++) {
      if (n == _tagGhosts.length) break;
      final ghost = shown[k];
      if (t > ghost.end || !ghosts.named.contains(ghost)) continue;
      // Sorted by height as they come, the lowest first.
      final top =
          (ghost.yAt(t) - StageRunner.runnerHeight * .34) * s - size * .7;
      var i = n++;
      for (; i > 0 && _tagTops[i - 1] < top; i--) {
        _tagTops[i] = _tagTops[i - 1];
        _tagGhosts[i] = _tagGhosts[i - 1];
      }
      _tagTops[i] = top;
      _tagGhosts[i] = ghost;
    }
    if (n == 0) return;
    // Place all visible tags first so a fading saveLayer only allocates the
    // tight bounding box around the 1–3 labels instead of the whole stage column.
    var below = double.infinity;
    var minLeft = double.infinity, minTop = double.infinity;
    var maxRight = 0.0, maxBottom = 0.0;
    for (var i = 0; i < n; i++) {
      final ghost = _tagGhosts[i]!;
      final tag = _glyphs.tag(ghost.tag, size, ghost.rank);
      final top = min(_tagTops[i], below - tag.height);
      final left = cx - gap - tag.width;
      _tagPainters[i] = tag;
      _tagPlacedTops[i] = top;
      below = top;
      if (left < minLeft) minLeft = left;
      if (top < minTop) minTop = top;
      if (left + tag.width > maxRight) maxRight = left + tag.width;
      if (top + tag.height > maxBottom) maxBottom = top + tag.height;
      _tagGhosts[i] = null;
    }
    final fading = alpha < 1;
    if (fading) {
      _ghostTagLayer.color = _tagOpacities[(alpha * _ghostSteps).round()];
      canvas.saveLayer(
        Rect.fromLTRB(minLeft - 2, minTop - 2, maxRight + 2, maxBottom + 2),
        _ghostTagLayer,
      );
    }
    for (var i = 0; i < n; i++) {
      final tag = _tagPainters[i]!;
      tag.paint(canvas, Offset(cx - gap - tag.width, _tagPlacedTops[i]));
      _tagPainters[i] = null;
    }
    if (fading) canvas.restore();
  }

  void _plainRunner(Canvas canvas, StageRunner g, double s) {
    final cx = StageRunner.runnerX * s, cy = g.y * s;
    final h = StageRunner.runnerHeight * s, bw = StageRunner.runnerWidth * s;
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - h * .5), _ropePaint);
    final onFloor =
        g.y >= StageRunner.floor - StageRunner.runnerHeight / 2 - .001;
    final swing = onFloor && !g.over
        ? sin(g.distance * 40) * bw * .5
        : bw * .15;
    final hip = Offset(cx, cy + h * .15);
    canvas.drawLine(hip, Offset(cx + swing, cy + h * .5), _limbPaint);
    canvas.drawLine(hip, Offset(cx - swing, cy + h * .5), _limbPaint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy - h * .02),
          width: bw * .8,
          height: h * .42,
        ),
        Radius.circular(bw * .3),
      ),
      _bodyPaint,
    );
    canvas.drawCircle(Offset(cx, cy - h * .34), h * .14, _headPaint);
  }

  @override
  bool shouldRepaint(StageRunnerPainter old) =>
      old.pixelRatio != pixelRatio ||
      old.sceneryMotion() != sceneryMotion() ||
      old.reducedMotion() != reducedMotion();
}

/// Lightweight signal that marks the stage painter dirty without boxing or
/// comparing frame numbers every tick.
class _FrameSignal extends ChangeNotifier {
  void tick() => notifyListeners();
}

/// Zero-allocation batcher that collapses same-atlas uniform-scale sprites
/// (obstacles, pickups, rotated drums, runner poses) into a single
/// `Canvas.drawRawAtlas` call on Web/CanvasKit, eliminating per-sprite
/// `CkCanvas.drawImageRect` embind + `CkPaint.toSkPaint()` overhead.
class _SpriteBatch {
  static const _capacity = 64;

  final _transforms = Float32List(_capacity * 4);
  final _rects = Float32List(_capacity * 4);
  ui.Image? _image;
  Paint? _paint;
  int _count = 0;

  static bool _samePaint(Paint a, Paint b) =>
      identical(a, b) ||
      (a.colorFilter == b.colorFilter &&
          a.color == b.color &&
          a.filterQuality == b.filterQuality &&
          a.blendMode == b.blendMode);

  void addRect(
    Canvas canvas,
    ui.Image image,
    Rect src,
    Rect dst,
    Paint paint,
  ) {
    final sw = src.width, sh = src.height, dw = dst.width, dh = dst.height;
    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return;
    final sx = dw / sw, sy = dh / sh;
    // RSTransform encodes uniform scale + rotation; stretched slices fall back
    // to drawImageRect (which shares Skia's GrTextureOp GL shader).
    if ((sx - sy).abs() > 1e-3 * max(sx, sy)) {
      flush(canvas);
      canvas.drawImageRect(image, src, dst, paint);
      return;
    }
    if (_count > 0 &&
        (!identical(_image, image) ||
            !_samePaint(_paint!, paint) ||
            _count == _capacity)) {
      flush(canvas);
    }
    _image = image;
    _paint = paint;
    final o = _count * 4;
    _transforms[o] = (sx + sy) * .5;
    _transforms[o + 1] = 0;
    _transforms[o + 2] = dst.left;
    _transforms[o + 3] = dst.top;
    _rects[o] = src.left;
    _rects[o + 1] = src.top;
    _rects[o + 2] = src.right;
    _rects[o + 3] = src.bottom;
    _count++;
  }

  void addRotated(
    Canvas canvas,
    ui.Image image,
    Rect src,
    Offset center,
    double scale,
    double radians,
    Paint paint,
  ) {
    if (src.width <= 0 || src.height <= 0 || scale <= 0) return;
    if (_count > 0 &&
        (!identical(_image, image) ||
            !_samePaint(_paint!, paint) ||
            _count == _capacity)) {
      flush(canvas);
    }
    _image = image;
    _paint = paint;
    final scos = cos(radians) * scale;
    final ssin = sin(radians) * scale;
    final ax = src.width * .5;
    final ay = src.height * .5;
    final o = _count * 4;
    _transforms[o] = scos;
    _transforms[o + 1] = ssin;
    _transforms[o + 2] = center.dx - scos * ax + ssin * ay;
    _transforms[o + 3] = center.dy - ssin * ax - scos * ay;
    _rects[o] = src.left;
    _rects[o + 1] = src.top;
    _rects[o + 2] = src.right;
    _rects[o + 3] = src.bottom;
    _count++;
  }

  void flush(Canvas canvas) {
    final count = _count;
    if (count == 0) return;
    final n = count * 4;
    canvas.drawRawAtlas(
      _image!,
      Float32List.sublistView(_transforms, 0, n),
      Float32List.sublistView(_rects, 0, n),
      null,
      null,
      null,
      _paint!,
    );
    _count = 0;
    _image = null;
    _paint = null;
  }
}

/// Zero-allocation vertex batcher for circles, ovals, quads, rects and
/// triangles on Web/CanvasKit. Collapses pickup/crash particles, lamp beams,
/// sandbag shadows, warning markers, drum dust, ropes and velvet borders into
/// `Canvas.drawVertices` so mid-run bursts compile zero Circle/Oval shaders.
class _DiscBatch {
  static const _sides = 12;
  static const _maxVerts = 1024;
  static const _maxIndices = 3072;
  static final _unitX = Float32List.fromList([
    for (var i = 0; i < _sides; i++) cos(i * 2 * pi / _sides),
  ]);
  static final _unitY = Float32List.fromList([
    for (var i = 0; i < _sides; i++) sin(i * 2 * pi / _sides),
  ]);
  static final _paint = Paint();

  final _positions = Float32List(_maxVerts * 2);
  final _colors = Int32List(_maxVerts);
  final _indices = Uint16List(_maxIndices);
  int _vertCount = 0;
  int _indexCount = 0;

  void _ensure(Canvas canvas, int verts, int indices) {
    if (_vertCount + verts > _maxVerts || _indexCount + indices > _maxIndices) {
      flush(canvas);
    }
  }

  void addTriangle(
    Canvas canvas,
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    int argb,
  ) {
    _ensure(canvas, 3, 3);
    final v = _vertCount, p = v * 2, o = _indexCount;
    _positions[p] = x0;
    _positions[p + 1] = y0;
    _positions[p + 2] = x1;
    _positions[p + 3] = y1;
    _positions[p + 4] = x2;
    _positions[p + 5] = y2;
    _colors[v] = argb;
    _colors[v + 1] = argb;
    _colors[v + 2] = argb;
    _indices[o] = v;
    _indices[o + 1] = v + 1;
    _indices[o + 2] = v + 2;
    _vertCount = v + 3;
    _indexCount = o + 3;
  }

  void addQuad(
    Canvas canvas,
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    int argb,
  ) {
    _ensure(canvas, 4, 6);
    final v = _vertCount, p = v * 2, o = _indexCount;
    _positions[p] = x0;
    _positions[p + 1] = y0;
    _positions[p + 2] = x1;
    _positions[p + 3] = y1;
    _positions[p + 4] = x2;
    _positions[p + 5] = y2;
    _positions[p + 6] = x3;
    _positions[p + 7] = y3;
    _colors[v] = argb;
    _colors[v + 1] = argb;
    _colors[v + 2] = argb;
    _colors[v + 3] = argb;
    _indices[o] = v;
    _indices[o + 1] = v + 1;
    _indices[o + 2] = v + 2;
    _indices[o + 3] = v;
    _indices[o + 4] = v + 2;
    _indices[o + 5] = v + 3;
    _vertCount = v + 4;
    _indexCount = o + 6;
  }

  void addRect(
    Canvas canvas,
    double left,
    double top,
    double right,
    double bottom,
    int argb,
  ) {
    if (right <= left || bottom <= top) return;
    addQuad(canvas, left, top, right, top, right, bottom, left, bottom, argb);
  }

  void addOval(
    Canvas canvas,
    double cx,
    double cy,
    double rx,
    double ry,
    int argb,
  ) {
    if (rx <= 0 || ry <= 0) return;
    _ensure(canvas, _sides + 1, _sides * 3);
    final base = _vertCount;
    var p = base * 2;
    _positions[p++] = cx;
    _positions[p++] = cy;
    _colors[base] = argb;
    for (var i = 0; i < _sides; i++) {
      _positions[p++] = cx + _unitX[i] * rx;
      _positions[p++] = cy + _unitY[i] * ry;
      _colors[base + 1 + i] = argb;
    }
    var o = _indexCount;
    for (var i = 0; i < _sides; i++) {
      _indices[o++] = base;
      _indices[o++] = base + 1 + i;
      _indices[o++] = base + 1 + (i + 1 == _sides ? 0 : i + 1);
    }
    _vertCount = base + _sides + 1;
    _indexCount = o;
  }

  void addCircle(Canvas canvas, double cx, double cy, double r, int argb) =>
      addOval(canvas, cx, cy, r, r, argb);

  void flush(Canvas canvas) {
    if (_indexCount == 0) return;
    final verts = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_positions, 0, _vertCount * 2),
      colors: Int32List.sublistView(_colors, 0, _vertCount),
      indices: Uint16List.sublistView(_indices, 0, _indexCount),
    );
    canvas.drawVertices(verts, BlendMode.dst, _paint);
    verts.dispose();
    _vertCount = 0;
    _indexCount = 0;
  }
}

/// Flutter's CanvasKit [ui.ImageShader] keeps the passed [ui.Image] handle
/// without cloning it and disposes that handle in [ui.ImageShader.dispose]
/// (`CkImageShader.dispose`), unlike Skwasm and native engines. Passing a
/// cloned handle on CanvasKit keeps ownership uniform across all backends:
/// callers always retain their own [ui.Image] (e.g. a shared backdrop in
/// [RunnerArt] or [WardrobePictures]) and still dispose images they own (e.g.
/// [_BakedStrip]) without double-disposing.
const _imageShaderDisposesInput = kIsWeb && !kIsWasm;

ui.ImageShader _createImageShader(
  ui.Image image,
  TileMode tmx,
  TileMode tmy,
  Float64List matrix4, {
  FilterQuality? filterQuality,
}) => ui.ImageShader(
  _imageShaderDisposesInput ? image.clone() : image,
  tmx,
  tmy,
  matrix4,
  filterQuality: filterQuality,
);

/// Pre-baked repeating texture entry for a single periodic decoration strip.
class _BakedStrip {
  _BakedStrip(this.image, this.shader, this.paint, this.stripTop, this.stripH);
  final ui.Image image;
  final ui.ImageShader shader;
  final Paint paint;
  final double stripTop, stripH;

  void dispose() {
    paint.shader = null;
    shader.dispose();
    image.dispose();
  }
}

/// Layout metadata for one stall row packed inside [_DecorationCache._stallsAtlas].
class _StallRowInfo {
  const _StallRowInfo({
    required this.spacing,
    required this.period,
    required this.rowOffset,
    required this.stripTop,
    required this.srcLeft,
    required this.srcTop,
    required this.srcRight,
    required this.srcBottom,
  });
  final double spacing, period, rowOffset, stripTop;
  final double srcLeft, srcTop, srcRight, srcBottom;
}

/// Caches repeating decorative layers with zero per-frame allocations.
///
/// On native/VM (`rasterize == false`), small recorded vector [ui.Picture]
/// strips preserve exact vector edges at every pixel ratio without hash-map
/// churn or record allocations.
///
/// On the web (`rasterize == true`), curve-heavy periodic strips (stalls with
/// baked house bg/seat backs, front-row audience, valance scallops, drape folds
/// with baked fly-loft shade & gold trim, and floor planks) are pre-rasterized
/// once per viewport size into opaque GPU textures, while spotlight cones+pools
/// and wings are packed into static [ui.Vertices] meshes so WebGL/CanvasKit
/// renders the whole surround with zero overdraw and minimal GL program switches.
class _DecorationCache {
  _DecorationCache({required this.rasterize});
  final bool rasterize;

  static const _maxTexWidth = 2048;
  static const _spotOvalSides = 24;
  static final _spotCos = Float32List.fromList([
    for (var i = 0; i < _spotOvalSides; i++) cos(i * 2 * pi / _spotOvalSides),
  ]);
  static final _spotSin = Float32List.fromList([
    for (var i = 0; i < _spotOvalSides; i++) sin(i * 2 * pi / _spotOvalSides),
  ]);
  static final _tilePaint = Paint()..filterQuality = FilterQuality.low;
  static final _vertexPaint = Paint();
  static final _coneArgb = _beam.withValues(alpha: .045).toARGB32();
  static final _poolArgb = _beam.withValues(alpha: .07).toARGB32();

  Size? _size;
  double _pixelRatio = 1;
  double get _bakeScale => max(1.0, min(_pixelRatio, 2.0));

  // Vector strip caches (zero-allocation fixed slots).
  ui.Picture? _drapesPic;
  ui.Picture? _valancePic;
  ui.Picture? _spotlightsPic;
  ui.Picture? _wingsPic;
  ui.Picture? _floorPlanksPic;
  final _audiencePics = List<ui.Picture?>.filled(13, null);
  final _stallsPics = <List<ui.Picture?>>[];

  // Rasterized texture and vertex caches (used when [rasterize] is true).
  _BakedStrip? _drapesStrip;
  _BakedStrip? _valanceStrip;
  _BakedStrip? _audienceStrip;
  _BakedStrip? _floorStrip;
  ui.Image? _stallsAtlas;
  double _stallsAtlasInvScale = 1;
  List<_StallRowInfo> _stallRows = const [];
  Float32List? _stallsTransforms;
  Float32List? _stallsRects;
  ui.Vertices? _spotConesVertices;
  ui.Vertices? _wingsVertices;

  static Float64List scaleMatrix(double sx, double sy) {
    final m = Float64List(16);
    m[0] = sx;
    m[5] = sy;
    m[10] = 1;
    m[15] = 1;
    return m;
  }

  /// Rasterizes [pic] into a GPU texture and always disposes [pic]. Returns
  /// null (falling back to the vector strip path) if WebGL readback fails
  /// transiently (e.g. Safari context loss).
  static ui.Image? _tryToImageSync(ui.Picture pic, int width, int height) {
    try {
      return pic.toImageSync(width, height);
    } catch (_) {
      return null;
    } finally {
      pic.dispose();
    }
  }

  bool _rasterFailed = false;
  bool get _useRaster => rasterize && !_rasterFailed;

  void resize(Size size, double pixelRatio) {
    if (_size == size && _pixelRatio == pixelRatio) return;
    dispose();
    _size = size;
    _pixelRatio = pixelRatio;
  }

  /// Pre-bakes one slice of GPU textures / static vertex meshes for the active
  /// viewport size while the intro menu is idle.
  void prewarmStep(
    double s,
    double w,
    double top,
    double below,
    double floorY,
    int step,
  ) {
    if (!_useRaster) return;
    switch (step) {
      case 0:
        if (top > 0) _ensureDrapesStrip(s, top, -top - s * .05);
        _ensureValanceStrip(s);
      case 1:
        _ensureFloorStrip(s, floorY);
        _ensureWingsPic(s, w);
        _ensureSpotlightsPic(s, w, floorY);
      case 2:
        _ensureAudienceStrip(s);
      case 3:
        if (below > 0 && _stallsAtlas == null) {
          _bakeStallsAtlas(s, w, s + below + s * .05, s * .24);
        }
    }
  }

  _BakedStrip? _ensureDrapesStrip(double s, double top, double from) {
    final existing = _drapesStrip;
    if (existing != null) return existing;
    final period = s * .09;
    final drapeH = -from;
    if (period <= 0 || drapeH <= 0) return null;
    final scale = _bakeScale;
    final pw = max(1, (period * scale).round());
    final ph = min(_maxTexWidth, max(1, (drapeH * scale).ceil()));
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder)..scale(pw / period, ph / drapeH);
    c
      ..drawRect(
        Rect.fromLTRB(0, 0, period, drapeH),
        StageRunnerPainter._velvetPaint,
      )
      ..drawRect(
        Rect.fromLTRB(period * .12, 0, period * .3, drapeH),
        StageRunnerPainter._sheenPaint,
      )
      ..drawRect(
        Rect.fromLTRB(period * .55, 0, period * .85, drapeH),
        StageRunnerPainter._foldPaint,
      );
    if (top > s * .2) {
      // Matches original shade gradient from y = -top to y = -top * .4 in
      // strip-local coordinates (localY = y - from = y + top + s * .05).
      final shadeTop = s * .05;
      final shadeBottom = shadeTop + top * .6;
      final shade = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ).createShader(Rect.fromLTRB(0, shadeTop, 1, shadeBottom));
      c.drawRect(Rect.fromLTRB(0, 0, period, shadeBottom), shade);
    }
    c.drawRect(
      Rect.fromLTRB(0, drapeH - s * .012, period, drapeH - s * .004),
      StageRunnerPainter._goldPaint,
    );
    final img = _tryToImageSync(recorder.endRecording(), pw, ph);
    if (img == null) {
      _rasterFailed = true;
      return null;
    }
    final shader = _createImageShader(
      img,
      TileMode.repeated,
      TileMode.clamp,
      scaleMatrix(period / pw, drapeH / ph),
      filterQuality: FilterQuality.low,
    );
    return _drapesStrip = _BakedStrip(
      img,
      shader,
      Paint()..shader = shader,
      from,
      drapeH,
    );
  }

  /// Paints the upper house drapes; returns true when the rasterized strip
  /// already includes the fly-loft shade gradient and gold hem trim.
  bool paintDrapes(
    Canvas canvas,
    double s,
    double w,
    double top,
    double from,
    double scroll,
    bool shaking,
  ) {
    final period = s * .09;
    final shift = -(scroll % period);
    if (_useRaster) {
      final strip = _ensureDrapesStrip(s, top, from);
      if (strip != null) {
        final pad = shaking ? s * .02 : 0.0;
        canvas
          ..save()
          ..translate(shift, strip.stripTop)
          ..drawRect(
            Rect.fromLTRB(-shift - pad, 0, w - shift + pad, strip.stripH),
            strip.paint,
          )
          ..restore();
        return true;
      }
    }
    canvas.drawRect(
      Rect.fromLTRB(0, from, w, 0),
      StageRunnerPainter._velvetPaint,
    );
    var pic = _drapesPic;
    if (pic == null) {
      final count = (w / period).ceil() + 1;
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      for (var i = 0; i < count; i++) {
        final x = i * period;
        c
          ..drawRect(
            Rect.fromLTRB(x + period * .12, from, x + period * .3, 0),
            StageRunnerPainter._sheenPaint,
          )
          ..drawRect(
            Rect.fromLTRB(x + period * .55, from, x + period * .85, 0),
            StageRunnerPainter._foldPaint,
          );
      }
      pic = _drapesPic = recorder.endRecording();
    }
    canvas
      ..save()
      ..translate(shift, 0)
      ..drawPicture(pic)
      ..restore();
    return false;
  }

  _BakedStrip? _ensureValanceStrip(double s) {
    final existing = _valanceStrip;
    if (existing != null) return existing;
    final bottom = s * StageRunner.ceiling * .7, r = s * .03;
    final period = r * 2;
    final scale = _bakeScale;
    final pw = max(1, (period * scale).round());
    final ph = max(1, ((bottom + r) * scale).ceil() + 1);
    final actualH = ph / scale;
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder)..scale(pw / period, scale);
    c
      ..drawRect(
        Rect.fromLTRB(0, 0, period, bottom),
        StageRunnerPainter._velvetPaint,
      )
      ..drawCircle(Offset(0, bottom), r, StageRunnerPainter._velvetPaint)
      ..drawCircle(
        Offset(period, bottom),
        r,
        StageRunnerPainter._velvetPaint,
      )
      ..drawRect(
        Rect.fromLTRB(0, bottom - s * .01, period, bottom - s * .004),
        StageRunnerPainter._goldPaint,
      );
    final img = _tryToImageSync(recorder.endRecording(), pw, ph);
    if (img == null) {
      _rasterFailed = true;
      return null;
    }
    final shader = _createImageShader(
      img,
      TileMode.repeated,
      TileMode.clamp,
      scaleMatrix(period / pw, actualH / ph),
      filterQuality: FilterQuality.low,
    );
    return _valanceStrip = _BakedStrip(
      img,
      shader,
      Paint()..shader = shader,
      0,
      actualH,
    );
  }

  void paintValance(
    Canvas canvas,
    double s,
    double w,
    double scroll,
    bool shaking,
  ) {
    final bottom = s * StageRunner.ceiling * .7, r = s * .03;
    final period = r * 2;
    final shift = r - scroll % period;
    if (_useRaster) {
      final strip = _ensureValanceStrip(s);
      if (strip != null) {
        final pad = shaking ? s * .02 : 0.0;
        canvas
          ..save()
          ..translate(shift, 0)
          ..drawRect(
            Rect.fromLTRB(-shift - pad, 0, w - shift + pad, strip.stripH),
            strip.paint,
          )
          ..restore();
        return;
      }
    }
    canvas.drawRect(
      Rect.fromLTRB(0, 0, w, bottom),
      StageRunnerPainter._velvetPaint,
    );
    var pic = _valancePic;
    if (pic == null) {
      final count = (w / period).ceil() + 2;
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      for (var i = 0; i < count; i++) {
        c.drawCircle(
          Offset(i * period, bottom),
          r,
          StageRunnerPainter._velvetPaint,
        );
      }
      pic = _valancePic = recorder.endRecording();
    }
    canvas
      ..save()
      ..translate(shift, 0)
      ..drawPicture(pic)
      ..restore();
    canvas.drawRect(
      Rect.fromLTRB(0, bottom - s * .01, w, bottom - s * .004),
      StageRunnerPainter._goldPaint,
    );
  }

  _BakedStrip? _ensureAudienceStrip(double s) {
    final existing = _audienceStrip;
    if (existing != null) return existing;
    final spacing = s * .11;
    final period = 13 * spacing;
    final stripTop = s * .89;
    final stripH = s - stripTop;
    final scale = _bakeScale;
    final pw = min(_maxTexWidth, max(1, (period * scale).round()));
    final ph = max(1, (stripH * scale).ceil());
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder)..scale(pw / period, ph / stripH);
    // k = -1..13 wraps shoulders seamlessly across the 0 / period seam.
    for (var k = -1; k <= 13; k++) {
      final h = ((k % 13) * 7919) % 13;
      final r = s * (.034 + (h % 3) * .004);
      final x = k * spacing + (h % 5) * s * .004;
      final y = s * (.985 - (h % 4) * .006) - stripTop;
      c
        ..drawCircle(
          Offset(x, y - r * .6),
          r,
          StageRunnerPainter._crowdPaint,
        )
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(x, y + r * 1.2),
              width: r * 3.2,
              height: r * 2.2,
            ),
            Radius.circular(r),
          ),
          StageRunnerPainter._crowdPaint,
        );
    }
    final img = _tryToImageSync(recorder.endRecording(), pw, ph);
    if (img == null) {
      _rasterFailed = true;
      return null;
    }
    final shader = _createImageShader(
      img,
      TileMode.repeated,
      TileMode.clamp,
      scaleMatrix(period / pw, stripH / ph),
      filterQuality: FilterQuality.low,
    );
    return _audienceStrip = _BakedStrip(
      img,
      shader,
      Paint()..shader = shader,
      stripTop,
      stripH,
    );
  }

  void paintAudience(
    Canvas canvas,
    double s,
    double w,
    double scroll,
    bool shaking,
  ) {
    final spacing = s * .11;
    if (_useRaster) {
      final strip = _ensureAudienceStrip(s);
      if (strip != null) {
        final period = 13 * spacing;
        final shift = -(scroll % period);
        final pad = shaking ? s * .02 : 0.0;
        canvas
          ..save()
          ..translate(shift, strip.stripTop)
          ..drawRect(
            Rect.fromLTRB(-shift - pad, 0, w - shift + pad, strip.stripH),
            strip.paint,
          )
          ..restore();
        return;
      }
    }
    final first = (scroll / spacing).floor() - 1;
    final phase = first % 13;
    var pic = _audiencePics[phase];
    if (pic == null) {
      final count = (w / spacing).ceil() + 3;
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      for (var i = 0; i < count; i++) {
        final h = ((phase + i) * 7919) % 13;
        final r = s * (.034 + (h % 3) * .004);
        final x = i * spacing + (h % 5) * s * .004;
        final y = s * (.985 - (h % 4) * .006);
        c
          ..drawCircle(Offset(x, y - r * .6), r, StageRunnerPainter._crowdPaint)
          ..drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(x, y + r * 1.2),
                width: r * 3.2,
                height: r * 2.2,
              ),
              Radius.circular(r),
            ),
            StageRunnerPainter._crowdPaint,
          );
      }
      pic = _audiencePics[phase] = recorder.endRecording();
    }
    canvas
      ..save()
      ..translate(first * spacing - scroll, 0)
      ..drawPicture(pic)
      ..restore();
  }

  void paintStalls(
    Canvas canvas,
    double s,
    double w,
    double below,
    double scroll,
    bool shaking,
  ) {
    final bottom = s + below + s * .05, gap = s * .24;
    if (_useRaster) {
      if (_stallsAtlas == null) _bakeStallsAtlas(s, w, bottom, gap);
      final atlas = _stallsAtlas;
      final rows = _stallRows;
      if (atlas != null && rows.isNotEmpty) {
        final pad = shaking ? s * .02 : 0.0;
        final invScale = _stallsAtlasInvScale;
        final transforms = _stallsTransforms!;
        final rects = _stallsRects!;
        final maxSprites = transforms.length ~/ 4;
        var count = 0;
        for (var i = 0; i < rows.length; i++) {
          final info = rows[i];
          final period = info.period;
          final start = -((scroll + info.rowOffset) % period);
          for (var tx = start; tx < w + pad; tx += period) {
            if (tx + period <= -pad) continue;
            if (count >= maxSprites) break;
            final o = count * 4;
            transforms[o] = invScale;
            transforms[o + 1] = 0;
            transforms[o + 2] = tx;
            transforms[o + 3] = info.stripTop;
            rects[o] = info.srcLeft;
            rects[o + 1] = info.srcTop;
            rects[o + 2] = info.srcRight;
            rects[o + 3] = info.srcBottom;
            count++;
          }
        }
        if (count > 0) {
          canvas.drawRawAtlas(
            atlas,
            Float32List.sublistView(transforms, 0, count * 4),
            Float32List.sublistView(rects, 0, count * 4),
            null,
            null,
            null,
            _tilePaint,
          );
        }
        return;
      }
    }
    canvas.drawRect(
      Rect.fromLTRB(0, s, w, bottom),
      StageRunnerPainter._housePaint,
    );
    // The first row right below the stage's edge, so even a thin strip of
    // stalls shows heads.
    for (var row = 1; s + (row - 1) * gap < bottom; row++) {
      final grow = 1 + row * .05, y = s + (row - .65) * gap;
      final spacing = s * .16 * grow, shift = scroll + row * spacing * .5;
      final rowIdx = row - 1;
      final first = (shift / spacing).floor() - 1;
      final phase = first % 13;
      while (_stallsPics.length <= rowIdx) {
        _stallsPics.add(List<ui.Picture?>.filled(13, null));
      }
      final rowPics = _stallsPics[rowIdx];
      var pic = rowPics[phase];
      if (pic == null) {
        final count = (w / spacing).ceil() + 3;
        final recorder = ui.PictureRecorder();
        final c = Canvas(recorder);
        for (var i = 0; i < count; i++) {
          final h = ((phase + i) * 7919 + row * 104729) % 13;
          if (h == 4) continue;
          final r = s * (.03 + (h % 3) * .004) * grow;
          final x = i * spacing + (h % 5) * s * .006;
          final head = y - r * (1.9 + (h % 4) * .1);
          c
            ..drawCircle(Offset(x, head), r, StageRunnerPainter._crowdPaint)
            ..drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromCenter(
                  center: Offset(x, head + r * 1.8),
                  width: r * 3.1,
                  height: r * 2.2,
                ),
                Radius.circular(r),
              ),
              StageRunnerPainter._crowdPaint,
            );
        }
        pic = rowPics[phase] = recorder.endRecording();
      }
      canvas
        ..save()
        ..translate(first * spacing - shift, 0)
        ..drawPicture(pic)
        ..restore();
      // The backs of the seats in front hide the shoulders.
      canvas
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(-s, y, w + s, y + gap * .32),
            Radius.circular(s * .02),
          ),
          StageRunnerPainter._seatPaint,
        )
        ..drawRect(
          Rect.fromLTRB(0, y, w, y + s * .006),
          StageRunnerPainter._seatEdgePaint,
        );
    }
  }

  /// Packs all stall rows — including opaque house background, silhouettes,
  /// seat backs and velvet trim — into contiguous non-overlapping bands in one
  /// GPU atlas with 1 px wrapped gutters on every side so [paintStalls] draws
  /// the entire lower house in one `drawRawAtlas` call with zero overdraw.
  void _bakeStallsAtlas(double s, double w, double bottom, double gap) {
    var rowCount = 0;
    var maxPeriod = 0.0;
    for (var row = 1; s + (row - 1) * gap < bottom; row++) {
      rowCount++;
      final period = 13 * s * .16 * (1 + row * .05);
      if (period > maxPeriod) maxPeriod = period;
    }
    if (rowCount == 0 || maxPeriod <= 0) {
      _stallRows = const [];
      return;
    }
    final lastSeatBottom = s + (rowCount - .33) * gap;
    final totalH = max(1.0, max(bottom, lastSeatBottom) - s);
    final atlasScale = min(
      _bakeScale,
      min(
        (_maxTexWidth - 4) / maxPeriod,
        (_maxTexWidth - rowCount * 4) / totalH,
      ),
    );
    if (atlasScale <= 0) {
      _stallRows = const [];
      return;
    }
    _stallsAtlasInvScale = 1 / atlasScale;
    final atlasW = min(_maxTexWidth, max(3, (maxPeriod * atlasScale).ceil() + 3));

    final rows = <_StallRowInfo>[];
    final rowSpecs = <(int, double, double, double, double, double, int, int)>[];
    var cursorY = 0;
    var minPeriod = double.infinity;
    var prevRowBottom = s;
    for (var row = 1; row <= rowCount; row++) {
      final grow = 1 + row * .05, y = s + (row - .65) * gap;
      final spacing = s * .16 * grow;
      final period = 13 * spacing;
      if (period < minPeriod) minPeriod = period;
      final seatBottom = y + gap * .32;
      final rowTop = row == 1 ? s : prevRowBottom;
      final rowBottom = row == rowCount ? max(bottom, seatBottom) : seatBottom;
      final rowH = max(1 / atlasScale, rowBottom - rowTop);
      final rowPxH = max(1, (rowH * atlasScale).ceil());
      rowSpecs.add((row, grow, y, spacing, rowTop, rowH, cursorY, rowPxH));
      rows.add(
        _StallRowInfo(
          spacing: spacing,
          period: period,
          rowOffset: row * spacing * .5,
          stripTop: rowTop,
          srcLeft: 1.0,
          srcTop: (cursorY + 1).toDouble(),
          srcRight: 1.0 + period * atlasScale,
          srcBottom: (cursorY + 1) + rowH * atlasScale,
        ),
      );
      cursorY += rowPxH + 3;
      prevRowBottom = rowBottom;
    }
    final atlasH = max(3, cursorY);

    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    final padWorld = 2 / atlasScale;
    for (final (row, grow, y, spacing, rowTop, rowH, yPx, hPx) in rowSpecs) {
      final period = 13 * spacing;
      final seatY = y - rowTop;
      final seatBottomY = seatY + gap * .32;
      final bandClipW = min(
        atlasW.toDouble(),
        (period * atlasScale).ceilToDouble() + 2,
      );
      // Clip to [0 .. bandClipW] × [yPx .. yPx + hPx + 2] so top/bottom/left/
      // right 1 px bilinear gutters are filled with opaque band colors.
      c
        ..save()
        ..clipRect(
          Rect.fromLTWH(0, yPx.toDouble(), bandClipW, (hPx + 2).toDouble()),
          doAntiAlias: false,
        )
        ..translate(1.0, (yPx + 1).toDouble())
        ..scale(atlasScale, atlasScale)
        ..drawRect(
          Rect.fromLTRB(-padWorld, -padWorld, period + padWorld, rowH + padWorld),
          StageRunnerPainter._housePaint,
        );
      for (var k = -1; k <= 13; k++) {
        final h = ((k % 13) * 7919 + row * 104729) % 13;
        if (h == 4) continue;
        final r = s * (.03 + (h % 3) * .004) * grow;
        final x = k * spacing + (h % 5) * s * .006;
        final head = seatY - r * (1.9 + (h % 4) * .1);
        c
          ..drawCircle(Offset(x, head), r, StageRunnerPainter._crowdPaint)
          ..drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(x, head + r * 1.8),
                width: r * 3.1,
                height: r * 2.2,
              ),
              Radius.circular(r),
            ),
            StageRunnerPainter._crowdPaint,
          );
      }
      // Extend the seat back into the bottom gutter when it sits at the row's
      // bottom edge so bilinear sampling never pulls house bg across the seam.
      final extSeatBottom = seatBottomY >= rowH - 1e-3
          ? rowH + padWorld
          : seatBottomY;
      c
        ..drawRect(
          Rect.fromLTRB(-padWorld, seatY, period + padWorld, extSeatBottom),
          StageRunnerPainter._seatPaint,
        )
        ..drawRect(
          Rect.fromLTRB(-padWorld, seatY, period + padWorld, seatY + s * .006),
          StageRunnerPainter._seatEdgePaint,
        )
        ..restore();
    }
    final img = _tryToImageSync(recorder.endRecording(), atlasW, atlasH);
    if (img == null) {
      _rasterFailed = true;
      return;
    }
    _stallsAtlas = img;
    _stallRows = rows;

    final maxPerRow = (w / minPeriod).ceil() + 3;
    final maxSprites = rowCount * maxPerRow;
    _stallsTransforms = Float32List(maxSprites * 4);
    _stallsRects = Float32List(maxSprites * 4);
  }

  ui.Picture _ensureSpotlightsPic(double s, double w, double floorY) {
    final existing = _spotlightsPic;
    if (existing != null) return existing;
    final period = s * .72;
    final startX = s * .48 - period;
    final endX = w + s * .25 + period;
    var count = 0;
    for (var x = startX; x < endX; x += period) {
      count++;
    }
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    if (_useRaster && count > 0) {
      // Pack both spotlight cones and 24-gon floor pools into a single
      // vertex-colored mesh so spotlights emit 1 drawVertices call, zero
      // textures, and share Skia's GrFillVerticesOp GL program with _wings.
      const vertsPerSpot = 4 + _spotOvalSides + 1;
      const idxPerSpot = 6 + _spotOvalSides * 3;
      final pos = Float32List(count * vertsPerSpot * 2);
      final colors = Int32List(count * vertsPerSpot);
      final idx = Uint16List(count * idxPerSpot);
      final rx = s * .23, ry = s * .03, cy = floorY + s * .02;
      final coneColor = _coneArgb, poolColor = _poolArgb;
      var v = 0, p = 0, o = 0;
      for (var i = 0; i < count; i++) {
        final x = startX + i * period;
        // Cone trapezoid.
        final cv = v;
        pos[p++] = x - s * .02;
        pos[p++] = 0;
        pos[p++] = x + s * .02;
        pos[p++] = 0;
        pos[p++] = x + s * .22;
        pos[p++] = floorY;
        pos[p++] = x - s * .22;
        pos[p++] = floorY;
        colors[v++] = coneColor;
        colors[v++] = coneColor;
        colors[v++] = coneColor;
        colors[v++] = coneColor;
        idx[o++] = cv;
        idx[o++] = cv + 1;
        idx[o++] = cv + 2;
        idx[o++] = cv;
        idx[o++] = cv + 2;
        idx[o++] = cv + 3;
        // Floor oval fan.
        final ov = v;
        pos[p++] = x;
        pos[p++] = cy;
        colors[v++] = poolColor;
        for (var k = 0; k < _spotOvalSides; k++) {
          pos[p++] = x + _spotCos[k] * rx;
          pos[p++] = cy + _spotSin[k] * ry;
          colors[v++] = poolColor;
        }
        for (var k = 0; k < _spotOvalSides; k++) {
          idx[o++] = ov;
          idx[o++] = ov + 1 + k;
          idx[o++] = ov + 1 + (k + 1 == _spotOvalSides ? 0 : k + 1);
        }
      }
      _spotConesVertices?.dispose();
      final verts = _spotConesVertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        pos,
        colors: colors,
        indices: idx,
      );
      c.drawVertices(verts, BlendMode.dst, _vertexPaint);
    } else {
      final path = Path();
      for (var i = 0; i < count; i++) {
        final x = startX + i * period;
        path
          ..reset()
          ..moveTo(x - s * .02, 0)
          ..lineTo(x + s * .02, 0)
          ..lineTo(x + s * .22, floorY)
          ..lineTo(x - s * .22, floorY)
          ..close();
        c
          ..drawPath(path, StageRunnerPainter._conePaint)
          ..drawOval(
            Rect.fromCenter(
              center: Offset(x, floorY + s * .02),
              width: s * .46,
              height: s * .06,
            ),
            StageRunnerPainter._poolPaint,
          );
      }
    }
    return _spotlightsPic = recorder.endRecording();
  }

  void paintSpotlights(
    Canvas canvas,
    double s,
    double w,
    double floorY,
    double scroll,
  ) {
    final period = s * .72;
    final shift = -(scroll % period);
    final pic = _ensureSpotlightsPic(s, w, floorY);
    canvas
      ..save()
      ..translate(shift, 0)
      ..drawPicture(pic)
      ..restore();
  }

  ui.Picture _ensureWingsPic(double s, double w) {
    final existing = _wingsPic;
    if (existing != null) return existing;
    const width = .07;
    final period = s * .51;
    final top = s * .05, bottom = s * StageRunner.floor;
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    if (_useRaster) {
      // Split each wing into 5 disjoint vertical bands in one static vertex
      // mesh: zero overdraw, zero textures, same GL program as _spotlights.
      var count = 0;
      for (var left = 0.0; left < w + period; left += period) {
        count++;
      }
      if (count > 0) {
        const bands = 5;
        const stops = [0.0, .012, .024, .042, .054, width];
        const bandColors = [
          StageRunnerPainter._velvetArgb,
          StageRunnerPainter._velvetDarkArgb,
          StageRunnerPainter._velvetArgb,
          StageRunnerPainter._velvetDarkArgb,
          StageRunnerPainter._velvetArgb,
        ];
        final pos = Float32List(count * bands * 8);
        final colors = Int32List(count * bands * 4);
        final idx = Uint16List(count * bands * 6);
        var v = 0, p = 0, o = 0;
        for (var i = 0; i < count; i++) {
          final left = i * period;
          for (var b = 0; b < bands; b++) {
            final l = left + s * stops[b];
            final r = left + s * stops[b + 1];
            final col = bandColors[b];
            final base = v;
            pos[p++] = l;
            pos[p++] = top;
            pos[p++] = r;
            pos[p++] = top;
            pos[p++] = r;
            pos[p++] = bottom;
            pos[p++] = l;
            pos[p++] = bottom;
            colors[v++] = col;
            colors[v++] = col;
            colors[v++] = col;
            colors[v++] = col;
            idx[o++] = base;
            idx[o++] = base + 1;
            idx[o++] = base + 2;
            idx[o++] = base;
            idx[o++] = base + 2;
            idx[o++] = base + 3;
          }
        }
        _wingsVertices?.dispose();
        final verts = _wingsVertices = ui.Vertices.raw(
          ui.VertexMode.triangles,
          pos,
          colors: colors,
          indices: idx,
        );
        c.drawVertices(verts, BlendMode.dst, _vertexPaint);
      }
    } else {
      for (var left = 0.0; left < w + period; left += period) {
        c
          ..drawRect(
            Rect.fromLTRB(left, top, left + s * width, bottom),
            StageRunnerPainter._velvetPaint,
          )
          ..drawRect(
            Rect.fromLTRB(left + s * .012, top, left + s * .024, bottom),
            StageRunnerPainter._foldPaint,
          )
          ..drawRect(
            Rect.fromLTRB(left + s * .042, top, left + s * .054, bottom),
            StageRunnerPainter._foldPaint,
          );
      }
    }
    return _wingsPic = recorder.endRecording();
  }

  void paintWings(Canvas canvas, double s, double w, double scroll) {
    final period = s * .51;
    final shift = -(scroll % period);
    final pic = _ensureWingsPic(s, w);
    canvas
      ..save()
      ..translate(shift, 0)
      ..drawPicture(pic)
      ..restore();
  }

  _BakedStrip? _ensureFloorStrip(double s, double floorY) {
    final existing = _floorStrip;
    if (existing != null) return existing;
    final period = s * .25;
    final stripTop = floorY - 1.0;
    final stripH = (s - floorY) + 2.0;
    if (period <= 0 || stripH <= 0) return null;
    final scale = _bakeScale;
    final pw = max(1, (period * scale).round());
    final ph = max(1, (stripH * scale).ceil());
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder)..scale(pw / period, ph / stripH);
    final plankBottom = 1.0 + (s - floorY);
    c
      ..drawRect(
        Rect.fromLTRB(0, 1.0, period, stripH),
        StageRunnerPainter._floorPaint,
      )
      ..save()
      ..clipRect(Rect.fromLTRB(0, 1.0, period, stripH), doAntiAlias: false)
      ..drawLine(
        const Offset(0, 1.0),
        Offset(-s * .04, plankBottom),
        StageRunnerPainter._plankPaint,
      )
      ..drawLine(
        Offset(period, 1.0),
        Offset(period - s * .04, plankBottom),
        StageRunnerPainter._plankPaint,
      )
      ..restore()
      ..drawLine(
        const Offset(0, 1.0),
        Offset(period, 1.0),
        StageRunnerPainter._edgePaint,
      );
    final img = _tryToImageSync(recorder.endRecording(), pw, ph);
    if (img == null) {
      _rasterFailed = true;
      return null;
    }
    final shader = _createImageShader(
      img,
      TileMode.repeated,
      TileMode.clamp,
      scaleMatrix(period / pw, stripH / ph),
      filterQuality: FilterQuality.low,
    );
    return _floorStrip = _BakedStrip(
      img,
      shader,
      Paint()..shader = shader,
      stripTop,
      stripH,
    );
  }

  /// Paints the stage floor (fill + diagonal planks + top edge trim) in one
  /// repeating textured quad on Web; returns false to fall back to vectors.
  bool paintFloor(
    Canvas canvas,
    double s,
    double w,
    double floorY,
    double scroll,
    bool shaking,
  ) {
    if (!_useRaster) return false;
    final strip = _ensureFloorStrip(s, floorY);
    if (strip == null) return false;
    final period = s * .25;
    final shift = -(scroll % period);
    final pad = shaking ? s * .02 : 0.0;
    canvas
      ..save()
      ..translate(shift, strip.stripTop)
      ..drawRect(
        Rect.fromLTRB(-shift - pad, 0, w - shift + pad, strip.stripH),
        strip.paint,
      )
      ..restore();
    return true;
  }

  void paintFloorPlanks(
    Canvas canvas,
    double s,
    double w,
    double floorY,
    double scroll,
  ) {
    final period = s * .25;
    final shift = -(scroll % period);
    var pic = _floorPlanksPic;
    if (pic == null) {
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      for (var x = 0.0; x < w + s * .04 + period; x += period) {
        c.drawLine(
          Offset(x, floorY),
          Offset(x - s * .04, s),
          StageRunnerPainter._plankPaint,
        );
      }
      pic = _floorPlanksPic = recorder.endRecording();
    }
    canvas
      ..save()
      ..translate(shift, 0)
      ..drawPicture(pic)
      ..restore();
  }

  void dispose() {
    _drapesPic?.dispose();
    _drapesPic = null;
    _valancePic?.dispose();
    _valancePic = null;
    _spotlightsPic?.dispose();
    _spotlightsPic = null;
    _wingsPic?.dispose();
    _wingsPic = null;
    _floorPlanksPic?.dispose();
    _floorPlanksPic = null;
    for (var i = 0; i < _audiencePics.length; i++) {
      _audiencePics[i]?.dispose();
      _audiencePics[i] = null;
    }
    for (final row in _stallsPics) {
      for (final pic in row) {
        pic?.dispose();
      }
    }
    _stallsPics.clear();
    _drapesStrip?.dispose();
    _drapesStrip = null;
    _valanceStrip?.dispose();
    _valanceStrip = null;
    _audienceStrip?.dispose();
    _audienceStrip = null;
    _floorStrip?.dispose();
    _floorStrip = null;
    _stallsAtlas?.dispose();
    _stallsAtlas = null;
    _stallRows = const [];
    _stallsTransforms = null;
    _stallsRects = null;
    _spotConesVertices?.dispose();
    _spotConesVertices = null;
    _wingsVertices?.dispose();
    _wingsVertices = null;
    _rasterFailed = false;
    _size = null;
  }
}
