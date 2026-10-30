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

  /// Cable drum that rolls towards the runner along the floor, evenly from
  /// before it comes into the picture until after it has left it: hop over
  /// it.
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

  /// A sandbag is falling or a drum is rolling (a drum always is).
  bool falling = false;

  /// Whether passing it counts for the missions: one per section (the flat
  /// below a border and the top crates of a pile belong to it), and whether
  /// the runner is past it.
  bool counted = false, passed = false;

  /// Where a drum's left edge is when the runner gets to it, or the middle
  /// height of a drop's lower edge.
  double anchor = 0;

  /// When the runner gets to a drum, in seconds of the run: it is at
  /// [anchor] then and rolls at [StageRunner.rollSpeed] all along.
  double meets = 0;

  /// Where a drop is in its ride up and down, in radians.
  double phase = 0;

  double get right => left + width;

  /// Too high for one crate picture, so a crate is drawn differently. Only
  /// a question of the drawing and of what the closing line calls it.
  bool get tall => bottom - top > width * 1.35;
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

  /// A drum rolls towards the runner at this speed (stage heights per
  /// second), never faster or slower, never stopping.
  static const rollSpeed = .3;

  /// The section after a drum stands far enough on that the drum has rolled
  /// past where it stands before it shows on a picture this wide, so the
  /// course is the same on every screen up to it (only still wider ones get
  /// their own); [rollClearance] is what the drawings take beyond their
  /// hitboxes, on both sides together.
  static const rollView = 3.6, rollClearance = .03;

  /// A drum's size, on the floor.
  static const drumWidth = .12;

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

  /// What the Tagesmissionen (`runnerMissions`) need, counted on the way
  /// without allocating: pickups by kind, obstacles passed by kind (indexed
  /// by the enums) and the distance on the floor and right below the fly
  /// loft, within [ceilingZone] of the highest position.
  final List<int> collectedBy = List.filled(PickupKind.values.length, 0);
  final List<int> passedBy = List.filled(ObstacleKind.values.length, 0);
  double groundDistance = 0, ceilingDistance = 0;
  static const ceilingZone = .05;

  int get groundMeters => (groundDistance * RunnerRules.metersPerUnit).floor();
  int get ceilingMeters =>
      (ceilingDistance * RunnerRules.metersPerUnit).floor();
  int collectedOf(PickupKind kind) => collectedBy[kind.index];
  int passedOf(ObstacleKind kind) => passedBy[kind.index];

  /// The run's statistics as the app sends them with the score.
  Map<String, Object> get missionStats => {
    for (final k in PickupKind.values) k.name: collectedBy[k.index],
    'ground': groundMeters,
    'ceiling': ceilingMeters,
    'passed': {
      for (final k in ObstacleKind.values)
        if (passedBy[k.index] > 0) k.name: passedBy[k.index],
    },
  };

  /// Lets tests run long courses without crashing.
  @visibleForTesting
  bool invincible = false;

  /// What ended the run, for the closing line.
  ObstacleKind? hitBy;

  /// Whether that obstacle was [Obstacle.tall].
  bool hitTall = false;

  /// How many of the [debuts] the score has reached.
  int unlocked = 0;

  /// The newest obstacle kind and where its first one stands. The stage
  /// does not announce it; the run's telemetry marks it.
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

  /// Where and when the drum of the last section meets the runner, if it was
  /// one.
  ({double x, double meets})? _drum;

  /// The visible width in stage heights, never less than [viewWidth]; the
  /// runner stays [runnerX] from its left edge. The course is laid out .4
  /// beyond its right edge, so on wide screens, too, every obstacle comes in
  /// from outside the picture. What is laid out and how fast stays the same:
  /// only how early.
  double get view => _view;
  double _view = viewWidth;
  set view(double width) {
    final view = max(viewWidth, width);
    if (view == _view) return;
    final wider = view > _view;
    _view = view;
    // A wider picture (a rotated phone, a resized window) shows its new
    // part filled at once.
    if (wider && !over) _layOut();
  }

  void _layOut() {
    while (_nextX < distance + _view + .4) {
      _section();
    }
  }

  /// Seconds the runner needs for [units] more stage heights at the growing
  /// speed.
  double _secondsFor(double units) {
    const a = RunnerRules.acceleration, top = RunnerRules.maxSpeed;
    final v = speed, rising = (top - v) / a;
    final reach = v * rising + a * rising * rising / 2;
    if (units >= reach) return rising + (units - reach) / top;
    return (sqrt(v * v + 2 * a * units) - v) / a;
  }

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

  /// Height of a gap between a border and a flat; even late in a run the
  /// opening leaves room to correct the runner's height.
  static double gapHeight(double meters) => max(.32, .52 - meters / 6000);

  /// Lower edge of a drop at [time].
  static double dropBottom(double middle, double phase, double time) =>
      middle + dropSwing * sin(2 * pi * time / dropPeriod + phase);

  /// Stage heights a run has covered after [seconds], as [update] counts
  /// them.
  static double unitsAt(double seconds) =>
      RunnerRules.maxMeters(seconds) / RunnerRules.metersPerUnit;

  void update(double dt) {
    dt = dt.clamp(0, .05).toDouble();
    if (over) {
      sinceOver += dt;
      return;
    }
    time += dt;
    final step = speed * dt;
    distance += step;
    vy = (vy + (holding ? -lift : gravity) * dt)
        .clamp(-maxRise, maxFall)
        .toDouble();
    y += vy * dt;
    const minY = ceiling + runnerHeight / 2, maxY = floor - runnerHeight / 2;
    if (y < minY || y > maxY) {
      y = y.clamp(minY, maxY).toDouble();
      vy = 0;
    }
    if (y >= maxY - 1e-9) {
      groundDistance += step;
    } else if (y <= minY + ceilingZone) {
      ceilingDistance += step;
    }
    _layOut();
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
          o.left = o.anchor + rollSpeed * (o.meets - time);
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
          hitTall = o.tall;
          vy = 0;
          break;
        }
      }
    }
    if (!over) {
      for (final o in obstacles) {
        if (o.counted && !o.passed && o.right < x - hw) {
          o.passed = true;
          passedBy[o.kind.index]++;
        }
      }
    }
    for (final p in pickups) {
      if (!p.taken && (p.x - x).abs() < .06 && (p.y - y).abs() < .075) {
        p.taken = true;
        pickupPoints += p.kind.points;
        collected++;
        collectedBy[p.kind.index]++;
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
      ..falling = false
      ..counted = false
      ..passed = false;
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
    final x = _pastDrum(_nextX), m = x * RunnerRules.metersPerUnit;
    _drum = null;
    // The speed when the runner gets here, not the current one. It is
    // estimated as on the narrowest picture, from [lead] ahead: a wider one
    // lays the course out earlier, but must not lay out another one.
    const lead = viewWidth + .4 - runnerX;
    final ahead = max(0.0, x - runnerWorldX);
    final then = ahead > lead ? time + _secondsFor(ahead - lead) : time;
    final arrival =
        then + min(ahead, lead) / max(RunnerRules.speedAt(then), .01);
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
    final first = obstacles.length;
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
        width = drumWidth;
        // It gets to x just when the runner does, so the space before it is
        // as long as usual; until then it is further on, rolling.
        final meets =
            time + _secondsFor(max(0.0, x - hitHalfWidth - runnerWorldX));
        final left = x + rollSpeed * (meets - time);
        _obstacle(kind, left, width, floor - width, floor)
          ..falling = true
          ..anchor = x
          ..meets = meets;
        _drum = (x: x, meets: meets);
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
    obstacles[first].counted = true;
    final length = width + spacing;
    _nextX = x + length;
    if (_random.nextDouble() < .55) _pickups(x + width / 2, safeY, length);
  }

  /// Where the section that would start at [x] starts instead, so that the
  /// drum before it (if any) does not roll over it in the picture: by the
  /// time it shows on the right, even of a [rollView] wide picture, the drum
  /// has rolled past it. Only ever further on; early in a run, when the
  /// runner is slow, by a few hundredths.
  double _pastDrum(double x) {
    final drum = _drum;
    if (drum == null) return x;
    final view = max(rollView, _view);
    bool clear(double x) {
      // When the drum's right edge has rolled past x, and how far the runner
      // has come by then (counted from now, either way).
      final at =
          drum.meets - (x - rollClearance - drumWidth - drum.x) / rollSpeed;
      final then = distance + unitsAt(at) - unitsAt(time);
      return then + view <= x - rollClearance;
    }

    while (!clear(x)) {
      x += .01;
    }
    return x;
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
