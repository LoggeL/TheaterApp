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
  });

  final int personId, rank, score, meters, hz;
  final String name;
  final Uint8List samples;

  /// Whether the run ended in a crash; a small mark shows where.
  final bool crashed;

  /// The signed-in member's own best run.
  final bool me;

  /// The best three are drawn clearly, with their names.
  bool get top => rank >= 1 && rank <= 3;

  /// The run's last moment, in seconds (of a crash: within half a sample
  /// of it, see [GhostRecorder]).
  double get end => samples.isEmpty ? 0 : (samples.length - 1) / hz;

  /// Where the run ended, in world x (the runner's centre then), and at
  /// which height.
  late final double endX = StageRunner.unitsAt(end) + StageRunner.runnerX;
  late final double endY = yAt(end);

  /// The name tag of one of the best three: "2. Lena", or "2. Du".
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
    );
  }
}

/// The ghosts a run shows, best first, and whether they are shown at all
/// (training can hide them).
class RunnerGhosts {
  RunnerGhosts(List<RunnerGhost> ghosts, {this.visible = true})
    : ghosts = [...ghosts]..sort((a, b) => a.rank.compareTo(b.rank));
  final List<RunnerGhost> ghosts;
  bool visible;

  /// The best of them, whose score the run chases.
  RunnerGhost? get leader => ghosts.firstOrNull;
}
