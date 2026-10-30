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
import '../domain/stage_runner.dart';
import 'ensemble_card.dart' show EnsembleStrip;
import 'missions_card.dart';
import 'runner_menu.dart';
import 'stage_runner_art.dart';
import 'stage_runner_fx.dart';
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
  });
  final AppController controller;

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
      onHide: () {
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
    _menu.addListener(_menuChanged);
    if (_art == null) {
      RunnerArt.load().then((art) {
        if (mounted && art != null) setState(() => _art = art);
        _dress();
      });
    }
    if (_dressable) _loadWardrobe();
    // Native players load during the intro; browsers preload only bytes.
    // The browser's audio context still opens in the start gesture.
    _sound.enabled.addListener(_soundChanged);
    _motion.addListener(_motionChanged);
    if (_sound case final RunnerMusic music) music.warmUp();
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
    if (mounted) setState(() {});
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
                title: const Text('Bewegung'),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Garderobe nicht geladen: $e');
    }
  }

  Future<void> _dress() async {
    unawaited(_tune());
    final base = RunnerArt.loaded, w = _wardrobe;
    if (base == null || w == null) return;
    final art = await dressArt(base, w, controller);
    if (mounted && identical(w, _wardrobe)) {
      setState(() => _art = art);
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

  void _play() {
    if (!_motion.ready) return;
    final run = ++_run;
    final game = _game = StageRunner(random: widget.random);
    final perf = _perf = RunnerPerf(
      game,
      curtainStart: _curtainStart,
      sound: () => _sound.enabled.value,
    );
    final fx = _fx = RunnerFx(
      best: _board?.own?.score,
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
    _saveError = null;
    _improved = false;
    _saving = false;
    _queued = false;
    _stageSize = null;
    _paused = false;
    // The server times the run; a failed start only means it is not ranked.
    _start = _ranked
        ? startRound(controller).then<String?>(
            (id) => id,
            onError: (Object e) {
              if (mounted && run == _run) {
                setState(() => _saveError = userMessage(e));
              }
              return null;
            },
          )
        : null;
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

  Future<void> _finish(int run) async {
    setState(() {
      _phase = _Phase.finished;
      _line = curtainLine(
        _game.hitBy,
        _lines,
        obstacleCrashLines: _art?.obstacleCrashLines ?? const {},
      );
    });
    final start = _start;
    if (start == null) return;
    // Fixed now, before anything is awaited: a quick "Nochmal" replaces
    // `_game` and `_start`, and this run must still be sent as it ended,
    // with its own round. The outbox sends it even when the next run plays.
    final outbox = runnerScoreOutbox(controller);
    final score = RunScore(
      round: start,
      score: _game.score,
      meters: _game.meters,
      hitBy: _game.hitBy,
      missionStats: _game.missionStats,
    );
    setState(() => _saving = true);
    try {
      final result = await outbox.send(score);
      if (result == null || !mounted) return;
      if (run != _run) {
        // Counted while the next run plays: its list is the newest so far.
        if (_phase == _Phase.playing) _board = result.leaderboard;
        return;
      }
      // The fanfare, unless it already played when the record fell.
      if (result.improved && !_fx.recordBroken) {
        _sound.play(RunnerSfx.record);
      } else if ((result.progress?.newCrates ?? 0) > 0) {
        _sound.play(RunnerSfx.reveal);
      }
      if (result.progress?.missions?.justCompletedAll ?? false) {
        _sound.play(RunnerSfx.jackpot);
      }
      setState(() {
        _improved = result.improved;
        _progress = result.progress;
        if (result.progress?.missions case final m?) _missions = m;
        _board = result.leaderboard;
        _boardError = null;
      });
      // The run may have moved the own place in this month's list.
      if (monthlyBoardAvailable(controller)) unawaited(_loadMonthly());
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
          _ => _menuBody(context),
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

  /// The menu before and after a run: the hero (or the last run's result)
  /// first, then the own standing, the Ensemble-Strecke, the rankings and
  /// the Tagesmissionen. Wide enough, the hero stays on the left and the
  /// rest scrolls beside it.
  Widget _menuBody(BuildContext context) {
    final lead = _phase == _Phase.intro ? _hero(context) : _result(context);
    final rest = [
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
            children: spaced([lead, ...rest]),
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
                  children: spaced(rest),
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

  Widget _result(BuildContext context) {
    final theme = Theme.of(context);
    final status = !_ranked
        ? null
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
                FilledButton.icon(
                  autofocus: true,
                  onPressed: _play,
                  icon: const Icon(Icons.replay),
                  label: const Text('Nochmal'),
                ),
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
  );

  /// The stage's painter, kept across rebuilds (its laid-out texts and
  /// shader stay); a new one only for another pixel ratio.
  _StagePainter? _painter;
  _StagePainter _stagePainter(double ratio) {
    final kept = _painter;
    if (kept != null && kept.pixelRatio == ratio) return kept;
    kept?.dispose();
    return _painter = _StagePainter(
      () => _game,
      () => _fx,
      () => _art,
      _frame,
      () => _trail,
      pixelRatio: ratio,
      sceneryMotion: () => _sceneryMotion,
    );
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
              delegate: _HudLayout(
                pad,
                ratio,
                MediaQuery.textScalerOf(context).scale(36),
              ),
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
  _HudLayout(this.pad, this.pixelRatio, this.height);
  final EdgeInsets pad;
  final double pixelRatio, height;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tight(
        Size(max(0, constraints.maxWidth - pad.horizontal - 40), height),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    pad.left + 20,
    max(pad.top + 4, stageLayout(size, pixelRatio).top - 52),
  );

  @override
  bool shouldRelayout(_HudLayout old) =>
      old.pad != pad || old.pixelRatio != pixelRatio || old.height != height;
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

/// The painter of the stage for one fixed [game], for tests and renders.
@visibleForTesting
CustomPainter stagePainterFor(
  StageRunner game,
  RunnerArt? art, {
  RunnerFx? fx,
  RunnerTrail? trail,
  double pixelRatio = 1,
  bool sceneryMotion = true,
}) {
  final f = fx ?? RunnerFx(), t = trail ?? RunnerTrail();
  return _StagePainter(
    () => game,
    () => f,
    () => art,
    _never,
    () => t,
    pixelRatio: pixelRatio,
    sceneryMotion: () => sceneryMotion,
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
class _StagePainter extends CustomPainter {
  _StagePainter(
    this.game,
    this.fx,
    this.art,
    Listenable repaint,
    this.trail, {
    this.pixelRatio = 1,
    required this.sceneryMotion,
  }) : super(repaint: repaint);
  final StageRunner Function() game;
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

  /// A crate too tall for one crate picture: two crates, or the obstacle
  /// set's own tall one.
  static bool _tall(Rect rect) => rect.height > rect.width * 1.35;

  void _obstacle(
    Canvas canvas,
    RunnerArt a,
    Obstacle o,
    Rect rect,
    double s,
    double floorY,
  ) {
    switch (o.kind) {
      case ObstacleKind.crate when a.ownTallCrate && _tall(rect):
        // One tall picture over the whole hitbox: the cell is as high as
        // the tall crates are on average, so it is never stretched much.
        _sprite(canvas, a, RunnerSprite.tallCrate, rect);
      case ObstacleKind.crate:
        // A tall pile is two crates, so none gets stretched much.
        if (_tall(rect)) {
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
      case ObstacleKind.flat:
        _flat(canvas, a, rect);
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
      case ObstacleKind.pile when a.ownPile:
        // One picture over both parts, drawn with the lower one (the upper
        // one is as high and stands on it); the hitboxes stay the same.
        if (o.bottom >= StageRunner.floor) {
          _sprite(
            canvas,
            a,
            RunnerSprite.pile,
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
        // Four lamps under the truss, the outer ones flush with its ends.
        final bar = RunnerSprite.truss;
        final lampWidth = rect.width * .19;
        final lampHeight =
            lampWidth * RunnerSprite.lamp.height / RunnerSprite.lamp.width;
        final barHeight = rect.width * bar.height / bar.width;
        final barTop = rect.bottom - lampHeight - barHeight * .5;
        for (var i = 0; i < 4; i++) {
          final x =
              rect.left + lampWidth / 2 + i * (rect.width - lampWidth) / 3;
          _lamp(canvas, a, x, rect.bottom, lampWidth, floorY);
        }
        for (final x in [rect.left + s * .012, rect.right - s * .012]) {
          canvas.drawLine(Offset(x, 0), Offset(x, barTop), _ropePaint);
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
        canvas.drawLine(
          Offset(frame.center.dx, 0),
          Offset(frame.center.dx, frame.top),
          _ropePaint,
        );
        canvas.drawRect(frame, _canvasPaint);
        canvas.drawRect(frame.deflate(1), _canvasLine);
    }
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
  bool shouldRepaint(_StagePainter old) =>
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
