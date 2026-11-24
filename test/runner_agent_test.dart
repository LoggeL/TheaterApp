import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';

import '../tool/runner_agent.dart' show loadRunnerPolicy, runnerLandscape;
import '../tool/runner_agent/policy.dart';

void main() {
  final policy = loadRunnerPolicy();

  test('the example clears 4000 with ordinary inputs and collisions', () {
    final game = StageRunner(seed: 500054)..view = runnerLandscape;
    final player = HumanRunner(policy, 123001014);
    int? previous;
    var held = false, taps = 0, floorFrames = 0;
    for (var i = 0; !game.over && i < 60 * 300; i++) {
      final desired = player.hold(game);
      if (desired && !held) taps++;
      if (desired != held) {
        if (previous == null) {
          expect(i, greaterThanOrEqualTo(10));
        } else {
          expect(i - previous, greaterThanOrEqualTo(HumanRunner.minDwell));
        }
        previous = i;
      }
      held = desired;
      game.holding = held;
      final before = game.groundDistance;
      game.update(1 / 60);
      if (game.groundDistance > before) floorFrames++;
    }
    expect(game.over, isTrue);
    expect(game.score, greaterThanOrEqualTo(4000));
    expect(floorFrames / (60 * game.time), greaterThan(.15));
    expect(taps * 60 / game.time, lessThan(85));
    expect(game.score, game.meters + game.pickupPoints);
    expect(player.freshestObservation, greaterThanOrEqualTo(10));
  });

  test('walks under a lamp without tapping for an overhead pickup', () {
    final game = StageRunner(seed: 1);
    game.obstacles
      ..clear()
      ..add(
        Obstacle()
          ..kind = ObstacleKind.lamp
          ..left = StageRunner.runnerX + .5
          ..width = .18
          ..top = 0
          ..bottom = .4,
      );
    game.pickups
      ..clear()
      ..add(
        Pickup()
          ..x = StageRunner.runnerX + .57
          ..y = .48,
      );
    final player = HumanRunner(policy, 117);
    for (var i = 0; i < 90; i++) {
      game.holding = player.hold(game);
      expect(game.holding, isFalse, reason: 'tick $i');
      game.update(1 / 60);
    }
    expect(game.over, isFalse);
    expect(game.groundDistance, closeTo(game.distance, 1e-9));
  });

  test('lifts its feet over a low sill at the bottom of an opening', () {
    final game = StageRunner(seed: 1);
    final left = StageRunner.runnerX + .7;
    game.obstacles
      ..clear()
      ..add(
        Obstacle()
          ..kind = ObstacleKind.border
          ..left = left
          ..width = .09
          ..top = 0
          ..bottom = .32,
      )
      ..add(
        Obstacle()
          ..kind = ObstacleKind.flat
          ..left = left
          ..width = .09
          ..top = .815
          ..bottom = StageRunner.floor,
      );
    game.pickups.clear();
    final player = HumanRunner(policy, 117);
    var taps = 0;
    while (!game.over && game.runnerWorldX < left + .15) {
      final hold = player.hold(game);
      if (hold && !game.holding) taps++;
      game.holding = hold;
      game.update(1 / 60);
    }
    expect(game.over, isFalse);
    expect(taps, greaterThan(0));
  });

  test('new geometry cannot affect a decision before its reaction delay', () {
    final high = StageRunner(seed: 1), low = StageRunner(seed: 1);
    final a = HumanRunner(policy, 117), b = HumanRunner(policy, 117);
    for (var tick = 0; tick < 40; tick++) {
      expect(a.hold(high), b.hold(low));
    }
    // Keep the runner still, so the newly visible geometry is the only
    // difference. A hanging lamp and a tall flat require opposite inputs.
    high.obstacles.add(
      Obstacle()
        ..kind = ObstacleKind.lamp
        ..left = StageRunner.runnerX + .18
        ..width = .12
        ..top = 0
        ..bottom = .6,
    );
    low.obstacles.add(
      Obstacle()
        ..kind = ObstacleKind.flat
        ..left = StageRunner.runnerX + .18
        ..width = .12
        ..top = .35
        ..bottom = StageRunner.floor,
    );
    var differed = false;
    for (var elapsed = 0; elapsed < 90; elapsed++) {
      final different = a.hold(high) != b.hold(low);
      if (elapsed < 10) expect(different, isFalse, reason: 'tick $elapsed');
      differed |= different;
    }
    expect(differed, isTrue);
  });

  test('hidden obstacles cannot influence inputs', () {
    final plain = StageRunner(seed: 5), extra = StageRunner(seed: 5);
    final hidden = Obstacle()
      ..left = extra.view + .01
      ..width = .1
      ..top = .3
      ..bottom = StageRunner.floor;
    extra.obstacles.add(hidden);
    final a = HumanRunner(policy, 109), b = HumanRunner(policy, 109);
    for (var i = 0; i < 1200 && !plain.over; i++) {
      // The extra obstacle stays outside the camera throughout this test.
      hidden.left = extra.distance + extra.view + .01;
      plain.holding = a.hold(plain);
      extra.holding = b.hold(extra);
      expect(extra.holding, plain.holding, reason: 'frame $i');
      plain.update(1 / 60);
      extra.update(1 / 60);
    }
  });

  test(
    'gesture timing is repeatable and varies independently of the course',
    () {
      List<bool> inputs(int motorSeed) {
        final game = StageRunner(seed: 57)..view = runnerLandscape;
        final player = HumanRunner(policy, motorSeed);
        final trace = <bool>[];
        while (!game.over && trace.length < 1200) {
          game.holding = player.hold(game);
          trace.add(game.holding);
          game.update(1 / 60);
        }
        return trace;
      }

      final trace = inputs(23);
      expect(inputs(23), trace);
      expect(inputs(24), isNot(trace));
    },
  );
}
