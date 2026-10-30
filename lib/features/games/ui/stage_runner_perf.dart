import '../../../core/telemetry/perf_telemetry.dart';
import '../data/wardrobe_api.dart';
import '../domain/stage_runner.dart';

/// Feeds the performance telemetry with one run's game-loop steps and what
/// happened in them (pickups, sounds, new obstacles, loaded costumes, the
/// crash and the curtain). Independent of the score: nothing here reaches
/// `runnerScore`. Inert while the telemetry is off (tests, debug builds).
class RunnerPerf {
  RunnerPerf(
    this._game, {
    required this.curtainStart,
    PerfRunRecorder? recorder,
    this.sound,
  }) : _recorder = recorder ?? PerfTelemetry.instance.beginRun();
  final StageRunner _game;
  final PerfRunRecorder _recorder;

  /// Seconds after the crash when the curtain starts to close.
  final double curtainStart;

  /// Whether sound is on, asked at the end of the run.
  final bool Function()? sound;
  Object? _lastObstacle;
  Object? _debut;
  bool _crashed = false, _curtain = false;
  double? _firstStepMs;

  /// A game-loop step of [seconds]; the first one after the start has none.
  /// The first measured one is the start's picture: what setting up the run
  /// noted (the first obstacle, a sound) is not what happened in the game.
  void step(double seconds) {
    if (seconds <= 0) return;
    if (_firstStepMs == null) {
      _firstStepMs = seconds * 1000;
      _recorder.clear();
    }
    _recorder.frame(seconds * 1000, seconds: _game.time, meters: _game.meters);
  }

  /// Notes what changed in the game during the last update.
  void observe() {
    final game = _game, obstacles = game.obstacles;
    final last = obstacles.isEmpty ? null : obstacles.last;
    if (!identical(last, _lastObstacle)) {
      _lastObstacle = last;
      if (last != null) _recorder.mark(PerfRunEvent.obstacle);
    }
    if (game.debut != null && game.debut != _debut) {
      _debut = game.debut;
      _recorder.mark(PerfRunEvent.debut);
    }
    if (game.over && !_crashed) {
      _crashed = true;
      _recorder.mark(PerfRunEvent.crash);
    }
    if (game.over && !_curtain && game.sinceOver >= curtainStart) {
      _curtain = true;
      _recorder.mark(PerfRunEvent.curtain);
    }
  }

  /// The run is being set up: the game, the sound, the music.
  void start() => _recorder.mark(PerfRunEvent.start);
  void played() => _recorder.mark(PerfRunEvent.sound);
  void pickup() => _recorder.mark(PerfRunEvent.pickup);

  /// A costume picture was decoded and is worn from now on.
  void skin() => _recorder.mark(PerfRunEvent.skin);

  /// Queues the run's report. Figures of ensemble members only count as
  /// `ensemble`: many wear their own, which would point to the person.
  void finish(Wardrobe? wardrobe, {String end = 'crash'}) {
    String? worn(WardrobeKind kind) {
      final item = wardrobe?.worn(kind);
      if (item == null || item.isDefault) return null;
      return item.personId != null ? 'ensemble' : item.id;
    }

    _recorder.finish(
      duration: Duration(microseconds: (_game.time * 1e6).round()),
      meters: _game.meters,
      score: _game.score,
      character: worn(WardrobeKind.character),
      backdrop: worn(WardrobeKind.backdrop),
      fx: worn(WardrobeKind.fx),
      end: end,
      sound: sound?.call(),
      firstStepMs: _firstStepMs,
    );
  }
}
