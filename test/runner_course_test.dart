import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/domain/course_random.dart';
import 'package:theater_app/features/games/domain/runner_ghost.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';

/// What decides an obstacle where it is laid out: the fields that move
/// (a rolling drum, a falling sandbag, a riding drop) by what drives them.
String _obstacle(Obstacle o) => switch (o.kind) {
  ObstacleKind.drum =>
    'drum ${o.anchor} ${o.meets} ${o.width} ${o.top} ${o.bottom}',
  ObstacleKind.sandbag => 'sandbag ${o.left} ${o.width} ${o.bottom - o.top}',
  ObstacleKind.drop => 'drop ${o.left} ${o.width} ${o.anchor} ${o.phase}',
  _ =>
    '${o.kind.name} ${o.left} ${o.width} ${o.top} ${o.bottom} '
        '${o.gap} ${o.counted}',
};

String _pickup(Pickup p) => '${p.kind.name} ${p.x} ${p.y}';

/// The course of [seed] up to [upTo] stage heights as a run lays it out,
/// with frames of [dt], on a picture [view] wide (widened to [widen] at
/// 300 m when given) and steered by [steer]. Every obstacle and pickup is
/// noted when it first shows up; recycled objects count anew.
({List<String> obstacles, List<String> pickups}) _course(
  int seed, {
  required double Function(int frame) dt,
  double view = StageRunner.viewWidth,
  double? widen,
  void Function(StageRunner game) steer = _rest,
  double upTo = 150,
}) {
  final game = StageRunner(seed: seed)
    ..invincible = true
    ..view = view;
  final obstacles = <(double, String)>[], pickups = <(double, String)>[];
  var seenObstacles = Set<Obstacle>.identity();
  var seenPickups = Set<Pickup>.identity();
  void note() {
    for (final o in game.obstacles) {
      if (seenObstacles.contains(o)) continue;
      final x = o.kind == ObstacleKind.drum ? o.anchor : o.left;
      obstacles.add((x, _obstacle(o)));
    }
    for (final p in game.pickups) {
      if (!seenPickups.contains(p)) pickups.add((p.x, _pickup(p)));
    }
    seenObstacles = Set.identity()..addAll(game.obstacles);
    seenPickups = Set.identity()..addAll(game.pickups);
  }

  note();
  var frame = 0;
  while (game.distance < upTo + 2) {
    steer(game);
    game.update(dt(frame++));
    if (widen != null && game.meters >= 300 && game.view < widen) {
      game.view = widen;
    }
    note();
  }
  List<String> upToEnd(List<(double, String)> items) => [
    for (final (x, s) in items)
      if (x < upTo) s,
  ];
  return (obstacles: upToEnd(obstacles), pickups: upToEnd(pickups));
}

void _rest(StageRunner game) => game.holding = false;
void _hold(StageRunner game) => game.holding = true;

/// Flies towards the next pickup to take as many as possible.
void _greedy(StageRunner game) {
  final ahead = game.pickups.where((p) => p.x > game.runnerWorldX - .02);
  final target = ahead.isEmpty
      ? null
      : ahead.reduce((a, b) => a.x < b.x ? a : b);
  game.holding = target != null && target.y < game.y;
}

