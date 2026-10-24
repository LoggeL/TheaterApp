import 'dart:math';
import 'dart:typed_data';

import '../domain/stage_runner.dart';
import 'stage_runner_sound.dart';

/// A short line shown above the runner, e.g. "+10".
class RunnerPopup {
  String text = '';
  double x = 0, y = 0, age = 1;
  bool get alive => age < RunnerFx.popupLife;
}

/// Juice of a run that does not touch the score: sparkles, point popups,
/// milestone banners, the crash shake and the sounds that go with them.
/// Coordinates are in stage heights relative to the visible stage.
///
/// Everything lives in fixed pools, so a run allocates nothing per frame.
class RunnerFx {
  RunnerFx({Random? random, this.best, this.onSound})
    : _random = random ?? Random();

  final Random _random;

  /// The player's best score before this run, if known.
  final int? best;
  final void Function(RunnerSfx sfx)? onSound;

  static const maxParticles = 64, popupLife = .7, bannerLife = 1.6;
  static const cheerTime = .35, shakeTime = .35;

  final px = Float32List(maxParticles), py = Float32List(maxParticles);
  final vx = Float32List(maxParticles), vy = Float32List(maxParticles);
  final life = Float32List(maxParticles), size = Float32List(maxParticles);

  /// Index into the painter's particle colours (a [PickupKind] index, or
  /// [dust] for the crash).
  final tint = Uint8List(maxParticles);
  static const dust = 3;
  int _nextParticle = 0;

  final popups = List.generate(6, (_) => RunnerPopup());
  int _nextPopup = 0;

  String? banner;
  double bannerAge = bannerLife;
  bool get showsBanner => banner != null && bannerAge < bannerLife;

  /// Seconds left of the cheering pose.
  double cheer = 0;
  double _sinceWhoosh = 99;
  bool _wasHolding = false, _crashed = false, _curtain = false;
  bool recordBroken = false;
  int _milestone = 0;
  ObstacleKind? _announced;

  /// The metres that get a banner, then every further thousand.
  static int milestoneAt(int index) => switch (index) {
    0 => 100,
    1 => 500,
    2 => 1000,
    _ => (index - 1) * 1000,
  };

  static String milestoneText(int meters) => switch (meters) {
    100 => '100 m – Applaus!',
    500 => '500 m – Szenenapplaus!',
    1000 => '1000 m – Zugabe!',
    2000 => '2000 m – Standing Ovations!',
    _ => '$meters m – Bühnenlegende!',
  };

  /// The banner for a new kind of obstacle.
  static String debutText(ObstacleKind kind) => 'Neu: ${obstacleName(kind)}!';

  void _banner(String text) {
    banner = text;
    bannerAge = 0;
  }

  /// A pickup was taken at [viewX], [y].
  void pickup(PickupKind kind, double viewX, double y) {
    cheer = cheerTime;
    onSound?.call(switch (kind) {
      PickupKind.rose => RunnerSfx.rose,
      PickupKind.mask => RunnerSfx.mask,
      PickupKind.star => RunnerSfx.star,
    });
    final p = popups[_nextPopup];
    _nextPopup = (_nextPopup + 1) % popups.length;
    p
      ..text = '+${kind.points}'
      ..x = viewX
      ..y = y - .06
      ..age = 0;
    final count = kind == PickupKind.star ? 14 : 8;
    for (var i = 0; i < count; i++) {
      final angle = _random.nextDouble() * 2 * pi;
      final speed = .25 + _random.nextDouble() * .45;
      _particle(
        viewX,
        y,
        cos(angle) * speed,
        sin(angle) * speed - .2,
        .35 + _random.nextDouble() * .3,
        .006 + _random.nextDouble() * .008,
        kind.index,
      );
    }
  }

  void _particle(
    double x,
    double y,
    double vx0,
    double vy0,
    double lifetime,
    double radius,
    int color,
  ) {
    final i = _nextParticle;
    _nextParticle = (i + 1) % maxParticles;
    px[i] = x;
    py[i] = y;
    vx[i] = vx0;
    vy[i] = vy0;
    life[i] = lifetime;
    size[i] = radius;
    tint[i] = color;
  }

