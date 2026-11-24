import 'dart:math';

import 'package:theater_app/features/games/domain/stage_runner.dart';

part 'perception.dart';
part 'lookahead.dart';

const _dt = 1 / 60;
const _minY = StageRunner.ceiling + StageRunner.runnerHeight / 2;
const _maxY = StageRunner.floor - StageRunner.runnerHeight / 2;

typedef _Motion = ({double y, double vy});

_Motion _step(_Motion p, bool hold) {
  final a = hold ? -StageRunner.lift : StageRunner.gravity;
  final vy = (p.vy + a * _dt).clamp(-StageRunner.maxRise, StageRunner.maxFall);
  final y = p.y + vy * _dt;
  if (y < _minY || y > _maxY) return (y: y.clamp(_minY, _maxY), vy: 0);
  return (y: y, vy: vy);
}

/// Shaping weights for the short action forecast. Cross-entropy policy
/// search fits them against the score of complete, input-limited episodes.
class RunnerPolicy {
  RunnerPolicy(this.weights);
  final List<double> weights;
  static const initial = [.50, .052, .90, .018, 3.0, .30];
  static const spread = [.07, .014, .26, .014, 2.0, .25];
  static const minimum = [.28, .003, .0, .001, 1.0, .0];
  static const maximum = [.68, .095, 1.4, .08, 12.0, 2.0];

  double get cruiseY => weights[0];
  double get margin => weights[1];
  double get clearance => StageRunner.hitHalfHeight + margin;
  double get pickupGain => weights[2];
  double get speedPenalty => weights[3];
  double get pickupWeight => weights[4];
  double get switchCost => weights[5];
}

/// An offline player. Only the eyes read the live game; a decision gets an
/// old snapshot and the history of buttons actually held since its capture.
class HumanRunner {
  HumanRunner(this.policy, int motorSeed)
    : _eyes = _Eyes(Random(motorSeed)),
      _timing = Random(motorSeed ^ 0x6a09e667);

  static const minDwell = 8;
  final RunnerPolicy policy;
  final _Eyes _eyes;
  final Random _timing;
  final _plan = _Lookahead();
  final _history = List.filled(64, false);
  int _frame = 0, _nextDecision = 0;
  bool _holding = false;
  int switches = 0;
  int? lastSwitch, shortestDwell;
  int? freshestObservation;

  bool hold(StageRunner game) {
    final seen = _eyes.sample(game, _frame, _history);
    if (seen != null && _frame >= _nextDecision) {
      final age = _frame - seen.frame;
      freshestObservation = min(freshestObservation ?? age, age);
      var position = seen.motion;
      for (var tick = seen.frame; tick < _frame; tick++) {
        position = _step(position, _history[tick % _history.length]);
      }
      final desired = _plan.choose(policy, seen, age, position, _holding);
      final changed = desired != _holding;
      if (changed) {
        if (lastSwitch case final previous?) {
          shortestDwell = min(shortestDwell ?? _frame, _frame - previous);
        }
        lastSwitch = _frame;
        switches++;
      }
      _holding = desired;
      // Timing is drawn after deciding. A fresh press or release commits
      // the thumb for 8–11 ticks; an ongoing gesture can be reconsidered
      // after 3–5 ticks. Longer holds need no additional input.
      _nextDecision =
          _frame +
          (changed ? minDwell + _timing.nextInt(4) : 3 + _timing.nextInt(3));
    }
    _history[_frame % _history.length] = _holding;
    _frame++;
    return _holding;
  }
}
