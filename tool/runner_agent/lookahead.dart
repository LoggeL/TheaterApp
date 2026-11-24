part of 'policy.dart';

/// Score short sequences of presses and releases in the last perceived
/// scene. Only the first gesture goes to the motor controller.
class _Lookahead {
  static const horizon = 45;
  static const durations = [HumanRunner.minDwell, 11, 15, 20];
  final _lows = List.filled(horizon, _minY),
      _highs = List.filled(horizon, _maxY);
  final _targets = List.filled(horizon, .48),
      _priorities = List.filled(horizon, 1.0);
  late RunnerPolicy _policy;
  // Offsets include sampling and reaction latency as well as future ticks.
  static final _cos = List.generate(
    horizon + 64,
    (i) => cos(i * _dt * 2 * pi / StageRunner.dropPeriod),
  );
  static final _sin = List.generate(
    horizon + 64,
    (i) => sin(i * _dt * 2 * pi / StageRunner.dropPeriod).abs(),
  );

  bool choose(
    RunnerPolicy policy,
    _Seen scene,
    int age,
    _Motion at,
    bool holding,
  ) {
    // When the camera shows less than a landing and a takeoff ahead,
    // be ready for a new obstacle entering the frame.
    final shortPreview = scene.sight / scene.speed - age * _dt < 0.9;
    _policy = policy;
    // At higher speeds a second obstacle can arrive before a landing and
    // a fresh takeoff. Keep aiming for the opening through such sections.
    final cluster =
        shortPreview ||
        (scene.speed >= 1.25 &&
            scene.lanes.any(
              (lane) =>
                  lane.high.isFinite &&
                  lane.left <
                      (scene.speed + lane.closingSpeed) * (age * _dt + .95) &&
                  lane.right >
                      (scene.speed + lane.closingSpeed) * (age * _dt - .10),
            ));
    for (var i = 0; i < horizon; i++) {
      final tick = age + i + 1;
      _lows[i] = -1;
      _highs[i] = 2;
      _targets[i] = cluster ? policy.cruiseY : _maxY;
      _priorities[i] = 1;
      for (final lane in scene.lanes) {
        final dx = tick * _dt * (scene.speed + lane.closingSpeed);
        if (dx > lane.right + StageRunner.hitHalfWidth + .025) continue;
        double lo = lane.low, hi = lane.high;
        if (lane.dropOffset case final offset?) {
          lo += offset * _cos[tick] + lane.dropAmplitude * _sin[tick];
        }
        if (lo.isFinite) lo += policy.clearance;
        if (hi.isFinite) hi -= policy.clearance;
        final bonus = lane.pickupY;
        final aim = bonus == null
            ? policy.cruiseY
            : policy.cruiseY + policy.pickupGain * (bonus - policy.cruiseY);
        // Walk up to the obstacle. The search can still take off early
        // enough to clear it, since it scores the whole gesture sequence.
        final approach = (lane.left - dx) / (scene.speed + lane.closingSpeed);
        if (cluster || (approach <= .12 && lane.high.isFinite)) {
          _targets[i] = aim.clamp(lo, hi);
        }
        if (dx >= lane.left - .12 && bonus != null) {
          _priorities[i] = policy.pickupWeight;
        }
        if (dx >= lane.left - StageRunner.hitHalfWidth - .025) {
          if (lane.low.isFinite) _lows[i] = lo - policy.margin;
          if (lane.high.isFinite) _highs[i] = hi + policy.margin;
        }
        break;
      }
    }

    var best = double.negativeInfinity;
    var choice = holding;
    for (final hold in [holding, !holding]) {
      for (final ticks
          in hold == holding ? const [4, 7, ...durations] : durations) {
        final value = _value(
          0,
          at,
          hold,
          ticks,
          hold == holding ? 0 : policy.switchCost,
          best,
        );
        if (value > best) {
          best = value;
          choice = hold;
        }
      }
    }
    return choice;
  }

  // Penalize obstacle overlap across the crossing. After each
  // forecast gesture we can switch, or continue to the end of the horizon.
  double _value(
    int start,
    _Motion at,
    bool hold,
    int ticks,
    double cost,
    double incumbent,
  ) {
    final end = min(horizon, start + ticks);
    for (var i = start; i < end; i++) {
      at = _step(at, hold);
      final error = at.y - _targets[i];
      cost +=
          _priorities[i] * error * error + _policy.speedPenalty * at.vy * at.vy;
      final overlap = max(_lows[i] - at.y, at.y - _highs[i]);
      final margin = max(0.0, overlap + _policy.margin);
      cost += 180 * margin * margin + 4 * margin;
      if (overlap > 0) cost += 1 + 300 * overlap;
      if (-cost <= incumbent) return -cost;
    }
    if (end == horizon) return -cost;
    var best = _value(end, at, hold, horizon, cost, incumbent);
    for (final next in durations) {
      best = max(
        best,
        _value(
          end,
          at,
          !hold,
          next,
          cost + _policy.switchCost,
          max(best, incumbent),
        ),
      );
    }
    return best;
  }
}
