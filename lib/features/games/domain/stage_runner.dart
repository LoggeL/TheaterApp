import 'dart:math';

import 'package:flutter/foundation.dart';

/// Shared limits of "Bühnenlauf"; the server checks scores against the same
/// numbers (`stageRunner` in server/src/theater.mjs).
abstract final class RunnerRules {
  /// Running speed in stage heights per second: grows linearly to [maxSpeed].
  static const startSpeed = .55, acceleration = .01, maxSpeed = 2.4;
  static const metersPerUnit = 10;

  /// The course never offers more pickup points than this per metre.
  static const pickupPointsPerMeter = 6;

  static double speedAt(double seconds) =>
      min(maxSpeed, startSpeed + acceleration * seconds);

  /// Metres a run can cover in [seconds].
  static double maxMeters(double seconds) {
    final t = max(0.0, seconds), top = (maxSpeed - startSpeed) / acceleration;
    final units = t <= top
        ? startSpeed * t + acceleration * t * t / 2
        : startSpeed * top +
              acceleration * top * top / 2 +
              maxSpeed * (t - top);
    return units * metersPerUnit;
  }
}

enum ObstacleKind {
  /// Props crate on the floor: hop over it.
  crate,

  /// Flat (a piece of scenery) standing on the floor.
  flat,

  /// Stage light hanging from the fly loft: stay below it.
  lamp,

  /// Border hanging from the fly loft; with a [flat] below it forms a gap.
  border,

  /// Sandbag that drops from the fly loft shortly before the runner arrives.
  sandbag,

  /// Cable drum that rolls towards the runner along the floor and comes to
  /// rest just before the runner gets there: hop over it.
  drum,

  /// Pile of three props crates, twice as wide as one: a long hop.
  pile,

  /// Lighting truss with a row of lamps: a long stretch to stay below.
  truss,

  /// Painted drop that rides up and down on its fly line: pass below it.
  drop,
}

enum PickupKind {
  rose(5),
  mask(10),
  star(25);

  const PickupKind(this.points);
  final int points;
}

/// An obstacle as a rectangle in world coordinates: x grows along the course,
/// y from the fly loft (0) to the floor (1), both in stage heights.
class Obstacle {
  ObstacleKind kind = ObstacleKind.crate;
  double left = 0, width = 0, top = 0, bottom = 0;

  /// A sandbag is falling or a drum is rolling.
  bool falling = false;

  /// Where a drum comes to rest (its left edge), or the middle height of a
  /// drop's lower edge.
  double anchor = 0;

  /// Where a drop is in its ride up and down, in radians.
  double phase = 0;

  double get right => left + width;
}

class Pickup {
  PickupKind kind = PickupKind.rose;
  double x = 0, y = 0;
  bool taken = false;
}