/// Steers around the obstacles like a careful player (as in
/// stage_runner_test.dart), ignoring the pickups.
void _careful(StageRunner game) {
  const f = StageRunner.floor, c = StageRunner.ceiling;
  const hw = StageRunner.hitHalfWidth + .01;
  const hh = StageRunner.hitHalfHeight + .015;
  const minY = c + StageRunner.runnerHeight / 2;
  const maxY = f - StageRunner.runnerHeight / 2;
  final x = game.runnerWorldX;
  final ahead = game.obstacles.where((o) => o.right > x - hw).toList()
    ..sort((a, b) => a.left.compareTo(b.left));
  var lo = minY, hi = maxY;
  if (ahead.isNotEmpty) {
    final first = ahead.first;
    for (final o in ahead.where((o) => o.left < first.right + hw)) {
      switch (o.kind) {
        case ObstacleKind.sandbag:
          hi = min(hi, f - (o.bottom - o.top) - hh);
        case ObstacleKind.drop:
          lo = max(lo, o.anchor + StageRunner.dropSwing + hh);
        case _ when o.top <= 0:
          lo = max(lo, o.bottom + hh);
        case _:
          hi = min(hi, o.top - hh);
      }
    }
  }
  final y = game.y;
  final target = lo > hi ? (lo + hi) / 2 : y.clamp(lo, hi).toDouble();
  final wanted = ((target - y) * 10)
      .clamp(-StageRunner.maxRise, StageRunner.maxFall)
      .toDouble();
  game.holding = game.vy > wanted;
}

