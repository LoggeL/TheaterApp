import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/app_controller.dart';
import '../data/wardrobe_api.dart';
import '../domain/stage_runner.dart';
import 'stage_runner_art.dart';

/// A colour matrix that turns the hue by [WardrobeTint.hue] degrees and
/// scales saturation and brightness; null for no change.
ColorFilter? tintFilter(WardrobeTint? tint) {
  if (tint == null) return null;
  if (tint.hue == 0 && tint.saturation == 1 && tint.brightness == 1) {
    return null;
  }
  return ColorFilter.matrix(tintMatrix(tint));
}

@visibleForTesting
List<double> tintMatrix(WardrobeTint tint) {
  // Hue rotation around the luminance axis (as in CSS hue-rotate), then
  // saturation towards the same luminance, then brightness.
  final a = tint.hue * pi / 180, c = cos(a), s = sin(a);
  const lr = .213, lg = .715, lb = .072;
  final hue = [
    lr + c * (1 - lr) + s * -lr,
    lg + c * -lg + s * -lg,
    lb + c * -lb + s * (1 - lb),
    lr + c * -lr + s * .143,
    lg + c * (1 - lg) + s * .14,
    lb + c * -lb + s * -.283,
    lr + c * -lr + s * -(1 - lr),
    lg + c * -lg + s * lg,
    lb + c * (1 - lb) + s * lb,
  ];
  final t = tint.saturation;
  final sat = [
    lr + (1 - lr) * t,
    lg - lg * t,
    lb - lb * t,
    lr - lr * t,
    lg + (1 - lg) * t,
    lb - lb * t,
    lr - lr * t,
    lg - lg * t,
    lb + (1 - lb) * t,
  ];
  final m = List<double>.filled(9, 0);
  for (var r = 0; r < 3; r++) {
    for (var col = 0; col < 3; col++) {
      var v = 0.0;
      for (var k = 0; k < 3; k++) {
        v += sat[r * 3 + k] * hue[k * 3 + col];
      }
      m[r * 3 + col] = v * tint.brightness;
    }
  }
  return [
    m[0], m[1], m[2], 0, 0, //
    m[3], m[4], m[5], 0, 0,
    m[6], m[7], m[8], 0, 0,
    0, 0, 0, 1, 0,
  ];
}

/// Sepia for the antique (legacy) cards.
const antiqueFilter = ColorFilter.matrix([
  .393, .769, .189, 0, 0, //
  .349, .686, .168, 0, 0,
  .272, .534, .131, 0, 0,
  0, 0, 0, 1, 0,
]);

/// Pictures of the wardrobe from the server, decoded once per session.
/// Only what is worn or shown gets loaded; a failure (offline) leaves the
/// default art in its place and is tried again next time.
abstract final class WardrobePictures {
  static final _images = <String, ui.Image>{};
  static final _loading = <String, Future<ui.Image?>>{};

  /// Already decoded, without waiting.
  static ui.Image? cached(String? path) => path == null ? null : _images[path];

  static Future<ui.Image?> load(AppController controller, String? path) {
    if (path == null) return Future.value();
    final done = _images[path];
    if (done != null) return Future.value(done);
    // A block body: an arrow would hand whenComplete the removed future,
    // which is this very one, and it would wait for itself.
    return _loading[path] ??= _fetch(controller, path).whenComplete(() {
      _loading.remove(path);
    });
  }