/// "Bühnenlauf": an endless run across the stage on a flying wire.
///
/// Holding (finger, mouse, space bar) pulls the runner up; letting go lets
/// them sink. The course is generated section by section with gaps that are
/// always reachable at the current speed, but speed and density keep growing
/// until the gaps get too tight to react – then the curtain falls.
///
/// Pure game state without Flutter widgets, advanced by [update]; objects are
/// recycled instead of allocated per section.
class StageRunner {
  StageRunner({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// Visible course width in stage heights; the runner stays at [runnerX].
  static const viewWidth = 1.6, runnerX = .4;

  /// The runner's body without wings, arms and halo.
  static const runnerWidth = .06, runnerHeight = .11;

  /// Half the hitbox: a bit smaller than the body, which feels fair.
  static const hitHalfWidth = runnerWidth * .4;
  static const hitHalfHeight = runnerHeight * .42;
  static const ceiling = .07, floor = .86;

  /// Vertical acceleration and speed limits (stage heights per second).
  static const lift = 5.2, gravity = 4.6, maxRise = 1.6, maxFall = 1.8;

  /// Obstacles that join the course once the score reaches their points; the
  /// earlier ones stay. Each one's first appearance comes right after.
  static const debuts = [
    (250, ObstacleKind.drum),
    (500, ObstacleKind.pile),
    (750, ObstacleKind.truss),
    (1000, ObstacleKind.drop),
  ];

  /// A drum starts rolling this far ahead of the runner, at this speed.
  static const rollFrom = 1.0, rollSpeed = .3;

  /// A drop's lower edge rides between [dropMiddle] ± [dropSwing], once in
  /// [dropPeriod] seconds: never faster than the runner climbs or sinks, and
  /// at its lowest the floor lane below stays wide open.
  static const dropMiddle = .4, dropSwing = .12, dropPeriod = 2.4;

  double time = 0, distance = 0;
  double y = floor - runnerHeight / 2, vy = 0;
  bool holding = false, over = false;

  /// Seconds since the run ended, for the closing curtain.
  double sinceOver = 0;
  int pickupPoints = 0, collected = 0;

  /// Lets tests run long courses without crashing.
  @visibleForTesting
  bool invincible = false;

  /// What ended the run, for the closing line.
  ObstacleKind? hitBy;

  /// How many of the [debuts] the score has reached.
  int unlocked = 0;

  /// The newest obstacle kind and where its first one stands, so the stage
  /// can announce it when it comes into view.
  ({ObstacleKind kind, double x})? debut;
  int _debuted = 0;

  /// Told about every pickup as it is taken, for sound and sparkle; it does
  /// not change the score.
  void Function(PickupKind kind, double x, double y)? onPickup;

  final List<Obstacle> obstacles = [];
  final List<Pickup> pickups = [];
  final List<Obstacle> _spareObstacles = [];
  final List<Pickup> _sparePickups = [];

  /// Where the next section starts, and the centre of the last gap.
  double _nextX = viewWidth + .3, _lastGapX = 0, _lastGapCenter = .5;

  /// Pickup points placed so far, for the per-metre limit.
  int placedPickupPoints = 0;

  int get meters => (distance * RunnerRules.metersPerUnit).floor();
  int get score => meters + pickupPoints;
  double get speed => RunnerRules.speedAt(time);

  /// World x of the runner's centre.
  double get runnerWorldX => distance + runnerX;

  /// Seconds the runner gets between two sections: shrinks with the distance
  /// until reacting is no longer possible.
  static double reactionTime(double meters) =>
      max(.3, 1.2 * pow(.9993, meters).toDouble());

  /// Share of the reachable height a gap may move between two gaps: below 1
  /// it is always reachable, from 2400 m on no longer.
  static double reachFactor(double meters) =>
      meters < 2000 ? .7 : min(1.6, .7 + (meters - 2000) / 1000 * .9);

  /// Height of a gap between a border and a flat.
  static double gapHeight(double meters) => max(.25, .46 - meters / 6000);

  /// Lower edge of a drop at [time].
  static double dropBottom(double middle, double phase, double time) =>
      middle + dropSwing * sin(2 * pi * time / dropPeriod + phase);

  /// How far ahead of its resting place a drum starts, so that it gets there
  /// before a runner at [speed]: it rolls while both close in on each other,
  /// counted from a little nearer than [rollFrom] to be sure.
  static double rollLead(double speed) =>
      rollSpeed * (rollFrom - .1) / (speed + rollSpeed);

  void update(double dt) {
    dt = dt.clamp(0, .05).toDouble();
    if (over) {
      sinceOver += dt;
      return;
    }
    time += dt;
    distance += speed * dt;
    vy = (vy + (holding ? -lift : gravity) * dt)
        .clamp(-maxRise, maxFall)
        .toDouble();
    y += vy * dt;
    const minY = ceiling + runnerHeight / 2, maxY = floor - runnerHeight / 2;
    if (y < minY || y > maxY) {
      y = y.clamp(minY, maxY).toDouble();
      vy = 0;
    }
    while (_nextX < distance + viewWidth + .4) {
      _section();
    }
    final x = runnerWorldX;
    for (final o in obstacles) {
      switch (o.kind) {
        case ObstacleKind.sandbag:
          if (!o.falling && o.left - x < speed * .9) o.falling = true;
          if (o.falling && o.bottom < floor) {
            final drop = min(1.3 * dt, floor - o.bottom);
            o
              ..top += drop
              ..bottom += drop;
          }
        case ObstacleKind.drum:
          if (!o.falling && o.left - x <= rollFrom) o.falling = true;
          if (o.falling && o.left > o.anchor) {
            o.left -= min(rollSpeed * dt, o.left - o.anchor);
          }
        case ObstacleKind.drop:
          o.bottom = dropBottom(o.anchor, o.phase, time);
        default:
      }
    }
    const hw = hitHalfWidth, hh = hitHalfHeight;
    if (!invincible) {
      for (final o in obstacles) {
        if (o.left < x + hw &&
            o.right > x - hw &&
            o.top < y + hh &&
            o.bottom > y - hh) {
          over = true;
          hitBy = o.kind;
          vy = 0;
          break;
        }
      }
    }
    for (final p in pickups) {
      if (!p.taken && (p.x - x).abs() < .06 && (p.y - y).abs() < .075) {
        p.taken = true;
        pickupPoints += p.kind.points;
        collected++;
        onPickup?.call(p.kind, p.x, p.y);
      }
    }
    _recycle();
  }

  void _recycle() {
    final left = distance - .2;
    obstacles.removeWhere((o) {
      if (o.right >= left) return false;
      _spareObstacles.add(o);
      return true;
    });
    pickups.removeWhere((p) {
      if (p.x >= left && !p.taken) return false;
      _sparePickups.add(p);
      return true;
    });
  }

  Obstacle _obstacle(
    ObstacleKind kind,
    double left,
    double width,
    double top,
    double bottom,
  ) {
    final o = _spareObstacles.isEmpty
        ? Obstacle()
        : _spareObstacles.removeLast();
    o
      ..kind = kind
      ..left = left
      ..width = width
      ..top = top
      ..bottom = bottom
      ..falling = false;
    obstacles.add(o);
    return o;
  }

  void _pickup(PickupKind kind, double x, double y) {
    final p = _sparePickups.isEmpty ? Pickup() : _sparePickups.removeLast();
    p
      ..kind = kind
      ..x = x
      ..y = y.clamp(ceiling + .06, floor - .06).toDouble()
      ..taken = false;
    pickups.add(p);
  }

  /// Places one section at [_nextX]: an obstacle (or a gap) and maybe a few
  /// pickups in the safe space next to it.
  void _section() {
    final x = _nextX, m = x * RunnerRules.metersPerUnit;
    // The speed when the runner gets here, not the current one.
    final arrival = time + max(0.0, x - runnerWorldX) / max(speed, .01);
    final v = RunnerRules.speedAt(arrival);
    final spacing = max(.6, v * reactionTime(m));
    while (unlocked < debuts.length && score >= debuts[unlocked].$1) {
      unlocked++;
    }
    final ObstacleKind kind;
    if (_debuted < unlocked) {
      // A newly reached obstacle shows itself right away.
      kind = debuts[_debuted++].$2;
      debut = (kind: kind, x: x);
    } else {
      final kinds = [
        ObstacleKind.crate,
        ObstacleKind.flat,
        ObstacleKind.lamp,
        if (m >= 80) ...[ObstacleKind.border, ObstacleKind.border],
        if (m >= 150) ObstacleKind.sandbag,
        for (final (_, kind) in debuts.take(unlocked)) kind,
      ];
      kind = kinds[_random.nextInt(kinds.length)];
    }
    var width = .1;
    // The middle of the safe space, where pickups go.
    double safeY;
    switch (kind) {
      case ObstacleKind.crate:
        width = .12;
        final height = .13 + _random.nextDouble() * .09;
        _obstacle(kind, x, width, floor - height, floor);
        safeY = floor - height - .12;
      case ObstacleKind.flat:
        width = .07;
        final height = .3 + _random.nextDouble() * .22;
        _obstacle(kind, x, width, floor - height, floor);
        safeY = (ceiling + floor - height) / 2;
      case ObstacleKind.lamp:
        width = .1;
        final bottom = ceiling + .22 + _random.nextDouble() * .22;
        _obstacle(kind, x, width, 0, bottom);
        safeY = (bottom + floor) / 2;
      case ObstacleKind.sandbag:
        width = .09;
        _obstacle(kind, x, width, ceiling - .1, ceiling);
        // It lands on the floor; the space above stays free.
        safeY = (ceiling + floor) / 2 - .05;
      case ObstacleKind.border:
        width = .09;
        final gap = gapHeight(m);
        final lowest = ceiling + gap / 2 + .04, highest = floor - gap / 2 - .04;
        // Up to 2000 m a gap never moves further than the runner can climb or
        // sink in the time between two gaps; beyond that it soon can.
        final reach = maxRise * max(0.0, x - _lastGapX) / v * reachFactor(m);
        final center = (lowest + _random.nextDouble() * (highest - lowest))
            .clamp(_lastGapCenter - reach, _lastGapCenter + reach)
            .clamp(lowest, highest)
            .toDouble();
        _obstacle(ObstacleKind.border, x, width, 0, center - gap / 2);
        _obstacle(ObstacleKind.flat, x, width, center + gap / 2, floor);
        _lastGapX = x;
        _lastGapCenter = center;
        safeY = center;
      case ObstacleKind.drum:
        width = .12;
        // Placed a little further on: it rolls back to x by the time the
        // runner gets there, so the space before it stays as long as usual.
        _obstacle(kind, x + rollLead(v), width, floor - width, floor).anchor =
            x;
        safeY = floor - width - .12;
      case ObstacleKind.pile:
        width = .22;
        final height = .2 + _random.nextDouble() * .06;
        _obstacle(kind, x, width, floor - height / 2, floor);
        _obstacle(
          kind,
          x + width / 4,
          width / 2,
          floor - height,
          floor - height / 2,
        );
        safeY = floor - height - .12;
      case ObstacleKind.truss:
        width = .3;
        final bottom = ceiling + .2 + _random.nextDouble() * .16;
        _obstacle(kind, x, width, 0, bottom);
        safeY = (bottom + floor) / 2;
      case ObstacleKind.drop:
        width = .13;
        final phase = _random.nextDouble() * 2 * pi;
        _obstacle(kind, x, width, 0, dropBottom(dropMiddle, phase, time))
          ..anchor = dropMiddle
          ..phase = phase;
        safeY = (dropMiddle + dropSwing + floor) / 2;
    }
    final length = width + spacing;
    _nextX = x + length;
    if (_random.nextDouble() < .55) _pickups(x + width / 2, safeY, length);
  }

  /// A row of pickups worth at most the per-metre budget of the section.
  void _pickups(double x, double y, double length) {
    final budget =
        (length * RunnerRules.metersPerUnit * RunnerRules.pickupPointsPerMeter)
            .floor();
    final roll = _random.nextDouble();
    final row = roll < .1
        ? [PickupKind.star]
        : roll < .4
        ? [PickupKind.mask, PickupKind.mask]
        : [PickupKind.rose, PickupKind.rose, PickupKind.rose];
    var points = 0;
    for (final (i, kind) in row.indexed) {
      if (points + kind.points > budget) break;
      points += kind.points;
      _pickup(kind, x + (i - (row.length - 1) / 2) * .09, y);
    }
    placedPickupPoints += points;
  }
}