  /// Advances the effects after [game] moved by [dt].
  void update(double dt, StageRunner game) {
    dt = dt.clamp(0, .05).toDouble();
    _sinceWhoosh += dt;
    cheer = max(0, cheer - dt);
    if (bannerAge < bannerLife) bannerAge += dt;
    for (final p in popups) {
      if (p.alive) p.age += dt;
    }
    for (var i = 0; i < maxParticles; i++) {
      if (life[i] <= 0) continue;
      life[i] -= dt;
      vy[i] += 1.4 * dt;
      px[i] += vx[i] * dt;
      py[i] += vy[i] * dt;
    }
    if (game.over) {
      if (!_crashed) {
        _crashed = true;
        onSound?.call(RunnerSfx.crash);
        final x = StageRunner.runnerX, y = game.y;
        for (var i = 0; i < 12; i++) {
          final angle = pi + _random.nextDouble() * pi;
          _particle(
            x,
            y + StageRunner.runnerHeight / 2,
            cos(angle) * .4,
            sin(angle) * .3,
            .4 + _random.nextDouble() * .3,
            .01 + _random.nextDouble() * .01,
            dust,
          );
        }
      }
      if (!_curtain && game.sinceOver >= .25) {
        _curtain = true;
        onSound?.call(RunnerSfx.curtain);
      }
      return;
    }
    // A pull on the wire when holding starts, not more than every 0.7 s.
    if (game.holding && !_wasHolding && _sinceWhoosh > .7) {
      _sinceWhoosh = 0;
      onSound?.call(RunnerSfx.whoosh);
    }
    _wasHolding = game.holding;
    if (game.meters >= milestoneAt(_milestone)) {
      _banner(milestoneText(milestoneAt(_milestone)));
      _milestone++;
      onSound?.call(RunnerSfx.bravo);
    }
    // A new obstacle is announced when its first one comes into view.
    final debut = game.debut;
    if (debut != null &&
        debut.kind != _announced &&
        debut.x - game.distance < StageRunner.viewWidth) {
      _announced = debut.kind;
      _banner(debutText(debut.kind));
    }
    final best = this.best;
    if (!recordBroken && best != null && best > 0 && game.score > best) {
      recordBroken = true;
      _banner('Neuer Rekord!');
      onSound?.call(RunnerSfx.record);
    }
  }

  /// Screen offset of the crash shake, in stage heights.
  (double, double) shake(StageRunner game) {
    if (!game.over || game.sinceOver >= shakeTime) return (0, 0);
    final strength = .018 * (1 - game.sinceOver / shakeTime);
    final t = game.sinceOver * 70;
    return (sin(t) * strength, cos(t * 1.3) * strength * .7);
  }
}

/// The name of an obstacle, as the stage announces it.
String obstacleName(ObstacleKind kind) => switch (kind) {
  ObstacleKind.crate => 'Requisitenkiste',
  ObstacleKind.flat => 'Kulisse',
  ObstacleKind.lamp => 'Scheinwerfer',
  ObstacleKind.border => 'Soffitte',
  ObstacleKind.sandbag => 'Sandsack',
  ObstacleKind.drum => 'Kabeltrommel',
  ObstacleKind.pile => 'Kistenstapel',
  ObstacleKind.truss => 'Lichttraverse',
  ObstacleKind.drop => 'Prospekt',
};

/// A line for the falling curtain, now and then about what was hit.
String curtainLine(ObstacleKind? hitBy, Random random) {
  const general = [
    'Text vergessen!',
    'Der Souffleur ist eingeschlafen.',
    'Toi, toi, toi fürs nächste Mal!',
    'Das war so nicht geprobt!',
    'Abgang – leider nicht nach Drehbuch.',
    'Engel Logge braucht eine Pause.',
    'Die Locken sitzen noch. Alles andere nicht.',
    'Ein Heiligenschein ist kein Helm.',
    'Der Inspizient schlägt die Hände über dem Kopf zusammen.',
    'Kein Beinbruch – nur ein Flügelbruch.',
    'Bühnenreif. Nur die Landung nicht.',
  ];
  final specific = switch (hitBy) {
    ObstacleKind.crate => 'Über die Requisitenkiste gestolpert.',
    ObstacleKind.flat => 'Die Kulisse stand genau da, wo sie hingehört.',
    ObstacleKind.border => 'Mitten in den Soffitten hängen geblieben.',
    ObstacleKind.lamp => 'Ins Scheinwerferlicht geflogen. Wörtlich.',
    ObstacleKind.sandbag => 'Der Sandsack hatte Vorfahrt.',
    ObstacleKind.drum => 'Von der Kabeltrommel überrollt.',
    ObstacleKind.pile => 'Der Kistenstapel war höher als gedacht.',
    ObstacleKind.truss => 'An der Lichttraverse hängen geblieben.',
    ObstacleKind.drop => 'Der Prospekt kam von oben. Wie geprobt.',
    null => null,
  };
  if (specific != null && random.nextBool()) return specific;
  return general[random.nextInt(general.length)];
}
