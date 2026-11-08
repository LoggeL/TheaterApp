import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'stage_runner.dart';

/// Ghosts of the Wochenprobe: the runner's height through a run, sampled
/// [ghostHz] times per second of simulation time ([StageRunner.time]), one
/// byte per sample from the fly loft's lowest reach ([StageRunner.ceiling],
/// 0) to the floor ([StageRunner.floor], 255). Every run is at the same
/// place at the same time ([StageRunner.unitsAt]), so the heights are all a
/// ghost needs: where it is follows from the time. Sent to the server, a
/// last byte says whether the run ended in a crash (1) or not (0); the
/// runner's centre never comes within half its height of the fly loft or the
/// floor, so no height is ever 0 or 1 (see [ghostByte]).
const ghostHz = 20;

/// The most samples a ghost may have (the server's limit too): 2000 s.
const ghostMaxSamples = 40000;

int ghostByte(double y) =>
    ((y - StageRunner.ceiling) /
            (StageRunner.floor - StageRunner.ceiling) *
            255)
        .round()
        .clamp(0, 255);

double ghostY(int byte) =>
    StageRunner.ceiling +
    byte / 255 * (StageRunner.floor - StageRunner.ceiling);

/// Records a run as a ghost. [record] is called after every
/// [StageRunner.update] (and once before the first); it fills in the
/// samples up to the run's time, each between the heights of the frames
/// around it, so the ghost does not depend on the frame rate. Only grows
/// its buffer now and then, never per frame.
///
/// A run ends between two samples. So that its ghost ends where it crashed
/// (not up to a sample's way before, in front of the obstacle), the height
/// of the crash goes in as one more sample when the crash is nearer the
/// next sample than the last one: the ghost's [RunnerGhost.end] is then
/// within half a sample of the crash.
class GhostRecorder {
  Uint8List _samples = Uint8List(1024);
  int _length = 0;
  double _lastTime = 0, _lastY = 0;
  bool _started = false, _ended = false;

  /// Samples so far.
  int get length => _length;

  void record(StageRunner game) {
    final time = game.time, y = game.y;
    if (!_started) {
      _started = true;
      _lastTime = time;
      _lastY = y;
    }
    while (_length < ghostMaxSamples && _length / ghostHz <= time + 1e-9) {
      final at = _length / ghostHz;
      final span = time - _lastTime;
      final f = span > 0 ? ((at - _lastTime) / span).clamp(0.0, 1.0) : 1.0;
      _add(ghostByte(_lastY + (y - _lastY) * f));
    }
    if (game.over && !_ended) {
      _ended = true;
      if (_length < ghostMaxSamples &&
          time - (_length - 1) / ghostHz > .5 / ghostHz) {
        _add(ghostByte(y));
      }
    }
    _lastTime = time;
    _lastY = y;
  }

  void _add(int byte) {
    if (_length == _samples.length) {
      _samples = Uint8List(_samples.length * 2)..setAll(0, _samples);
    }
    _samples[_length++] = byte;
  }

  Uint8List get samples => Uint8List.sublistView(_samples, 0, _length);

  /// The samples and the crash flag as the server takes them (`ghost` with
  /// the score).
  String encode({required bool crashed}) =>
      base64Encode([...samples, if (crashed) 1 else 0]);
}

/// The character a ghost was run in (`character` of a ghost,
/// `runnerGhostFigures`): its atlas, in the layout of the game's own, when
/// this member may load it; [isDefault] for the game's own figure, drawn
/// from the game's own atlas. Without a picture the ghost is a silhouette.
class GhostFigure {
  const GhostFigure({required this.id, this.image, this.isDefault = false});
  final String id;
  final String? image;
  final bool isDefault;

  static GhostFigure? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    final image = json['image'];
    return GhostFigure(
      id: json['id'] as String,
      image: image is String && image.isNotEmpty ? image : null,
      isDefault: json['default'] == true,
    );
  }
}

/// Another run of this week's course, as it is played back.
class RunnerGhost {
  RunnerGhost({
    required this.personId,
    required this.name,
    required this.rank,
    required this.score,
    required this.meters,
    required this.samples,
    this.hz = ghostHz,
    this.crashed = true,
    this.me = false,
    this.figure,
  });

  final int personId, rank, score, meters, hz;
  final String name;
  final Uint8List samples;

  /// Whether the run ended in a crash; a small mark shows where.
  final bool crashed;

  /// The signed-in member's own best run.
  final bool me;

  /// The figure it was run in; null from older servers (a silhouette).
  final GhostFigure? figure;

  /// One of the best three, whose name tag has its medal's colour.
  bool get top => rank >= 1 && rank <= 3;

  /// The run's last moment, in seconds (of a crash: within half a sample
  /// of it, see [GhostRecorder]).
  double get end => samples.isEmpty ? 0 : (samples.length - 1) / hz;

  /// Where the run ended, in world x (the runner's centre then), and at
  /// which height.
  late final double endX = StageRunner.unitsAt(end) + StageRunner.runnerX;
  late final double endY = yAt(end);

  /// The name tag: "2. Lena", or "2. Du".
  late final String tag = me ? '$rank. Du' : '$rank. $name';

  /// The height at [time], between the samples around it.
  double yAt(double time) {
    if (samples.isEmpty) return StageRunner.floor;
    final at = max(0.0, time) * hz;
    final i = at.floor();
    if (i >= samples.length - 1) return ghostY(samples.last);
    final a = samples[i], b = samples[i + 1];
    return ghostY(a) + (ghostY(b) - ghostY(a)) * (at - i);
  }

