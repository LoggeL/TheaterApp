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

/// Pictures of the wardrobe from the server, decoded once and kept while
/// they fit into [maxBytes]. Only what is worn or shown gets loaded; a
/// failure (offline) is tried again next time.
///
/// The cache only decides what stays without a holder: whoever shows a
/// picture keeps the image it got (the dressed [RunnerArt], a card's state,
/// the crate's reel), so a picture dropped from here never vanishes from the
/// screen; it is fetched again when it is needed anew.
abstract final class WardrobePictures {
  // In the order of last use: the first one is dropped first.
  static final _images = <String, ui.Image>{};
  static final _loading = <String, Future<ui.Image?>>{};
  static int _bytes = 0;

  /// Decoded bytes kept at most. A portrait takes 1 MB (512²), an atlas or
  /// backdrop about 2.5 MB: about a screen of cards with the worn costume
  /// and the reel of a crate. Less in the browser (the PWA), whose memory
  /// a tab shares with everything else.
  @visibleForTesting
  static int maxBytes = (kIsWeb ? 32 : 48) << 20;

  /// The decoded size of the kept pictures, for tests.
  @visibleForTesting
  static int get bytes => _bytes;

  /// Already decoded, without waiting; null if never loaded or dropped.
  static ui.Image? cached(String? path) {
    if (path == null) return null;
    final image = _images.remove(path);
    if (image != null) _images[path] = image;
    return image;
  }

  static int _sizeOf(ui.Image image) => image.width * image.height * 4;

  static void _keep(String path, ui.Image image) {
    final old = _images.remove(path);
    if (old != null) _bytes -= _sizeOf(old);
    _images[path] = image;
    _bytes += _sizeOf(image);
    // Not disposed: a holder may still draw it; it goes with its last one.
    while (_bytes > maxBytes && _images.length > 1) {
      final first = _images.keys.first;
      _bytes -= _sizeOf(_images.remove(first)!);
    }
  }

  /// The longest side, in device pixels, a portrait is decoded with on a
  /// screen of [devicePixelRatio]: enough for the largest card showing one
  /// (the crate's won card, 200 wide). Portraits are 512² on the server, so
  /// only screens below a ratio of 2.56 save (the PWA on a desktop most).
  static int portraitPixels(double devicePixelRatio) =>
      (200 * devicePixelRatio).ceil();

  /// [load] for a portrait, decoded only as large as [portraitPixels] on
  /// this screen (without a view: as for a ratio of 3, i.e. full size).
  static Future<ui.Image?> loadPortrait(
    AppController controller,
    String? path,
  ) => load(
    controller,
    path,
    maxPixels: portraitPixels(
      ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 3,
    ),
  );

  /// The picture at [path]; [maxPixels] decodes it smaller if its longer
  /// side exceeds that (never larger). The first load of a path decides its
  /// size, so a path is always loaded with the same [maxPixels].
  static Future<ui.Image?> load(
    AppController controller,
    String? path, {
    int? maxPixels,
  }) {
    if (path == null) return Future.value();
    final done = cached(path);
    if (done != null) return Future.value(done);
    // A block body: an arrow would hand whenComplete the removed future,
    // which is this very one, and it would wait for itself.
    return _loading[path] ??= _fetch(controller, path, maxPixels).whenComplete(
      () {
        _loading.remove(path);
      },
    );
  }

  static Future<ui.Image?> _fetch(
    AppController controller,
    String path,
    int? maxPixels,
  ) async {
    try {
      final media = await controller.mediaBytes(path, cache: false);
      final buffer = await ui.ImmutableBuffer.fromUint8List(media.bytes);
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (w, h) {
          final scale = maxPixels == null ? 1.0 : maxPixels / max(w, h);
          return scale >= 1
              ? const ui.TargetImageSize()
              : ui.TargetImageSize(
                  width: max(1, (w * scale).round()),
                  height: max(1, (h * scale).round()),
                );
        },
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      _keep(path, frame.image);
      return frame.image;
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Bild $path fehlt: $e');
      return null;
    }
  }

