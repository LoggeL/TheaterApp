import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:theater_app/features/games/domain/stage_runner.dart';

import 'runner_agent/policy.dart';

const _modelPath = 'tool/runner_agent/policy.json';
const _dt = 1 / 60;
const _trainingLimit = 6500;

const runnerLandscape = 2.1; // An 840 × 400 landscape playfield.
typedef _Run = ({
  StageRunner game,
  HumanRunner player,
  int taps,
  int groundFrames,
});
_Run _episode(
  RunnerPolicy policy,
  int seed, {
  required int motorSeed,
  int? limit,
  double view = runnerLandscape,
}) {
  final player = HumanRunner(policy, motorSeed);
  final game = StageRunner(seed: seed)..view = view;
  var taps = 0, groundFrames = 0;
  while (!game.over && (limit == null || game.score < limit)) {
    final hold = player.hold(game);
    if (hold && !game.holding) taps++;
    game.holding = hold;
    final previousGround = game.groundDistance;
    game.update(_dt);
    if (game.groundDistance > previousGround) groundFrames++;
  }
  return (game: game, player: player, taps: taps, groundFrames: groundFrames);
}

double _reward(RunnerPolicy policy, List<int> seeds) {
  var sum = 0.0;
  for (final (i, seed) in seeds.indexed) {
    final run = _episode(
      policy,
      seed,
      motorSeed: (i + 1) * 65537,
      limit: _trainingLimit,
    );
    final score = run.game.score;
    final scoreReward = min(score, 4000) + .20 * max(0, score - 4000);
    final floorShare = run.groundFrames * _dt / run.game.time;
    final tapsPerSecond = run.taps / run.game.time;
    sum +=
        scoreReward * (1 + .35 * floorShare - .12 * max(0, tapsPerSecond - 1));
  }
  return sum / seeds.length;
}

double _normal(Random random) =>
    sqrt(-2 * log(1 - random.nextDouble())) * cos(2 * pi * random.nextDouble());

void _train(String path) {
  final random = Random(20261109);
  const population = 14, elites = 4;
  var mean = [...RunnerPolicy.initial], spread = [...RunnerPolicy.spread];
  var champion = RunnerPolicy([...mean]);
  final validation = List.generate(16, (i) => 500000 + i);
  var best = _reward(champion, validation);
  stdout.writeln('Initial validation return: ${best.round()}');
  for (var round = 0; round < 12; round++) {
    final courses = List.generate(4, (_) => random.nextInt(500000));
    final ranked = <({RunnerPolicy policy, double reward})>[];
    for (var i = 0; i < population; i++) {
      final weights = [
        for (var j = 0; j < mean.length; j++)
          (mean[j] + spread[j] * _normal(random))
              .clamp(RunnerPolicy.minimum[j], RunnerPolicy.maximum[j])
              .toDouble(),
      ];
      final policy = RunnerPolicy(weights);
      ranked.add((policy: policy, reward: _reward(policy, courses)));
    }
    ranked.sort((a, b) => b.reward.compareTo(a.reward));
    final elite = ranked.take(elites).toList();
    for (var j = 0; j < mean.length; j++) {
      final center =
          elite.fold(0.0, (s, e) => s + e.policy.weights[j]) / elites;
      final variance =
          elite.fold(0.0, (s, e) => s + pow(e.policy.weights[j] - center, 2)) /
          elites;
      mean[j] = center;
      spread[j] = max(RunnerPolicy.spread[j] * .12, sqrt(variance));
    }
    for (final candidate in [
      elite.first.policy,
      RunnerPolicy([...mean]),
    ]) {
      final score = _reward(candidate, validation);
      if (score > best) {
        champion = candidate;
        best = score;
      }
    }
    stdout.writeln('Generation ${round + 1}: validation ${best.round()}');
  }
  File(path).writeAsStringSync(
    '${jsonEncode({'version': 1, 'weights': champion.weights})}\n',
  );
}

RunnerPolicy loadRunnerPolicy([String path = _modelPath]) {
  final data = jsonDecode(File(path).readAsStringSync()) as Map;
  final weights = (data['weights'] as List)
      .cast<num>()
      .map((n) => n.toDouble())
      .toList();
  if (data['version'] != 1 ||
      weights.length != RunnerPolicy.initial.length ||
      weights.asMap().entries.any(
        (e) =>
            !e.value.isFinite ||
            e.value < RunnerPolicy.minimum[e.key] ||
            e.value > RunnerPolicy.maximum[e.key],
      )) {
    throw const FormatException('Invalid runner policy');
  }
  return RunnerPolicy(weights);
}

void main(List<String> args) {
  switch (args.firstOrNull) {
    case 'train':
      _train(args.elementAtOrNull(1) ?? _modelPath);
    case 'eval':
      final start = int.parse(args.elementAtOrNull(1) ?? '1000000');
      final count = int.parse(args.elementAtOrNull(2) ?? '100');
      if (count < 1) throw const FormatException('count must be positive');
      final motorStart = int.parse(args.elementAtOrNull(3) ?? '120000000');
      final view = double.parse(args.elementAtOrNull(4) ?? '2.1');
      if (!view.isFinite || view < StageRunner.viewWidth) {
        throw const FormatException('view must be at least 1.6');
      }
      final policy = loadRunnerPolicy(args.elementAtOrNull(5) ?? _modelPath);
      final scores = <int>[];
      var totalSeconds = 0.0;
      var totalGroundFrames = 0, totalTaps = 0;
      stdout.writeln(
        'seed,score,meters,pickupPoints,seconds,hitBy,motorSeed,switches,minDwellFrames,minObservationAgeFrames,taps,groundSeconds',
      );
      for (var i = 0; i < count; i++) {
        final motorSeed = motorStart + i;
        final (:game, :player, :taps, :groundFrames) = _episode(
          policy,
          start + i,
          motorSeed: motorSeed,
          view: view,
        );
        scores.add(game.score);
        totalSeconds += game.time;
        totalGroundFrames += groundFrames;
        totalTaps += taps;
        stdout.writeln(
          '${game.seed},${game.score},${game.meters},${game.pickupPoints},'
          '${game.time.toStringAsFixed(3)},${game.hitBy?.name},$motorSeed,${player.switches},${player.shortestDwell},${player.freshestObservation},$taps,${(groundFrames * _dt).toStringAsFixed(3)}',
        );
      }
      scores.sort();
      final median = (scores[(count - 1) ~/ 2] + scores[count ~/ 2]) / 2;
      stderr.writeln(
        '${scores.where((s) => s >= 4000).length}/$count reached 4000; '
        'min ${scores.first}, median $median, max ${scores.last}; '
        '${(100 * totalGroundFrames * _dt / totalSeconds).toStringAsFixed(1)}% on floor, '
        '${(60 * totalTaps / totalSeconds).toStringAsFixed(1)} presses/min',
      );
    default:
      stderr.writeln(
        'dart run tool/runner_agent.dart train [model.json]\n'
        'dart run tool/runner_agent.dart eval [firstSeed [count [firstMotorSeed [view [model.json]]]]]',
      );
      exitCode = 64;
  }
}
