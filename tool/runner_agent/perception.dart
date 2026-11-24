part of 'policy.dart';

/// A visible section copied at capture time, including its multipart opening.
class _Lane {
  _Lane(this.left, this.right);
  final double left;
  double right;
  // Keep obstacle edges distinct from the limits on the runner's center:
  // even a lip below its center can catch its feet on the floor.
  double low = double.negativeInfinity, high = double.infinity;
  double closingSpeed = 0;
  double? pickupY, dropOffset;
  double dropAmplitude = 0;
}

/// Immutable with respect to the live world, including recycled obstacles.
class _Seen {
  _Seen(this.frame, this.motion, this.speed, this.sight, this.lanes);
  final int frame;
  final _Motion motion;
  final double speed, sight;
  final List<_Lane> lanes;
}

class _Eyes {
  _Eyes(this.random);
  final Random random;
  static const interval = 4, minLag = 10, maxLag = 14;
  final _queue = <({int ready, _Seen seen})>[];
  _Seen? _latest;
  _Motion? _estimate;

  // Roughly two to four pixels on a 400 px high stage.
  static double _position(double v) => (v * 160).round() / 160;
  static double _edge(double v) => (v * 100).round() / 100;

  _Seen? sample(StageRunner game, int frame, List<bool> history) {
    if (frame % interval == 0) {
      final y = _position(game.y);
      var estimate = _estimate ?? (y: y, vy: 0.0);
      if (frame > 0) {
        for (var i = frame - interval; i < frame; i++) {
          estimate = _step(estimate, history[i % history.length]);
        }
      }
      final residual = y - estimate.y;
      _estimate = (
        y: estimate.y + .6 * residual,
        vy: (estimate.vy + .18 * residual / (interval * _dt)).clamp(
          -StageRunner.maxRise,
          StageRunner.maxFall,
        ),
      );
      _queue.add((
        ready: frame + minLag + random.nextInt(maxLag - minLag + 1),
        seen: _Seen(
          frame,
          _estimate!,
          (game.speed * 20).round() / 20,
          game.view - StageRunner.runnerX,
          _visibleLanes(game),
        ),
      ));
    }
    while (_queue.isNotEmpty && _queue.first.ready <= frame) {
      _latest = _queue.removeAt(0).seen;
    }
    return _latest;
  }

  List<_Lane> _visibleLanes(StageRunner game) {
    final lanes = <_Lane>[];
    final x = game.runnerWorldX, edge = game.distance + game.view;
    for (final o in game.obstacles) {
      if (o.left >= edge || o.right < x - StageRunner.hitHalfWidth) continue;
      final left = _edge(o.left - x), right = _edge(min(o.right, edge) - x);
      if (lanes.isEmpty || left > lanes.last.right + .012) {
        lanes.add(_Lane(left, right));
      }
      final lane = lanes.last;
      lane.right = max(lane.right, right);
      switch (o.kind) {
        case ObstacleKind.sandbag:
          lane.high = _edge(StageRunner.floor - (o.bottom - o.top));
        case ObstacleKind.drop:
          final offset = (_edge(o.bottom) - StageRunner.dropMiddle).clamp(
            -StageRunner.dropSwing,
            StageRunner.dropSwing,
          );
          lane.dropOffset = offset;
          lane.dropAmplitude = sqrt(
            max(0.0, pow(StageRunner.dropSwing, 2) - offset * offset),
          );
          lane.low = StageRunner.dropMiddle;
        default:
          if (o.kind == ObstacleKind.drum) {
            lane.closingSpeed = StageRunner.rollSpeed;
          }
          if (o.top <= 0) {
            lane.low = max(lane.low, _edge(o.bottom));
          } else {
            lane.high = min(lane.high, _edge(o.top));
          }
      }
    }
    for (final p in game.pickups) {
      if (p.x > edge || p.x < x - .04) continue;
      final dx = _edge(p.x - x);
      for (final lane in lanes) {
        if (dx >= lane.left - .13 && dx <= lane.right + .13) {
          lane.pickupY ??= _edge(p.y);
          break;
        }
      }
    }
    return lanes;
  }
}