  /// Like [load], but a picture that fails (a dropped connection, a server
  /// just restarting) is asked for once more after [retryDelay]; only then
  /// does the caller fall back to the default art.
  static Future<ui.Image?> loadOrRetry(
    AppController controller,
    String? path,
  ) async {
    final image = await load(controller, path);
    if (image != null || path == null) return image;
    await Future<void>.delayed(retryDelay);
    final again = await load(controller, path);
    if (kDebugMode && again == null) {
      debugPrint('Bühnenlauf: Bild $path fehlt auch beim zweiten Versuch');
    }
    return again;
  }

  /// The pause before the second try of [loadOrRetry].
  @visibleForTesting
  static Duration retryDelay = const Duration(seconds: 1);

  @visibleForTesting
  static void clear() {
    _images.clear();
    _loading.clear();
    _bytes = 0;
  }
}

/// The game's art in the worn costume of [wardrobe]. An atlas that does not
/// load on a second try either ([WardrobePictures.loadOrRetry]) or does not
/// have the size of the game's atlas is replaced by the
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
  final backdrop = worn(WardrobeKind.backdrop);
  // A backdrop with obstacles of its own brings them along (the default
  // stage keeps the game's own); otherwise the worn obstacle set counts.
  final stageSet = backdrop?.obstacles;
  final obstacles = stageSet == null ? worn(WardrobeKind.obstacles) : null;
  final fx = worn(WardrobeKind.fx);
  bool fits(ui.Image? image) =>
      image != null &&
      image.width == base.atlas.width &&
      image.height == base.atlas.height;
  // A picture that fails is tried once more before the default art stands
  // in for it (Engel Logge instead of the worn figure).
  final images = await Future.wait([
    WardrobePictures.loadOrRetry(controller, character?.image),
    WardrobePictures.loadOrRetry(controller, stageSet ?? obstacles?.image),
    WardrobePictures.loadOrRetry(controller, backdrop?.image),
    // The backdrop's own collectibles; without them the game's own.
    WardrobePictures.loadOrRetry(controller, backdrop?.collectibles),
  ]);
  final runner = fits(images[0]) ? images[0] : null;
  final set = fits(images[1]) ? images[1] : null;
  if (kDebugMode && character?.image != null && runner == null) {
    debugPrint(
      images[0] == null
          ? 'Bühnenlauf: Figurenatlas ${character?.image} fehlt, '
                'Standardfigur statt ${character?.id}'
          : 'Bühnenlauf: Figurenatlas ${character?.id} hat falsche Maße '
                '${images[0]!.width}×${images[0]!.height}',
    );
  }
  final effect = fx?.effect;
  return base.dressed(
    runner: runner,
    obstacles: set,
    pickups: fits(images[3]) ? images[3] : null,
    backdrop: images[2],
    runnerFilter: tintFilter(character?.tint),
    obstacleFilter: tintFilter(obstacles?.tint),
    backdropFilter: tintFilter(backdrop?.tint),
    harness: {
      for (final sprite in RunnerSprite.values)
        if (character?.harness[sprite.name] case (final x, final y))
          sprite: ui.Offset(x, y),
    },
    border: backdrop?.borderColor,
    pickupNames: {
      for (final kind in PickupKind.values)
        kind: ?backdrop?.collectibleNames[kind.name],
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

  /// The time the shine sweeps and the glints twinkle by, in seconds.
  double get time => _time;
  double _time = 0;

  /// The glints of a shiny character, in their own fixed pool. A glint
  /// either sits on the figure ([glintLeft] 0; [glintX] and [glintY] in
  /// half its width and height from its middle, so it stays with the figure
  /// in every pose) or was left behind in flight ([glintLeft] 1; in stage
  /// heights, drifting off with the stage: a short trail of sparkles).
  static const glints = 28;
  final glintX = Float32List(glints), glintY = Float32List(glints);
  final glintLife = Float32List(glints), glintSpan = Float32List(glints);
  final glintSize = Float32List(glints);
  final glintTint = Uint8List(glints), glintLeft = Uint8List(glints);
  int _nextGlint = 0;
  double _glintCarry = 0;

  void update(double dt, StageRunner game, RunnerEffectStyle? style) {
    dt = dt.clamp(0, .05).toDouble();
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
    _updateGlints(dt, game, style);
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

  void _updateGlints(double dt, StageRunner game, RunnerEffectStyle? style) {
    for (var i = 0; i < glints; i++) {
      if (glintLife[i] <= 0) continue;
      glintLife[i] -= dt;
      // Left behind, they fall back at their own pace whatever the speed
      // of the run: the trail stays short.
      if (glintLeft[i] == 1) {
        glintX[i] -= .3 * dt;
        glintY[i] += .03 * dt;
      }
    }
    if (style == null || !style.shine) return;
    final flying =
        !game.over &&
        game.y < StageRunner.floor - StageRunner.runnerHeight / 2 - .001;
    _glintCarry += dt * (flying ? 20 : 7);
    while (_glintCarry >= 1) {
      _glintCarry -= 1;
      final i = _nextGlint;
      _nextGlint = (_nextGlint + 1) % glints;
      final behind = flying && _random.nextDouble() < .55;
      glintLeft[i] = behind ? 1 : 0;
      if (behind) {
        glintX[i] = StageRunner.runnerX - .02 - _random.nextDouble() * .035;
        glintY[i] =
            game.y +
            (_random.nextDouble() - .5) * StageRunner.runnerHeight * .7;
      } else {
        // Along the outline of the figure, a little in or out.
        final a = _random.nextDouble() * 2 * pi;
        final r = .7 + _random.nextDouble() * .35;
        glintX[i] = cos(a) * r;
        glintY[i] = sin(a) * r;
      }
      glintLife[i] = glintSpan[i] = behind
          ? .35 + _random.nextDouble() * .2
          : .55 + _random.nextDouble() * .35;
      glintSize[i] = .007 + _random.nextDouble() * .007;
      glintTint[i] = _random.nextInt(shineColors.length);
    }
  }

  /// The glints of a shiny character, in front of the figure drawn in
  /// [body]; [s] is the stage height in pixels. Nothing else: no light on
  /// the stage, so the shine belongs to the figure wherever it is.
  void paintGlints(Canvas canvas, Rect body, double s) {
    final cx = (body.left + body.right) / 2, hx = body.width / 2;
    final cy = (body.top + body.bottom) / 2, hy = body.height / 2;
    for (var i = 0; i < glints; i++) {
      final l = glintLife[i];
      if (l <= 0) continue;
      // Each glint grows, flashes and fades again.
      final flash = sin(pi * l / glintSpan[i]);
      final behind = glintLeft[i] == 1;
      _glint.color = shineColor(glintTint[i], flash);
      paintGlintAt(
        canvas,
        behind ? glintX[i] * s : cx + glintX[i] * hx,
        behind ? glintY[i] * s : cy + glintY[i] * hy,
        glintSize[i] * s * (.35 + .65 * flash),
        _glint,
      );
    }
  }

  final _path = Path();

  void paint(Canvas canvas, double s, RunnerEffectStyle? style) {
    if (style == null) return;
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

final _glint = Paint();
final _glintPath = Path();

/// Gold, white and a touch of colour: the glints of a shiny character.
const shineColors = [
  Color(0xFFFFF4C2),
  Color(0xFFFFFFFF),
  Color(0xFFFFD86B),
  Color(0xFFB8F1FF),
  Color(0xFFFFC2F0),
];

/// [shineColors] at sixteen steps of opacity, made once: the glints change
/// their opacity every frame without new colours.
final _shineSteps = [
  for (final c in shineColors)
    for (var a = 0; a < 16; a++) c.withValues(alpha: a / 15),
];

/// The [tint]th of [shineColors] at about [opacity].
Color shineColor(int tint, double opacity) =>
    _shineSteps[(tint % shineColors.length) * 16 +
        (opacity.clamp(0, 1) * 15).round()];

/// A four-pointed glint of [radius] at [c].
void paintGlint(Canvas canvas, Offset c, double radius, Paint paint) =>
    paintGlintAt(canvas, c.dx, c.dy, radius, paint);

/// A four-pointed glint of [radius] at ([x], [y]).
void paintGlintAt(
  Canvas canvas,
  double x,
  double y,
  double radius,
  Paint paint,
) {
  final r = radius, w = radius * .22;
  _glintPath
    ..reset()
    ..moveTo(x, y - r)
    ..lineTo(x + w, y - w)
    ..lineTo(x + r, y)
    ..lineTo(x + w, y + w)
    ..lineTo(x, y + r)
    ..lineTo(x - w, y + w)
    ..lineTo(x - r, y)
    ..lineTo(x - w, y - w)
    ..close();
  canvas.drawPath(_glintPath, paint);
}

/// The figure's own pixels in gold: the colour filter keeps only the shape
/// of the picture. The paints are made once; per frame only their opacity
/// changes, to one of a fixed set of colours.
final _rimPaint = Paint()
  ..filterQuality = FilterQuality.medium
  ..colorFilter = const ColorFilter.mode(Color(0xFFFFD86B), BlendMode.srcIn);
final _sheenFill = Paint()
  ..filterQuality = FilterQuality.medium
  ..colorFilter = const ColorFilter.mode(Color(0xFFFFF4C2), BlendMode.srcIn);
final _sheenLayer = Paint()..blendMode = BlendMode.plus;

/// A soft band one unit wide, scaled and slanted onto the figure; clear on
/// both sides of it ([_beyond] covers the rest of the figure, which the
/// mask must clear as well).
final _sheenBand = Paint()
  ..blendMode = BlendMode.dstIn
  ..shader = ui.Gradient.linear(
    Offset.zero,
    const Offset(1, 0),
    const [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
    const [0, .5, 1],
  );
final _beyond = Rect.fromLTRB(-40, -.05, 40, 1.05);
final _opacities = [
  for (var a = 0; a <= 32; a++) Color.fromRGBO(0, 0, 0, a / 32),
];
Color _opacity(double o) => _opacities[(o.clamp(0, 1) * 32).round()];

/// How often (seconds) the sheen sweeps over a shiny character, and how
/// long one sweep takes.
const sheenPeriod = 2.8, sheenSweep = .9;

/// A thin golden rim around the figure [src] of [image] drawn in [dst],
/// pulsing gently by [time] (seconds). Drawn just before the figure, which
/// covers all of it but the edge; it follows the figure in every pose.
void paintRim(Canvas canvas, ui.Image image, Rect src, Rect dst, double time) {
  final d = max(1.0, dst.height * .014);
  _rimPaint.color = _opacity(.45 + .2 * sin(time * 2.4));
  canvas
    ..save()
    ..translate(d, 0)
    ..drawImageRect(image, src, dst, _rimPaint)
    ..translate(-2 * d, 0)
    ..drawImageRect(image, src, dst, _rimPaint)
    ..translate(d, d)
    ..drawImageRect(image, src, dst, _rimPaint)
    ..translate(0, -2 * d)
    ..drawImageRect(image, src, dst, _rimPaint)
    ..restore();
}

/// A slanted band of light sweeping over the figure every [sheenPeriod]
/// seconds, only on its own pixels; drawn just after the figure. Between
/// sweeps it costs nothing.
void paintSheen(
  Canvas canvas,
  ui.Image image,
  Rect src,
  Rect dst,
  double time,
) {
  final u = (time % sheenPeriod) / sheenSweep;
  if (u >= 1) return;
  const slant = .5;
  final band = dst.width * .3;
  final x = dst.left - band + u * (dst.width + band + slant * dst.height);
  _sheenLayer.color = _opacity(.6 * sin(pi * u));
  canvas
    ..saveLayer(dst, _sheenLayer)
    ..drawImageRect(image, src, dst, _sheenFill)
    ..save()
    ..translate(x, dst.top)
    ..skew(-slant, 0)
    ..scale(band, dst.height)
    ..drawRect(_beyond, _sheenBand)
    ..restore()
    ..restore();
}