  /// How fast the height changes at [time], in stage heights per second
  /// (negative: rising), over the sample it lies in.
  double vyAt(double time) {
    final step = 1 / hz;
    return (yAt(time) - yAt(time - step)) / step;
  }

  /// Whether the ghost runs on the floor at [time]. The samples hold the
  /// height to a 255th of the stage, so a little more slack than the game's.
  bool onFloorAt(double time) =>
      yAt(time) >= StageRunner.floor - StageRunner.runnerHeight / 2 - .005;

  /// A ghost from the weekly view, or null when its samples cannot be read.
  static RunnerGhost? fromJson(Map<String, Object?> json, {int? me}) {
    final y = json['y'];
    if (y is! String || y.isEmpty) return null;
    final Uint8List samples;
    try {
      samples = base64Decode(y);
    } on FormatException {
      return null;
    }
    if (samples.isEmpty || samples.length > ghostMaxSamples) return null;
    final hz = json['hz'];
    int number(Object? v) => v is num ? v.toInt() : 0;
    final personId = number(json['personId']);
    return RunnerGhost(
      personId: personId,
      name: json['name'] is String ? json['name'] as String : '',
      rank: number(json['rank']),
      score: number(json['score']),
      meters: number(json['meters']),
      samples: samples,
      hz: hz is num && hz > 0 ? hz.toInt() : ghostHz,
      crashed: json['crashed'] != false,
      me: json['me'] == true || (me != null && personId == me),
      figure: GhostFigure.fromJson(json['character']),
    );
  }
}

/// Which ghosts a run of the Wochenprobe shows ("Geister: Wenige / Alle").
/// There is no "none": the ghosts are what the week is about, but all of
/// them at once distract, so "Wenige" is the default.
enum GhostMode {
  /// The week's best, the own best run and whoever is just ahead of it.
  few('Wenige'),

  /// Everyone's best run.
  all('Alle');

  const GhostMode(this.label);
  final String label;
}

/// The ghosts [mode] shows of [ghosts] (best first, as they come), best
/// first. [GhostMode.few]: the week's first, the own best run and the one
/// directly ahead of it in the ranking ([ownRank], else the own ghost's
/// rank), each once; without an own place yet the first two.
List<RunnerGhost> pickGhosts(
  List<RunnerGhost> ghosts,
  GhostMode mode, {
  int? ownRank,
}) {
  if (mode == GhostMode.all) return List.unmodifiable(ghosts);
  final own = ghosts.where((g) => g.me).firstOrNull;
  final rank = own?.rank ?? ownRank;
  final ranks = rank == null || rank < 1 ? const {1, 2} : {1, rank - 1, rank};
  return List.unmodifiable([
    for (final g in ghosts)
      if (identical(g, own) || (!g.me && ranks.contains(g.rank))) g,
  ]);
}

/// How clear a ghost is drawn at most: all alike, faint enough to run
/// through without looking twice.
const ghostOpacity = .25;

/// The share of [ghostOpacity] a ghost keeps right on the own figure:
/// nearly invisible, so the own runner always stands out.
const ghostNearShare = .1;

/// The opacity of a ghost at height [ghostY] while the runner is at
/// [runnerY]. Everyone runs at the same speed, so ghost and runner are at
/// the same x and only the heights tell them apart: from one runner's height
/// apart down to half of it the ghost fades to [ghostNearShare].
double ghostAlpha(double ghostY, double runnerY) {
  const near = StageRunner.runnerHeight * .5, far = StageRunner.runnerHeight;
  final apart = (ghostY - runnerY).abs();
  final f = ((apart - near) / (far - near)).clamp(0.0, 1.0);
  return ghostOpacity * (ghostNearShare + (1 - ghostNearShare) * f);
}

/// How long the names show at the start of a run, and how long they take
/// to fade out after that, in seconds of the run.
const ghostNamesFor = 2.0, ghostNamesFade = .5;

/// The opacity of the name tags at [time] of the run: full during the
/// first [ghostNamesFor] seconds, then gone within [ghostNamesFade].
double ghostTagAlpha(double time) =>
    (1 - (time - ghostNamesFor) / ghostNamesFade).clamp(0.0, 1.0);

/// The ghosts of a run, best first: all of them, those [mode] shows and
/// those whose names show at the start (the [GhostMode.few] ones, in
/// either mode).
class RunnerGhosts {
  RunnerGhosts(
    List<RunnerGhost> ghosts, {
    this._mode = GhostMode.few,
    this.ownRank,
  }) : ghosts = List.unmodifiable(
         [...ghosts]..sort((a, b) => a.rank.compareTo(b.rank)),
       ) {
    named = pickGhosts(this.ghosts, GhostMode.few, ownRank: ownRank).toSet();
    _pick();
  }

  final List<RunnerGhost> ghosts;

  /// The own place in the week's ranking, if the own best has no ghost.
  final int? ownRank;

  GhostMode _mode;
  GhostMode get mode => _mode;
  set mode(GhostMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _pick();
  }

  /// What is drawn, best first.
  List<RunnerGhost> shown = const [];

  /// The ghosts with a name tag.
  late final Set<RunnerGhost> named;

  void _pick() => shown = pickGhosts(ghosts, _mode, ownRank: ownRank);

  /// The best of them, whose score the run chases.
  RunnerGhost? get leader => ghosts.firstOrNull;
}