  static Future<ui.Image?> _fetch(AppController controller, String path) async {
    try {
      final media = await controller.mediaBytes(path, cache: false);
      final codec = await ui.instantiateImageCodec(media.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      // A long session never keeps more than a few dozen pictures.
      if (_images.length > 48) _images.remove(_images.keys.first);
      return _images[path] = frame.image;
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Bild $path fehlt: $e');
      return null;
    }
  }

  @visibleForTesting
  static void clear() {
    _images.clear();
    _loading.clear();
  }
}

/// The game's art in the worn costume of [wardrobe]. An atlas that does not
/// load or does not have the size of the game's atlas is replaced by the
/// default one, tinted if the item says so. Hitbox and course stay the same
/// whatever is worn.
Future<RunnerArt> dressArt(
  RunnerArt base,
  Wardrobe wardrobe,
  AppController controller,
) async {
  WardrobeItem? worn(WardrobeKind kind) {
    final item = wardrobe.worn(kind);
    return item == null || item.isDefault ? null : item;
  }

  // The worn role of the character, if one is chosen.
  final plain = worn(WardrobeKind.character);
  final character = plain?.inRole(wardrobe.variantOf(plain));
  final shiny = plain != null && wardrobe.isShiny(plain);
  final obstacles = worn(WardrobeKind.obstacles);
  final backdrop = worn(WardrobeKind.backdrop);
  final fx = worn(WardrobeKind.fx);
  bool fits(ui.Image? image) =>
      image != null &&
      image.width == base.atlas.width &&
      image.height == base.atlas.height;
  final images = await Future.wait([
    WardrobePictures.load(controller, character?.image),
    WardrobePictures.load(controller, obstacles?.image),
    WardrobePictures.load(controller, backdrop?.image),
  ]);
  final runner = fits(images[0]) ? images[0] : null;
  final set = fits(images[1]) ? images[1] : null;
  if (kDebugMode && images[0] != null && runner == null) {
    debugPrint('Bühnenlauf: Figurenatlas ${character?.id} hat falsche Maße');
  }
  final effect = fx?.effect;
  return base.dressed(
    runner: runner,
    obstacles: set,
    backdrop: images[2],
    runnerFilter: tintFilter(character?.tint),
    obstacleFilter: tintFilter(obstacles?.tint),
    backdropFilter: tintFilter(backdrop?.tint),
    harness: {
      for (final sprite in RunnerSprite.values)
        if (character?.harness[sprite.name] case (final x, final y))
          sprite: ui.Offset(x, y),
    },
    effect: effect == null && !shiny
        ? null
        : RunnerEffectStyle(
            effect?.trail ?? '',
            effect?.colors ?? const [],
            shine: shiny,
          ),
  );
}

/// The trail of a worn effect behind the runner, in a fixed pool like the
/// other effects. Coordinates are in stage heights of the visible stage.
class RunnerTrail {
  RunnerTrail({Random? random}) : _random = random ?? Random();
  final Random _random;

  static const size = 56;
  final x = Float32List(size), y = Float32List(size);
  final vx = Float32List(size), vy = Float32List(size);
  final life = Float32List(size), radius = Float32List(size);
  final spin = Float32List(size), tint = Uint8List(size);
  int _next = 0;
  double _carry = 0;

  RunnerEffectStyle? _style;
  List<Paint> _paints = const [];

  /// Particles per second and how long they last, by trail.
  static (double, double) _rate(String trail) => switch (trail) {
    'confetti' => (32, .9),
    'smoke' => (16, 1.1),
    'stars' => (14, .8),
    _ => (40, .45),
  };

  /// Where the runner was at the last update, for the shine; and the time
  /// the glints twinkle by.
  double _runnerY = StageRunner.floor - StageRunner.runnerHeight / 2;
  double _time = 0;

  void update(double dt, StageRunner game, RunnerEffectStyle? style) {
    dt = dt.clamp(0, .05).toDouble();
    _runnerY = game.y;
    _time += dt;
    // The trail stays where it was left: the stage moves on under it.
    final drift = game.over ? 0.0 : game.speed * dt;
    for (var i = 0; i < size; i++) {
      if (life[i] <= 0) continue;
      life[i] -= dt;
      x[i] += vx[i] * dt - drift;
      y[i] += vy[i] * dt;
      spin[i] += dt * 6;
    }
    if (style == null || style.trail.isEmpty || game.over) return;
    final (rate, lifetime) = _rate(style.trail);
    _carry += dt * rate;
    while (_carry >= 1) {
      _carry -= 1;
      final i = _next;
      _next = (_next + 1) % size;
      x[i] = StageRunner.runnerX - .03 + _random.nextDouble() * .02;
      y[i] =
          game.y + (_random.nextDouble() - .5) * StageRunner.runnerHeight * .6;
      vx[i] = -.05 - _random.nextDouble() * .1;
      vy[i] = style.trail == 'smoke'
          ? -.05 - _random.nextDouble() * .05
          : (_random.nextDouble() - .5) * .2 +
                (style.trail == 'confetti' ? .15 : 0);
      life[i] = lifetime * (.7 + _random.nextDouble() * .3);
      radius[i] = switch (style.trail) {
        'smoke' => .018 + _random.nextDouble() * .012,
        'stars' => .012 + _random.nextDouble() * .006,
        'confetti' => .007 + _random.nextDouble() * .004,
        _ => .004 + _random.nextDouble() * .004,
      };
      spin[i] = _random.nextDouble() * pi;
      tint[i] = style.colors.isEmpty ? 0 : _random.nextInt(style.colors.length);
    }
  }

  final _path = Path();