void main() {
  group('course dice', () {
    test('roll the same numbers everywhere for a seed', () {
      // From the reference mulberry32 in JavaScript (Math.imul), and the
      // same on the Dart VM and compiled to JavaScript: the web and the
      // apps must run one course from one seed.
      const golden = {
        0: [1144304738, 1416247, 958946056, 627933444, 2007157716],
        1: [2693262067, 11749833, 2265367787, 4213581821, 4159151403],
        46: [258016024, 3930957454, 1899134967, 3411614491, 966749302],
        0xFFFFFFFF: [3850105811, 813802916, 3073704848, 4054706436, 3630262831],
        123456789: [1107202814, 4169434471, 3372958138, 885470128, 1301683845],
      };
      for (final MapEntry(key: seed, value: values) in golden.entries) {
        final dice = CourseRandom(seed);
        expect([for (final _ in values) dice.nextUint32()], values);
      }
      // A seed is a uint32.
      expect(CourseRandom(46 + CourseRandom.seeds).nextUint32(), 258016024);
      final dice = CourseRandom(7);
      for (var i = 0; i < 1000; i++) {
        expect(dice.nextDouble(), inInclusiveRange(0, 1 - 1e-12));
        expect(dice.nextInt(7), inInclusiveRange(0, 6));
      }
    });

    test('a seed lays out its course, the same in every version', () {
      // Ghosts of a week are only right while the course of its seed stays
      // the same: a change here needs a new course version.
      final game = StageRunner(seed: 46)..view = 20;
      expect(
        [
          for (final o in game.obstacles.where((o) => o.counted).take(14))
            (o.kind, double.parse(o.left.toStringAsFixed(6))),
        ],
        [
          (ObstacleKind.crate, 1.9),
          (ObstacleKind.crate, 2.702809),
          (ObstacleKind.crate, 3.51799),
          (ObstacleKind.flat, 4.345195),
          (ObstacleKind.lamp, 5.13408),
          (ObstacleKind.lamp, 5.963643),
          (ObstacleKind.crate, 6.803974),
          (ObstacleKind.crate, 7.67476),
          (ObstacleKind.lamp, 8.555924),
          (ObstacleKind.border, 9.427141),
          (ObstacleKind.border, 10.297878),
          (ObstacleKind.border, 11.177734),
          (ObstacleKind.border, 12.06642),
          (ObstacleKind.border, 12.963652),
        ],
      );
      expect(
        [
          for (final p in game.pickups.take(6))
            (
              p.kind,
              double.parse(p.x.toStringAsFixed(6)),
              double.parse(p.y.toStringAsFixed(6)),
            ),
        ],
        [
          (PickupKind.rose, 1.87, .527628),
          (PickupKind.rose, 1.96, .527628),
          (PickupKind.rose, 2.05, .527628),
          (PickupKind.mask, 5.968643, .604712),
          (PickupKind.mask, 6.058643, .604712),
          (PickupKind.rose, 8.515924, .589352),
        ],
      );
    });
  });

  group('deterministic course', () {
    test('time and distance follow each other exactly', () {
      for (final m in [0.0, 5, 120, 1000, 1999, 2500, 9000, 40000]) {
        final t = RunnerRules.secondsAt(m.toDouble());
        expect(RunnerRules.maxMeters(t), closeTo(m, 1e-6), reason: '$m m');
      }
      expect(RunnerRules.secondsAt(-3), 0);
      // However the frames fall, a run is where [unitsAt] says.
      final jitter = Random(3);
      final a = StageRunner(seed: 1)..invincible = true;
      final b = StageRunner(seed: 1)..invincible = true;
      while (a.time < 60) {
        a.update(1 / 60);
      }
      while (b.time < a.time - 1e-9) {
        b.update(min(a.time - b.time, .004 + jitter.nextDouble() * .046));
      }
      expect(b.time, closeTo(a.time, 1e-9));
      expect(a.distance, closeTo(StageRunner.unitsAt(a.time), 1e-9));
      expect(b.distance, closeTo(a.distance, 1e-9));
    });

    test('the course depends on the seed only: not on frames, the picture '
        'or what the runner takes', () {
      const seed = 2026;
      final jitter = Random(11);
      final jittered = [
        for (var i = 0; i < 400000; i++) .004 + jitter.nextDouble() * .046,
      ];
      final reference = _course(seed, dt: (_) => 1 / 60);
      expect(reference.obstacles.length, greaterThan(100));
      expect(reference.pickups.length, greaterThan(50));
      final variants = {
        '144 Hz': _course(seed, dt: (_) => 1 / 144),
        'jittery frames': _course(seed, dt: (i) => jittered[i]),
        'long and short frames': _course(
          seed,
          dt: (i) => i.isEven ? .05 : .002,
        ),
        'turned phone': _course(seed, dt: (_) => 1 / 60, view: 2.17),
        'wide window': _course(seed, dt: (_) => 1 / 90, view: 3.5),
        'widened during the run': _course(seed, dt: (_) => 1 / 60, widen: 2.8),
        'taking every pickup': _course(seed, dt: (_) => 1 / 60, steer: _greedy),
        'under the fly loft': _course(
          seed,
          dt: (i) => jittered[i],
          view: 2.33,
          steer: _hold,
        ),
      };
      for (final MapEntry(key: why, value: course) in variants.entries) {
        expect(course.obstacles, reference.obstacles, reason: why);
        expect(course.pickups, reference.pickups, reason: why);
      }
      // Another seed is another course.
      expect(
        _course(seed + 1, dt: (_) => 1 / 60).obstacles,
        isNot(reference.obstacles),
      );
    });

    test('the debuts come where runs met them by points before', () {
      // Where the runner first got to each new obstacle under the points of
      // apps up to 0.14 (250, 500, 750, 1000), as the mean of 60 courses
      // simulated with the course of then: by a careful player who ignores
      // the pickups (about 1.35 points per metre) and by one who takes
      // every pickup (about 1.55).
      const careful = {
        ObstacleKind.drum: 202.9,
        ObstacleKind.pile: 399.4,
        ObstacleKind.truss: 598.7,
        ObstacleKind.drop: 797.7,
      };
      const greedy = {
        ObstacleKind.drum: 174.7,
        ObstacleKind.pile: 344.4,
        ObstacleKind.truss: 520.1,
        ObstacleKind.drop: 698.9,
      };
      for (final (name, steer) in [
        ('careful', _careful),
        ('greedy', _greedy),
      ]) {
        final met = <ObstacleKind, List<int>>{};
        for (var seed = 0; seed < 20; seed++) {
          final game = StageRunner(seed: seed)..invincible = true;
          final seen = <ObstacleKind>{};
          while (game.meters < 900) {
            steer(game);
            game.update(1 / 60);
            for (final o in game.obstacles) {
              if (careful.containsKey(o.kind) &&
                  o.left <= game.runnerWorldX &&
                  seen.add(o.kind)) {
                met.putIfAbsent(o.kind, () => []).add(game.meters);
              }
            }
          }
        }
        for (final (meters, kind) in StageRunner.debuts) {
          final mean = met[kind]!.reduce((a, b) => a + b) / met[kind]!.length;
          // Never before its metres; about where a typical run met it
          // before, halfway between the two players of then (neither of
          // them is one: nobody takes every pickup, and few skip them all).
          expect(met[kind]!.reduce(min), greaterThanOrEqualTo(meters));
          final typical = (greedy[kind]! + careful[kind]!) / 2;
          expect(mean, closeTo(typical, typical * .02), reason: '$name, $kind');
        }
      }
    });
    test('the server counts the debuts at the same metres', () {
      // runnerDebuts in server/src/runner-missions.mjs checks the passed
      // obstacles and makes the "reach" missions.
      final source = File('server/src/runner-missions.mjs').readAsStringSync();
      final line = RegExp(
        r'export const runnerDebuts = Object\.freeze\(\[(.*)\]\);',
      ).firstMatch(source)!;
      final server = [
        for (final m in RegExp(r"\[(\d+), '(\w+)'\]").allMatches(line[1]!))
          (int.parse(m[1]!), m[2]!),
      ];
      expect(server, [
        for (final (meters, kind) in StageRunner.debuts) (meters, kind.name),
      ]);
    });
  });

  group('ghost', () {
    test('records the height 20 times per second of the run', () {
      final game = StageRunner(seed: 5);
      final recorder = GhostRecorder()..record(game);
      expect(recorder.length, 1);
      // Frames of exactly a sample apart: every sample is a frame's height.
      final heights = <double>[game.y];
      while (!game.over && game.time < 30) {
        game
          ..holding = sin(game.time * 2.5) > 0
          ..update(1 / ghostHz);
        recorder.record(game);
        heights.add(game.y);
      }
      expect(game.over, isTrue);
      // Frames on the samples: the crash is one, nothing more after it.
      expect(recorder.length, (game.time * ghostHz + 1e-6).floor() + 1);
      const step = (StageRunner.floor - StageRunner.ceiling) / 255;
      final ghost = RunnerGhost.fromJson({
        'personId': 4,
        'name': 'Lena',
        'rank': 1,
        'score': 120,
        'meters': game.meters,
        'hz': ghostHz,
        'y': base64Encode(recorder.samples),
        'crashed': true,
      })!;
      expect(ghost.samples, recorder.samples);
      // Sent with the flag of the crash after the samples.
      expect(base64Decode(recorder.encode(crashed: true)), [
        ...recorder.samples,
        1,
      ]);
      expect(base64Decode(recorder.encode(crashed: false)).last, 0);
      for (final (i, y) in heights.indexed) {
        if (i >= ghost.samples.length) break;
        expect(ghost.yAt(i / ghostHz), closeTo(y, step / 2 + 1e-9));
      }
      // Between two samples it moves on evenly.
      final half = ghost.yAt(.5 + .5 / ghostHz);
      expect(
        half,
        closeTo((ghost.yAt(.5) + ghost.yAt(.5 + 1 / ghostHz)) / 2, 1e-9),
      );
      // The samples fit the metres, as the server checks.
      expect(
        RunnerRules.maxMeters((ghost.samples.length - 1) / ghostHz),
        closeTo(game.meters, 2),
      );
      expect(ghost.end, closeTo(game.time, 1 / ghostHz));
      expect(ghost.endX, closeTo(game.runnerWorldX, .2));
      expect(ghost.tag, '1. Lena');
      expect(ghost.yAt(ghost.end + 10), ghostY(ghost.samples.last));
    });

    test('ends where the run crashed', () {
      for (final dt in [1 / 30, 1 / 60, 1 / 144, .0123, .037]) {
        for (var seed = 0; seed < 8; seed++) {
          final game = StageRunner(seed: seed);
          final recorder = GhostRecorder()..record(game);
          while (!game.over) {
            game
              ..holding = sin(game.time * 1.7 + seed) > 0
              ..update(dt);
            recorder.record(game);
          }
          final ghost = RunnerGhost(
            personId: 1,
            name: 'Lena',
            rank: 1,
            score: game.score,
            meters: game.meters,
            samples: recorder.samples,
          );
          final why = 'dt $dt, seed $seed';
          expect(
            ghost.end,
            closeTo(game.time, .5 / ghostHz + 1e-9),
            reason: why,
          );
          expect(
            ghost.endX,
            closeTo(
              game.runnerWorldX,
              RunnerRules.speedAt(game.time) * .5 / ghostHz + 1e-3,
            ),
            reason: why,
          );
          // A last sample past the run's time has the height of the crash.
          if (ghost.end > game.time) {
            expect(recorder.samples.last, ghostByte(game.y), reason: why);
          }
          // No more after the crash.
          final length = recorder.length;
          game.update(dt);
          recorder.record(game);
          expect(recorder.length, length, reason: why);
        }
      }
    });

    test('does not depend on the frame rate', () {
      final counts = <int>[];
      for (final dt in [1 / 30, 1 / 60, 1 / 144, .0123]) {
        final game = StageRunner(seed: 9)..invincible = true;
        final recorder = GhostRecorder()..record(game);
        while (game.time < 20 - 1e-9) {
          game.update(min(dt, 20 - game.time));
          recorder.record(game);
        }
        counts.add(recorder.length);
        // Resting on the floor all the way.
        expect(recorder.samples.toSet(), {
          ghostByte(StageRunner.floor - StageRunner.runnerHeight / 2),
        });
      }
      expect(counts.toSet(), {20 * ghostHz + 1});
    });

    test('a byte covers the runner’s whole height range', () {
      expect(ghostByte(StageRunner.ceiling), 0);
      expect(ghostByte(StageRunner.floor), 255);
      // The runner's own heights never look like the crash flag.
      const lowest = StageRunner.floor - StageRunner.runnerHeight / 2;
      const highest = StageRunner.ceiling + StageRunner.runnerHeight / 2;
      expect(ghostByte(highest), greaterThan(1));
      expect(ghostByte(lowest), lessThan(254));
      expect(ghostByte(-1), 0);
      expect(ghostByte(2), 255);
      for (var b = 0; b < 256; b++) {
        expect(ghostByte(ghostY(b)), b);
      }
    });

    test('unreadable ghosts are left out', () {
      expect(RunnerGhost.fromJson({'y': 'not base64!'}), isNull);
      expect(RunnerGhost.fromJson({'y': ''}), isNull);
      expect(RunnerGhost.fromJson({}), isNull);
      expect(
        RunnerGhost.fromJson({
          'y': base64Encode(Uint8List(ghostMaxSamples + 1)),
        }),
        isNull,
      );
      final own = RunnerGhost.fromJson({
        'personId': 3,
        'rank': 2,
        'y': base64Encode([10, 20]),
      }, me: 3)!;
      expect(own.me, isTrue);
      expect(own.tag, '2. Du');
      expect(own.crashed, isTrue);
      expect(own.top, isTrue);
    });

    test('the ghosts are ordered best first', () {
      RunnerGhost ghost(int rank) => RunnerGhost(
        personId: rank,
        name: 'P$rank',
        rank: rank,
        score: 100 - rank,
        meters: 10,
        samples: Uint8List.fromList([1]),
      );
      final ghosts = RunnerGhosts([ghost(5), ghost(1), ghost(3)]);
      expect([for (final g in ghosts.ghosts) g.rank], [1, 3, 5]);
      expect(ghosts.leader!.rank, 1);
      expect(ghosts.ghosts.where((g) => g.top), hasLength(2));
    });
  });
}
