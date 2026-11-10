import 'dart:async';
import 'dart:math';
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
  bool _systemReducedMotion = false, _settingsOpen = false;

  late final RunnerMenuPreferences _menu =
      widget.menuPreferences ?? RunnerMenuPreferences();

  bool get _sceneryMotion =>
      _motion.ready && _motion.sceneryMotion && !_systemReducedMotion;

  /// The wardrobe, if the server offers it, and the progress after the last
  /// run.
  Wardrobe? _wardrobe;
  RunnerProgress? _progress;

  /// The day's Tagesmissionen (`runnerMissions`), the watch of the current
  /// run and its banner when the run makes one.
  DailyMissions? _missions;
  MissionWatch? _watch;
  final _missionBanner = ValueNotifier<DailyMission?>(null);
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
  final _frame = ValueNotifier<int>(0);
  final _hud = ValueNotifier<(int, int)>((0, 0));
  int _pointers = 0;

  /// Increases with every run, so late server replies of an earlier run are
  /// ignored.
  int _run = 0;
  Future<String?>? _start;
  Leaderboard? _board;
  String? _boardError, _saveError;
  bool _loadingBoard = false, _saving = false, _improved = false;

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

  /// The stage's size in this run, and whether the run waits for a tap
  /// after the size changed (see [_resized]).
  Size? _stageSize;
  bool _paused = false;

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
    _lifecycle = AppLifecycleListener(
      // Control Center, a call or another app in front: the run waits for a
      // tap, as after a new size, instead of flying on unsteered (a ranked
      // attempt of the Wochenprobe has no second try).
      onInactive: _pauseRun,
      onHide: () {
        if (_pauseRun()) return;
        if (_sound case final RunnerMusic music) music.pauseMusic();
      },
      onShow: () {
        if (_paused) return;
        if (_sound case final RunnerMusic music) music.resumeMusic();
      },
    );
    if (_ranked) {
      _loadBoard();
      if (_monthShown) unawaited(_loadMonthly());
      // Results that found no connection earlier in this session.
      unawaited(runnerScoreOutbox(controller).retry());
    }
    if (_collectionShown) _loadCollection();
    if (_weeklyShown) unawaited(_loadWeekly());
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

  /// Shows the newest entry of "Neu im Bühnenlauf" not seen on this device,
  /// once the menu is free: not during a run, nor over another dialog or
  /// page. It counts as seen as soon as it shows.
  Future<bool> _offerNews() async {
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
    final action = await showRunnerNews(context, pending.news);
    if (!mounted || _phase != _Phase.intro) return false;
    switch (action) {
      case RunnerNewsAction.weekly:
        unawaited(_openWeekly());
        return true;
      case null:
        return false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (_systemReducedMotion != reduced) {
      _systemReducedMotion = reduced;
      _frame.value++;
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
      _frame.value++;
    }
  }

  void _motionChanged() {
    if (!mounted) return;
    setState(() {});
    // The painter is kept across builds; a paused stage needs a repaint too.
    _frame.value++;
  }

  Future<void> _showSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    if (_phase == _Phase.playing && !_paused) {
      setState(() => _paused = true);
      _pointers = 0;
      _ticker.stop();
      if (_sound case final RunnerMusic music) music.pauseMusic();
    }
    String? saveError;
    var saveRequest = 0;
    final ghosts = _weeklyShown;
    final volumes = _sound is RunnerVolumes ? _sound as RunnerVolumes : null;
    // More than the scenery's motion: a section each.
    final sections = ghosts || volumes != null;
    // Turning a volume in the pause of a run lets the run's sound be heard
    // while the dialog is open (the music at its new volume, the effects'
    // preview; in browsers both wait in the one held audio context). It
    // holds again once the dialog closes, until the tap that runs on.
    var heard = false;
    void hear() {
      if (heard || _phase != _Phase.playing || !_paused) return;
      heard = true;
      if (_sound case final RunnerMusic music) music.resumeMusic();
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
                          onAdjust: hear,
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
    if (heard && mounted && _phase == _Phase.playing && _paused) {
      if (_sound case final RunnerMusic music) music.pauseMusic();
    }
    // An interrupted run stays paused until the player taps the stage.
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
        await celebrateGala(
          context,
          controller: controller,
          wardrobe: w,
          sound: _sound,
          onChanged: (next) {
            if (mounted) setState(() => _wardrobe = next);
          },
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Garderobe nicht geladen: $e');
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

  Future<void> _openWardrobe() async {
    var changed = false;
    final worn = _wardrobe;
    await openWardrobe(
      context,
      controller,
      wardrobe: worn,
      dressed: worn != null && outfitOf(worn) == _outfit ? _art : null,
      sound: _sound,
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
    _frame.dispose();
    _hud.dispose();
    _missionBanner.dispose();
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
      // The page shows last week's reward (once): the entry stops pointing
      // to it, also when the page is left for a run.
      onLoaded: (week) {
        if (mounted) setState(() => _weekly = week.withoutLastWeek());
      },
    );
    if (!mounted) return;
    if (play != null) {
      _play(play);
    } else if (_phase != _Phase.playing) {
      // A reward seen there leaves the entry.
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
      _ghostSkins = GhostSkins(controller, onLoaded: () => _frame.value++)
        ..want(ghosts.wanted, _art);
    }
    final perf = _perf = RunnerPerf(
      game,
      curtainStart: _curtainStart,
      sound: () => _sound.enabled.value,
    );
    final fx = _fx = RunnerFx(
      // Training counts for no list: no record to break.
      best: weekly == null
          ? _knownBest
          : weekly.ranked
          ? _knownWeeklyBest(weekly.challenge)
          : null,
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
    _hud.value = (0, 0);
    _pointers = 0;
    _heldOver.clear();
    _saveError = null;
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
          setState(() => _saveError = userMessage(e));
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

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastFrame).inMicroseconds / 1e6;
    _lastFrame = elapsed;
    _perf?.step(dt);
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    _game
      ..holding = _pointers > 0 || keys.any(_holdKeys.contains)
      ..update(dt);
    _recorder?.record(_game);
    _fx.update(dt, _game);
    _trail.update(dt, _game, _art?.effect);
    _perf?.observe();
    if (_watch?.check(_game) case final made?) {
      _missionBanner.value = made;
      _bannerUntil = _game.time + 2.5;
    } else if (_missionBanner.value != null && _game.time > _bannerUntil) {
      _missionBanner.value = null;
    }
    _frame.value++;
    final hud = (_game.score, _game.meters);
    if (hud != _hud.value) _hud.value = hud;
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

  /// The best score of this visit's normal runs that went to the server.
  /// The list ([_board]) knows a run only once its result is back, which a
  /// quick "Nochmal" does not wait for (and a result in the outbox may take
  /// long): the next run would break the old record once more.
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

  /// Hold keys that were still down when the run ended. Their repeats must
  /// not press the focused button of the result ("Nochmal"): whoever still
  /// holds the space bar would skip the result and fly on at once.
  final _heldOver = <LogicalKeyboardKey>{};

  KeyEventResult _menuKey(FocusNode node, KeyEvent event) {
    if (_heldOver.isEmpty) return KeyEventResult.ignored;
    if (event is KeyRepeatEvent) {
      return _heldOver.contains(event.logicalKey)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    // Let go, or pressed afresh (its release went elsewhere): from now on
    // the key acts as usual.
    _heldOver.remove(event.logicalKey);
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
        return;
      }
      // A weekly run counts for its own ranking only.
      final improved = weekly == null
          ? result.improved
          : weekly.ranked && (result.weekly?.improved ?? false);
      // The fanfare, unless it already played when the record fell.
      if (improved && !_fx.recordBroken) {
        _sound.play(RunnerSfx.record);
      } else if ((result.progress?.newCrates ?? 0) > 0) {
        _sound.play(RunnerSfx.reveal);
      }
      if (result.progress?.missions?.justCompletedAll ?? false) {
        _sound.play(RunnerSfx.jackpot);
      }
      setState(() {
        _improved = improved;
        _weeklyResult = result.weekly;
        _progress = result.progress;
        if (result.progress?.missions case final m?) _missions = m;
        _board = result.leaderboard;
        _boardError = null;
      });
      // The run may have moved the own place in this month's list, or in
      // this week's.
      if (weekly != null) {
        unawaited(_loadWeekly());
      } else if (monthlyBoardAvailable(controller)) {
        unawaited(_loadMonthly());
      }
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
    if (!_holdKeys.contains(event.logicalKey)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _resume();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final phone = runnerCoversRail(MediaQuery.sizeOf(context));
    final scaffold = Scaffold(
      appBar: AppBar(
        title: const Text('Bühnenlauf'),
        actions: [
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
              onPressed: () => _sound.setEnabled(!on),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AnnotatedRegion(
        value: _phase == _Phase.playing ? runnerBarsPlaying : runnerBarsDefault,
        child: switch (_phase) {
          _Phase.playing => Focus(
            autofocus: true,
            onKeyEvent: _key,
            child: _stage(context),
          ),
          // Its own key: not the stage's focus node kept for the menu.
          _ => Focus(
            key: const ValueKey('runner-menu-keys'),
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _menuKey,
            child: _menuBody(context),
          ),
        },
      ),
    );
    // On phones the game covers the section rail the route frame would
    // show beside it once the phone is turned (see [runnerCoversRail]).
    final controller = AppNavigationScope.controllerOf(context);
    final selection = AppNavigationScope.maybeOf(context);
    if (controller == null || selection == null) return scaffold;
    return DesktopRouteFrame(
      controller: controller,
      selectedIndex: selection.value,
      enabled: !phone,
      child: scaffold,
    );
  }

  /// The menu before and after a run: the countdown to a content drop less
  /// than a day away, the hero (or the last run's result), then the own
  /// standing, the Ensemble-Strecke, the rankings and the Tagesmissionen.
  /// Wide enough, the hero stays on the left and the rest scrolls beside it.
  Widget _menuBody(BuildContext context) {
    final lead = _phase == _Phase.intro ? _hero(context) : _result(context);
    // The drop countdown comes first: above the hero on phones, on top of
    // the column beside it on wide screens.
    final drop = _nextDropCard();
    final rest = [
      if (_weeklyShown) _weeklyCard(),
      ?_stand(context),
      ?_ensembleStrip(),
      _ranking(context),
      if (_missionsOn && (_phase == _Phase.intro || _missions != null))
        _missionsCard(),
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

  /// The worn figure and the big start.
  Widget _hero(BuildContext context) {
    final name = _wardrobe?.wornCharacterName() ?? 'Engel Logge';
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
      note: _bonusOpen ? _dailyBonusHint(context, onDark: true) : null,
      wardrobe: _dressable
          ? WardrobeButton(
              crates: _wardrobe?.progress.waiting ?? 0,
              onPressed: _openWardrobe,
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
      nextCrate: next,
      nextCrateFraction: next == null || p!.complete ? null : p.fraction,
      onWardrobe: _dressable ? _openWardrobe : null,
    );
  }

  /// The countdown to the next content drop, while one is less than a day
  /// away (`nextDrop`).
  Widget? _nextDropCard() {
    final drop = _wardrobe?.nextDrop;
    if (drop == null || !_dressable) return null;
    return NextDropCard(drop: drop, onDue: _reloadWardrobe);
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
  Widget _missionsCard() => DailyMissionsCard(
    controller: controller,
    missions: _missions,
    collectibleNames: _pickupNames,
    onChanged: (m) {
      if (mounted) setState(() => _missions = m);
    },
  );

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
      if (play.ranked && used > 0 && !_saving) ...[
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
              : _improved
              ? 'Neuer Wochenbestwert!'
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
                      : _improved
                      ? StageTheme.green
                      : null,
                  fontWeight: _improved ? FontWeight.w700 : null,
                ),
              ),
            ],
            if (_progress case final p?) _crateProgress(context, p),
            if (_progress?.missions case final m? when _missionsOn)
              MissionRunNote(m, names: _pickupNames),
            // A run of 0 m leaves the bonus open for the next one.
            if (_bonusOpen && !_saving) ...[
              const SizedBox(height: 12),
              _dailyBonusHint(context),
            ],
            const SizedBox(height: 20),
            Wrap(
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
                  OutlinedButton(
                    key: const ValueKey('runner-free-run'),
                    onPressed: _motion.ready ? _play : null,
                    child: const Text('Freier Lauf'),
                  ),
                ],
                if (_dressable)
                  WardrobeButton(
                    crates:
                        _progress?.waiting ?? _wardrobe?.progress.waiting ?? 0,
                    onPressed: _openWardrobe,
                  ),
                OutlinedButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('Zurück in die App'),
                ),
              ],
            ),
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
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        _pointers++;
        _resume();
      },
      onPointerUp: (_) => _pointers = max(0, _pointers - 1),
      onPointerCancel: (_) => _pointers = max(0, _pointers - 1),
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
                  child: CustomPaint(
                    key: const ValueKey('runner-stage'),
                    size: Size.infinite,
                    painter: _stagePainter(ratio),
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
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ValueListenableBuilder(
                      valueListenable: _hud,
                      builder: (context, hud, _) => Row(
                        children: [
                          Expanded(
                            child: Text(
                              hud.$1 == 1 ? '1 Punkt' : '${hud.$1} Punkte',
                              style: number,
                            ),
                          ),
                          Text('${hud.$2} m', style: number),
                        ],
                      ),
                    ),
                    // A made mission, briefly, between points and metres.
                    ValueListenableBuilder(
                      valueListenable: _missionBanner,
                      builder: (context, made, _) => AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: made == null
                            ? const SizedBox.shrink()
                            : FractionallySizedBox(
                                key: ValueKey(made.slot),
                                widthFactor: .6,
                                child: Center(
                                  child: MissionBanner(
                                    made,
                                    names: _pickupNames,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
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
              builder: (context, _) => !_paused
                  ? const SizedBox.shrink()
                  : ColoredBox(
                      key: const ValueKey('runner-paused'),
                      color: const Color(0x99000000),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Pause', style: number),
                            const SizedBox(height: 8),
                            Text(
                              'Tippen zum Weiterlaufen',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFFFFF1D6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// The stage got its size: the course is laid out to the picture's right
  /// edge at once. When the size changes during a run (a turned phone, a
  /// resized window), the run pauses until the next tap. The game counts in
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
    _paused = true;
    _pointers = 0;
    _ticker.stop();
    if (_sound case final RunnerMusic music) music.pauseMusic();
  }

  /// Pauses a run in play until the next tap ([_resume]), with its music;
  /// whether it did.
  bool _pauseRun() {
    if (_phase != _Phase.playing || _game.over || _paused) return false;
    setState(() => _paused = true);
    _pointers = 0;
    _ticker.stop();
    if (_sound case final RunnerMusic music) music.pauseMusic();
    return true;
  }

  /// Runs on after a pause, from the first fresh frame.
  void _resume() {
    if (!_paused || _settingsOpen) return;
    setState(() => _paused = false);
    _lastFrame = Duration.zero;
    _ticker.start();
    if (_sound case final RunnerMusic music) music.resumeMusic();
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
  RunnerGhosts? ghosts,
  GhostSkins? ghostSkins,
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
    ghosts: ghosts == null ? null : () => ghosts,
    ghostSkins: ghostSkins == null ? null : () => ghostSkins,
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
    this.ghosts,
    this.ghostSkins,
  }) : super(repaint: repaint);
  final StageRunner Function() game;

  /// The ghosts of a Wochenprobe run and their figures; null otherwise.
  final RunnerGhosts? Function()? ghosts;
  final GhostSkins? Function()? ghostSkins;
  final RunnerFx Function() fx;
  final RunnerArt? Function() art;

  /// Only decorative movement; the course and the player's hitboxes keep
  /// moving at the same speed in either setting.
  final bool Function() sceneryMotion;

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
  static final _ghostSkinPaint = Paint()..filterQuality = FilterQuality.medium;
  static final _ghostMark = _stroke(const Color(0x40DCE6F0), 1.5)
    ..strokeCap = StrokeCap.round;
  static final _ghostTagLayer = Paint();
  static final _tagOpacities = [
    for (var i = 0; i <= _ghostSteps; i++)
      Color.fromRGBO(0, 0, 0, i / _ghostSteps),
  ];
  // The name tags of a frame (at most the three of [RunnerGhosts.named]).
  final _tagGhosts = List<RunnerGhost?>.filled(3, null);
  final _tagTops = Float64List(3);
  final _glyphs = RunnerGlyphs();
  final _path = Path();
  final _decoration = _DecorationPictures();
  final _rim = RunnerRimCache();

  void dispose() {
    _decoration.dispose();
    _rim.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = game(), f = fx(), a = art();
    final movingScenery = sceneryMotion();
    // One stage height in pixels; the playing field is [view] heights wide
    // and starts [top] pixels down (see [stageLayout]).
    final (:s, :top, view: _) = stageLayout(size, pixelRatio);
    if (s <= 0) return;
    _decoration.resize(size);
    final w = size.width, below = size.height - top - s;
    final floorY = s * StageRunner.floor;
    _glyphs.stage(s);

    // The set is drawn beyond the picture on purpose (tiles and wings from
    // off-screen, the crash nudge), and neither CustomPaint nor its
    // RepaintBoundary clip: without this cut the stage would paint over
    // whatever lies next to it, e.g. the section rail on wide screens.
    canvas
      ..save()
      ..clipRect(Offset.zero & size, doAntiAlias: false)
      ..drawRect((Offset.zero & size).inflate(s * .05), _bg);
    final (dx, dy) = movingScenery ? f.shake(g) : (0.0, 0.0);
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
    if (top > 0) _drapes(canvas, s, w, top, sceneryScroll);
    if (below > 0) _stalls(canvas, s, w, below, sceneryScroll);
    canvas
      ..save()
      ..clipRect(Rect.fromLTRB(-s, 0, w + s, s));
    _backdrop(canvas, a, s, w, floorY, sceneryScroll);
    _spotlights(canvas, s, w, floorY, sceneryScroll);
    _wings(canvas, s, w, sceneryScroll);
    _floor(canvas, s, w, floorY, sceneryScroll);
    // Behind everything that matters for the run.
    if (ghosts?.call() case final gh?) {
      _ghostRuns(canvas, g, gh, ghostSkins?.call(), a, s, w, course);
    }

    for (final o in g.obstacles) {
      final rect = Rect.fromLTRB(
        o.left * s - course,
        o.top * s,
        o.right * s - course,
        o.bottom * s,
      );
      if (rect.right < -s * .1 || rect.left > w + s * .1) continue;
      if (a == null) {
        _plainObstacle(canvas, o.kind, rect, s, floorY);
      } else {
        _obstacle(canvas, a, o, rect, s, floorY);
      }
    }

    _pickups(canvas, g, a, s, w, course);
    trail().paint(canvas, s, a?.effect);
    if (a == null) {
      _plainRunner(canvas, g, s);
    } else {
      _runner(canvas, g, f, a, s);
    }
    _particles(canvas, f, s);
    _audience(canvas, s, w, sceneryScroll);
    _bannerAndValance(canvas, f, s, w, sceneryScroll, movingScenery);
    canvas
      ..restore()
      ..restore();

    if (g.over) _curtain(canvas, g, s, w, size.height, movingScenery);
    canvas.restore();
  }

  /// The painted backdrop passes [scroll] pixels to the left, tiled in turn
  /// as painted and mirrored, so the seams match for any picture: no
  /// backdrop needs edges that fit together. A tile is a whole number of
  /// device pixels wide, so the seams fall on pixel edges and stay
  /// invisible. Its paint samples with mipmaps ([FilterQuality.medium]):
  /// smooth when scaled down, no stair steps when scaled up.
  void _backdrop(
    Canvas canvas,
    RunnerArt? a,
    double s,
    double w,
    double floorY,
    double scroll,
  ) {
    if (a == null) {
      canvas.drawRect(Rect.fromLTRB(0, s * .1, w, floorY), _wallPaint);
      return;
    }
    final image = a.backdrop, top = s * .04, h = floorY - top;
    final tile = max(
      1 / pixelRatio,
      (h * image.width / image.height * pixelRatio).round() / pixelRatio,
    );
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    for (var x = -(scroll % (2 * tile)); x < w; x += 2 * tile) {
      canvas.drawImageRect(
        image,
        src,
        Rect.fromLTWH(x, top, tile, h),
        a.backdropPaint,
      );
      canvas
        ..save()
        ..translate(x + 2 * tile, top)
        ..scale(-1, 1)
        ..drawImageRect(
          image,
          src,
          Rect.fromLTWH(0, 0, tile, h),
          a.backdropPaint,
        )
        ..restore();
    }
  }

  /// Light cones hung every .72 stage heights, passing with the stage:
  /// flat translucent shapes, no blur.
  void _spotlights(
    Canvas canvas,
    double s,
    double w,
    double floorY,
    double scroll,
  ) {
    final period = s * .72;
    for (
      var x = s * .48 - scroll % period - period;
      x < w + s * .25;
      x += period
    ) {
      _path
        ..reset()
        ..moveTo(x - s * .02, 0)
        ..lineTo(x + s * .02, 0)
        ..lineTo(x + s * .22, floorY)
        ..lineTo(x - s * .22, floorY)
        ..close();
      canvas.drawPath(_path, _conePaint);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(x, floorY + s * .02),
          width: s * .46,
          height: s * .06,
        ),
        _poolPaint,
      );
    }
  }

  /// Velvet wings every .51 stage heights, passing with the stage.
  void _wings(Canvas canvas, double s, double w, double scroll) {
    const width = .07;
    final period = s * .51;
    for (var left = -(scroll % period); left < w; left += period) {
      final top = s * .05, bottom = s * StageRunner.floor;
      canvas.drawRect(
        Rect.fromLTRB(left, top, left + s * width, bottom),
        _velvetPaint,
      );
      for (final fold in const [.012, .042]) {
        canvas.drawRect(
          Rect.fromLTRB(left + s * fold, top, left + s * (fold + .012), bottom),
          _foldPaint,
        );
      }
    }
  }

  /// The floor; its planks pass exactly with the course.
  void _floor(Canvas canvas, double s, double w, double floorY, double scroll) {
    canvas.drawRect(Rect.fromLTRB(0, floorY, w, s), _floorPaint);
    final period = s * .25;
    for (var x = -(scroll % period); x < w + s * .04; x += period) {
      canvas.drawLine(Offset(x, floorY), Offset(x - s * .04, s), _plankPaint);
    }
    canvas.drawLine(Offset(0, floorY), Offset(w, floorY), _edgePaint);
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
        for (final x in [rect.left + s * .012, rect.right - s * .012]) {
          canvas.drawLine(Offset(x, 0), Offset(x, suspensionY), _ropePaint);
        }
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
        for (final x in [.28, .72]) {
          final dx = frame.left + frame.width * x;
          canvas.drawLine(
            Offset(dx, 0),
            Offset(dx, frame.top + height * .02),
            _ropePaint,
          );
        }
        _sprite(canvas, a, sprite, frame);
    }
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
    void slice(
      double srcTop,
      double srcBottom,
      double dstTop,
      double dstBottom,
    ) => canvas.drawImageRect(
      a.imageOf(sprite),
      Rect.fromLTRB(src.left, src.top + srcTop, src.right, src.top + srcBottom),
      Rect.fromLTRB(left, dstTop, left + width, dstBottom),
      a.paintOf(sprite),
    );
    slice(0, topCap, rect.top, rect.top + top);
    slice(topCap, sprite.height - footCap, rect.top + top, rect.bottom - foot);
    slice(
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
    void slice(double srcTop, double srcBottom, double dstTop, double dstEnd) =>
        canvas.drawImageRect(
          a.imageOf(sprite),
          Rect.fromLTRB(
            src.left,
            src.top + srcTop,
            src.right,
            src.top + srcBottom,
          ),
          Rect.fromLTRB(left, dstTop, left + width, dstEnd),
          a.paintOf(sprite),
        );
    final middle = rect.height - top - foot;
    if (middle <= 0) {
      slice(0, sprite.height, rect.top, rect.bottom);
      return;
    }
    final count = max(1, (middle / (rowHeight * scale)).round());
    final row = middle / count;
    slice(0, topCap, rect.top, rect.top + top);
    for (var i = 0; i < count; i++) {
      final from = topCap + (i % rows) * rowHeight;
      final y = rect.top + top + i * row;
      slice(from, from + rowHeight, y, y + row);
    }
    slice(
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
    for (final side in [0.0, 1 - upright]) {
      canvas.drawImageRect(
        a.imageOf(cell),
        Rect.fromLTWH(
          cell.x + cell.width * side,
          cell.y,
          cell.width * upright,
          cell.height,
        ),
        Rect.fromLTRB(
          left + width * side,
          max(rect.top, back),
          left + width * (side + upright),
          rect.bottom + max(0.0, gap),
        ),
        a.paintOf(cell),
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
  ) {
    final glyph = s * .075, height = s * .085;
    for (final p in g.pickups) {
      if (p.taken) continue;
      final x = p.x * s - course;
      if (x < -glyph || x > w + glyph) continue;
      // A gentle bob; the hitbox stays where it is.
      final y = p.y * s + sin(g.time * 4 + p.x * 7) * s * .008;
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
  ) {
    final onFloor =
        g.y >= StageRunner.floor - StageRunner.runnerHeight / 2 - .001;
    final RunnerSprite sprite;
    var feet = g.y + StageRunner.runnerHeight / 2 + .006;
    var angle = 0.0, wireTop = 0.0;
    if (g.over) {
      sprite = RunnerSprite.crash;
      // Drops to the floor with a little bounce; the wire snaps upwards.
      final t = (g.sinceOver / .35).clamp(0, 1).toDouble();
      final bounce = (1 - t) * sin(t * pi) * .06;
      feet =
          feet +
          (StageRunner.floor + .01 - feet) * Curves.easeIn.transform(t) -
          bounce;
      angle = (1 - t) * .5;
      wireTop =
          (g.y - StageRunner.runnerHeight / 2) * Curves.easeOut.transform(t);
    } else if (f.cheer > 0) {
      sprite = RunnerSprite.cheer;
    } else if (onFloor) {
      sprite = RunnerSprite.stride(g.distance);
    } else {
      sprite = g.vy < -.05 ? RunnerSprite.fly : RunnerSprite.dangle;
      angle = (g.vy * .12).clamp(-.2, .2).toDouble();
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
    final shine = a.effect?.shine ?? false;
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

  void _particles(Canvas canvas, RunnerFx f, double s) {
    for (var i = 0; i < RunnerFx.maxParticles; i++) {
      final life = f.life[i];
      if (life <= 0) continue;
      canvas.drawCircle(
        Offset(f.px[i] * s, f.py[i] * s),
        f.size[i] * s * min(1, life * 3),
        _particlePaints[f.tint[i]],
      );
    }
    final size = s * .045;
    for (final p in f.popups) {
      if (!p.alive) continue;
      final at = Offset(p.x * s, (p.y - p.age * .12) * s);
      _paintCentered(
        canvas,
        _glyphs.label(p.text, size, shadow: true),
        at + Offset(s * .003, s * .003),
      );
      _paintCentered(canvas, _glyphs.label(p.text, size), at);
    }
  }

  /// Heads in the front row, passing with the stage. They sit calmly, also
  /// while a banner celebrates.
  void _audience(Canvas canvas, double s, double w, double scroll) {
    final spacing = s * .11;
    final first = (scroll / spacing).floor() - 1;
    var count = 0;
    while ((first + count) * spacing - scroll < w + spacing) {
      count++;
    }
    _decoration.paint(
      canvas,
      ('audience', first % 13, count),
      first * spacing - scroll,
      (recording) {
        for (var i = 0; i < count; i++) {
          final h = ((first + i) * 7919) % 13;
          final r = s * (.034 + (h % 3) * .004);
          final x = i * spacing + (h % 5) * s * .004;
          final y = s * (.985 - (h % 4) * .006);
          recording.drawCircle(Offset(x, y - r * .6), r, _crowdPaint);
          recording.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(x, y + r * 1.2),
                width: r * 3.2,
                height: r * 2.2,
              ),
              Radius.circular(r),
            ),
            _crowdPaint,
          );
        }
      },
    );
  }

  /// Tall pictures: above the playing field the house's velvet drape,
  /// [top] pixels high, its folds passing with the stage, darker towards
  /// the top and hemmed in gold above the valance.
  void _drapes(Canvas canvas, double s, double w, double top, double scroll) {
    final from = -top - s * .05;
    canvas.drawRect(Rect.fromLTRB(0, from, w, 0), _velvetPaint);
    final period = s * .09;
    final shift = -(scroll % period);
    var count = 0;
    for (var x = shift; x < w; x += period) {
      count++;
    }
    _decoration.paint(canvas, ('drapes', count), shift, (recording) {
      for (var i = 0; i < count; i++) {
        final x = i * period;
        recording
          ..drawRect(
            Rect.fromLTRB(x + period * .12, from, x + period * .3, 0),
            _sheenPaint,
          )
          ..drawRect(
            Rect.fromLTRB(x + period * .55, from, x + period * .85, 0),
            _foldPaint,
          );
      }
    });
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
  void _stalls(Canvas canvas, double s, double w, double below, double scroll) {
    final bottom = s + below + s * .05, gap = s * .24;
    canvas.drawRect(Rect.fromLTRB(0, s, w, bottom), _housePaint);
    // The first row right below the stage's edge, so even a thin strip of
    // stalls shows heads.
    for (var row = 1; s + (row - 1) * gap < bottom; row++) {
      final grow = 1 + row * .05, y = s + (row - .65) * gap;
      final spacing = s * .16 * grow, shift = scroll + row * spacing * .5;
      final first = (shift / spacing).floor() - 1;
      var count = 0;
      while ((first + count) * spacing - shift < w + spacing) {
        count++;
      }
      _decoration.paint(
        canvas,
        ('stalls', row, first % 13, count),
        first * spacing - shift,
        (recording) {
          for (var i = 0; i < count; i++) {
            final h = ((first + i) * 7919 + row * 104729) % 13;
            // Now and then a seat stays empty.
            if (h == 4) continue;
            final r = s * (.03 + (h % 3) * .004) * grow;
            final x = i * spacing + (h % 5) * s * .006;
            final head = y - r * (1.9 + (h % 4) * .1);
            recording.drawCircle(Offset(x, head), r, _crowdPaint);
            recording.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromCenter(
                  center: Offset(x, head + r * 1.8),
                  width: r * 3.1,
                  height: r * 2.2,
                ),
                Radius.circular(r),
              ),
              _crowdPaint,
            );
          }
        },
      );
      // The backs of the seats in front hide the shoulders.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(-s, y, w + s, y + gap * .32),
          Radius.circular(s * .02),
        ),
        _seatPaint,
      );
      canvas.drawRect(Rect.fromLTRB(0, y, w, y + s * .006), _seatEdgePaint);
    }
  }

  /// The banner pops in below the valance and slides up behind it. The
  /// valance's scallops pass with the stage.
  void _bannerAndValance(
    Canvas canvas,
    RunnerFx f,
    double s,
    double w,
    double scroll,
    bool movingScenery,
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
    final bottom = s * StageRunner.ceiling * .7, r = s * .03;
    canvas.drawRect(Rect.fromLTRB(0, 0, w, bottom), _velvetPaint);
    final shift = r - scroll % (r * 2);
    var count = 0;
    for (var x = shift; x < w + r; x += r * 2) {
      count++;
    }
    _decoration.paint(canvas, ('valance', count), shift, (recording) {
      for (var i = 0; i < count; i++) {
        recording.drawCircle(Offset(i * r * 2, bottom), r, _velvetPaint);
      }
    });
    canvas.drawRect(
      Rect.fromLTRB(0, bottom - s * .01, w, bottom - s * .004),
      _goldPaint,
    );
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
    for (final left in [true, false]) {
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
    ObstacleKind kind,
    Rect rect,
    double s,
    double floorY,
  ) {
    switch (kind) {
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
        for (final x in [bar.left + 2, bar.right - 2]) {
          canvas.drawLine(Offset(x, 0), Offset(x, bar.top), _ropePaint);
        }
        canvas.drawRect(bar, _metalPaint);
        canvas.drawRect(
          Rect.fromLTRB(rect.left, bar.bottom, rect.right, rect.bottom),
          _metalPaint,
        );
        canvas.drawRect(
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
        for (final x in [frame.left + inset, frame.right - inset]) {
          final top = Offset(x, 0), bottom = Offset(x, frame.top);
          canvas
            ..drawLine(top, bottom, _flyLineEdge)
            ..drawLine(top, bottom, _flyLinePaint);
        }
        canvas.drawRect(frame, _canvasPaint);
        canvas.drawRect(frame.deflate(1), _canvasLine);
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
    for (final ghost in shown) {
      if (!ghost.crashed || t < ghost.end) continue;
      final x = ghost.endX * s - course;
      if (x < -mark || x > w + mark) continue;
      final y = ghost.endY * s;
      canvas
        ..drawLine(
          Offset(x - mark, y - mark),
          Offset(x + mark, y + mark),
          _ghostMark,
        )
        ..drawLine(
          Offset(x - mark, y + mark),
          Offset(x + mark, y - mark),
          _ghostMark,
        );
    }
    final cx = StageRunner.runnerX * s;
    // The best last, on top.
    for (var i = shown.length - 1; i >= 0; i--) {
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
        _ghostSprite(canvas, g, ghost, skin, y, s);
      }
    }
    final tags = ghostTagAlpha(t);
    if (tags > 0) _ghostTags(canvas, ghosts, t, s, tags);
  }

  /// A ghost in its figure: the runner's poses, without the wire and
  /// without tilting, so it stays calm.
  void _ghostSprite(
    Canvas canvas,
    StageRunner g,
    RunnerGhost ghost,
    ui.Image skin,
    double y,
    double s,
  ) {
    final t = g.time;
    final sprite = ghost.onFloorAt(t)
        ? RunnerSprite.stride(g.distance)
        : ghost.vyAt(t) < -.05
        ? RunnerSprite.fly
        : RunnerSprite.dangle;
    final scale = RunnerSprite.stagePerPixel * s;
    final width = sprite.width * scale, height = sprite.height * scale;
    final feet = sprite == RunnerSprite.fly
        ? y + height / s / 2
        : y + StageRunner.runnerHeight / 2 + .006;
    final cx = StageRunner.runnerX * s, bottom = feet * s;
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
    for (final ghost in ghosts.shown) {
      if (n == _tagGhosts.length) break;
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
    final fading = alpha < 1;
    if (fading) {
      _ghostTagLayer.color = _tagOpacities[(alpha * _ghostSteps).round()];
      canvas.saveLayer(Rect.fromLTRB(0, 0, cx, s), _ghostTagLayer);
    }
    var below = double.infinity;
    for (var i = 0; i < n; i++) {
      final ghost = _tagGhosts[i]!;
      final tag = _glyphs.tag(ghost.tag, size, ghost.rank);
      final top = min(_tagTops[i], below - tag.height);
      tag.paint(canvas, Offset(cx - gap - tag.width, top));
      below = top;
      _tagGhosts[i] = null;
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
      old.pixelRatio != pixelRatio || old.sceneryMotion() != sceneryMotion();
}

/// Small recorded strips preserve the vector edges at every pixel ratio.
/// Their thirteen audience variations repeat along the course. Only the
/// strip's translation changes each frame; its paths and rounded rectangles
/// are recorded again only for a new variation or a resized stage.
class _DecorationPictures {
  static const _limit = 256;
  final _pictures = <Object, ui.Picture>{};
  Size? _size;

  void resize(Size size) {
    if (_size == size) return;
    dispose();
    _size = size;
  }

  void paint(
    Canvas canvas,
    Object key,
    double shift,
    void Function(Canvas) record,
  ) {
    var picture = _pictures.remove(key);
    if (picture == null) {
      final recorder = ui.PictureRecorder();
      record(Canvas(recorder));
      picture = recorder.endRecording();
      if (_pictures.length >= _limit) {
        _pictures.remove(_pictures.keys.first)!.dispose();
      }
    }
    _pictures[key] = picture;
    canvas
      ..save()
      ..translate(shift, 0)
      ..drawPicture(picture)
      ..restore();
  }

  void dispose() {
    for (final picture in _pictures.values) {
      picture.dispose();
    }
    _pictures.clear();
    _size = null;
  }
}