  void paint(Canvas canvas, double s, RunnerEffectStyle? style) {
    if (style == null) return;
    if (style.shine) paintShine(canvas, s, _runnerY, _time);
    if (style.trail.isEmpty) return;
    if (!identical(style, _style)) {
      _style = style;
      final colors = style.colors.isEmpty
          ? const [Color(0xFFFFF4C2)]
          : style.colors;
      _paints = [
        for (final c in colors)
          Paint()
            ..color = style.trail == 'smoke' ? c.withValues(alpha: .28) : c,
      ];
    }
    final (_, lifetime) = _rate(style.trail);
    for (var i = 0; i < size; i++) {
      final l = life[i];
      if (l <= 0) continue;
      final paint = _paints[tint[i] % _paints.length];
      final c = Offset(x[i] * s, y[i] * s);
      final fade = min(1.0, l / lifetime * 2);
      switch (style.trail) {
        case 'smoke':
          // Grows while it fades.
          canvas.drawCircle(c, radius[i] * s * (2 - fade), paint);
        case 'confetti':
          final r = radius[i] * s * fade;
          canvas
            ..save()
            ..translate(c.dx, c.dy)
            ..rotate(spin[i])
            ..drawRect(Rect.fromLTWH(-r, -r * .5, r * 2, r), paint)
            ..restore();
        case 'stars':
          final r = radius[i] * s * fade;
          _path
            ..reset()
            ..moveTo(c.dx, c.dy - r)
            ..lineTo(c.dx + r * .3, c.dy - r * .3)
            ..lineTo(c.dx + r, c.dy)
            ..lineTo(c.dx + r * .3, c.dy + r * .3)
            ..lineTo(c.dx, c.dy + r)
            ..lineTo(c.dx - r * .3, c.dy + r * .3)
            ..lineTo(c.dx - r, c.dy)
            ..lineTo(c.dx - r * .3, c.dy - r * .3)
            ..close();
          canvas.drawPath(_path, paint);
        default:
          canvas.drawCircle(c, radius[i] * s * fade, paint);
      }
    }
  }
}

final _cone = Paint(), _halo = Paint(), _glint = Paint();
final _glintPath = Path();

/// Gold, white and a touch of colour: the glints of a shiny character.
const shineColors = [
  Color(0xFFFFF4C2),
  Color(0xFFFFFFFF),
  Color(0xFFFFD86B),
  Color(0xFFB8F1FF),
  Color(0xFFFFC2F0),
];

/// A four-pointed glint of [radius] at [c].
void paintGlint(Canvas canvas, Offset c, double radius, Paint paint) {
  final r = radius, w = radius * .22;
  _glintPath
    ..reset()
    ..moveTo(c.dx, c.dy - r)
    ..lineTo(c.dx + w, c.dy - w)
    ..lineTo(c.dx + r, c.dy)
    ..lineTo(c.dx + w, c.dy + w)
    ..lineTo(c.dx, c.dy + r)
    ..lineTo(c.dx - w, c.dy + w)
    ..lineTo(c.dx - r, c.dy)
    ..lineTo(c.dx - w, c.dy - w)
    ..close();
  canvas.drawPath(_glintPath, paint);
}

/// The shine of a shiny character on stage: a spotlight from the fly
/// gallery onto the runner at height [y] (in stage heights), a soft halo and
/// glints twinkling around it, behind the figure. [s] is the stage height in
/// pixels, [time] seconds.
void paintShine(Canvas canvas, double s, double y, double time) {
  final cx = StageRunner.runnerX * s, cy = y * s;
  final r = StageRunner.runnerHeight * s;
  final pulse = .75 + .25 * sin(time * 2.4);
  final bottom = cy + r * .6;
  _cone.shader = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      const Color(0x00FFF4C2),
      Color.fromRGBO(255, 244, 194, .26 * pulse),
    ],
  ).createShader(Rect.fromLTRB(cx - r, 0, cx + r, bottom));
  canvas.drawPath(
    Path()
      ..moveTo(cx - r * .12, 0)
      ..lineTo(cx + r * .12, 0)
      ..lineTo(cx + r * 1.1, bottom)
      ..lineTo(cx - r * 1.1, bottom)
      ..close(),
    _cone,
  );
  _halo.shader = RadialGradient(
    colors: [
      Color.fromRGBO(255, 236, 170, .55 * pulse),
      const Color(0x00FFECAA),
    ],
  ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r * 1.1));
  canvas.drawCircle(Offset(cx, cy), r * 1.1, _halo);
  for (var i = 0; i < 10; i++) {
    final twinkle = sin(time * 4.2 + i * 1.9);
    if (twinkle <= -.3) continue;
    final a = i * 2 * pi / 10 + time * .9;
    final d = r * (.58 + .16 * sin(time * 2.7 + i));
    _glint.color = shineColors[i % shineColors.length].withValues(
      alpha: (.4 + .6 * twinkle).clamp(0, 1).toDouble(),
    );
    paintGlint(
      canvas,
      Offset(cx + cos(a) * d, cy + sin(a) * d * .9),
      r * (.11 + .09 * twinkle),
      _glint,
    );
  }
}
