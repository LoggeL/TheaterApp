import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../domain/stage_runner.dart';

/// A trail behind the flying runner, from a worn effect.
class RunnerEffectStyle {
  const RunnerEffectStyle(this.trail, this.colors, {this.shine = false});

  /// `sparkle`, `confetti`, `smoke` or `stars`; anything else sparkles;
  /// empty for no trail (only the [shine]).
  final String trail;
  final List<ui.Color> colors;

  /// A shiny character: a golden rim, a sheen sweeping over the figure and
  /// glints around it. Only drawn: hitbox and physics stay the same.
  final bool shine;
}

/// Where each picture sits in `assets/games/stage_runner/atlas.webp`.
enum RunnerSprite {
  // Engel Logge.
  fly(752, 386, 210, 130),
  dangle(797, 4, 125, 165),
  // The run, in this order: the near leg forward ([runA]), passing under
  // the body ([passA]), back while the far leg is forward ([runB]), and
  // the far leg passing ([passB]). The far leg is in the shade.
  runA(4, 4, 172, 187),
  passA(180, 4, 172, 187),
  runB(621, 4, 172, 187),
  passB(576, 386, 172, 187),
  cheer(356, 4, 108, 195),
  crash(152, 454, 207, 88),
  crate(4, 208, 150, 147),
  lamp(158, 208, 92, 170),
  sandbag(254, 208, 118, 140),
  rose(376, 208, 89, 120),
  mask(469, 208, 120, 87),
  star(593, 208, 116, 120),
  flat(961, 4, 159, 360),
  drum(713, 208, 150, 150),
  truss(152, 386, 420, 64),
  drop(479, 4, 128, 176);

  const RunnerSprite(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
  ui.Rect get rect => ui.Rect.fromLTWH(x, y, width, height);

  /// Stage heights per pixel of the runner's poses, all drawn alike.
  static const stagePerPixel = .155 / 200;

  /// The poses of the run in order; a whole cycle covers two ninths of a
  /// unit, so the legs keep pace with the floor.
  static const strides = [runA, passA, runB, passB];

  /// The pose of the run after running [distance].
  static RunnerSprite stride(double distance) =>
      strides[(distance * 18).floor() % strides.length];

  /// Where the flying wire meets the harness, in pixels of the picture;
  /// only for the poses of the runner.
  ui.Offset get harness => switch (this) {
    fly => const ui.Offset(106, 42),
    dangle => const ui.Offset(54, 28),
    cheer => const ui.Offset(44, 68),
    runA => const ui.Offset(83, 66),
    _ => const ui.Offset(91, 66),
  };

  static RunnerSprite of(PickupKind kind) => switch (kind) {
    PickupKind.rose => rose,
    PickupKind.mask => mask,
    PickupKind.star => star,
  };

  /// Which picture of a costume holds it: the runner's poses come from the
  /// worn character, the obstacles from the worn obstacle set (or the
  /// backdrop's own), the pickups from the backdrop's collectibles, else
  /// from the game's own atlas.
  RunnerLayer get layer => switch (this) {
    fly ||
    dangle ||
    runA ||
    passA ||
    runB ||
    passB ||
    cheer ||
    crash => RunnerLayer.runner,
    rose || mask || star => RunnerLayer.pickups,
    _ => RunnerLayer.obstacles,
  };

  /// The sprite that shows an obstacle kind, e.g. in the statistics; null
  /// for the velvet border, which is drawn.
  static RunnerSprite? ofObstacle(ObstacleKind kind) => switch (kind) {
    ObstacleKind.crate => crate,
    ObstacleKind.flat => flat,
    ObstacleKind.lamp => lamp,
    ObstacleKind.border => null,
    ObstacleKind.sandbag => sandbag,
    ObstacleKind.drum => drum,
    ObstacleKind.pile => crate,
    ObstacleKind.truss => truss,
    ObstacleKind.drop => drop,
  };
}

enum RunnerLayer { runner, obstacles, pickups }

/// Sprites are scaled down from the atlas; mipmapped sampling keeps them
/// smooth without any blur filter.
Paint _paint([ColorFilter? filter]) => Paint()
  ..filterQuality = FilterQuality.medium
  ..colorFilter = filter;

/// The decoded pictures of the game. They are loaded when the game opens,
/// not with the app, and stay decoded for the rest of the session. Offline
/// on the web they may be missing; the stage then draws simple shapes.
class RunnerArt {
  RunnerArt._(this.atlas, this.backdrop)
    : runnerAtlas = atlas,
      obstacleAtlas = atlas,
      pickupAtlas = atlas,
      runnerPaint = _paint(),
      obstaclePaint = _paint(),
      backdropPaint = _paint(),
      harness = const {},
      effect = null,
      border = null,
      obstacleCrashLines = const {},
      pickupNames = const {};

  /// Art from already decoded pictures, for tests.
  @visibleForTesting
  RunnerArt.test(ui.Image atlas, ui.Image backdrop) : this._(atlas, backdrop);

  RunnerArt._dressed(
    this.atlas,
    this.backdrop, {
    required this.runnerAtlas,
    required this.obstacleAtlas,
    required this.pickupAtlas,
    required this.runnerPaint,
    required this.obstaclePaint,
    required this.backdropPaint,
    this.harness = const {},
    this.effect,
    this.border,
    this.obstacleCrashLines = const {},
    this.pickupNames = const {},
  });

  /// The game's own atlas and the shown backdrop.
  final ui.Image atlas, backdrop;

  /// The atlases of the worn character, obstacle set and collectibles, in
  /// the layout of [atlas]; the default ones are [atlas] itself.
  final ui.Image runnerAtlas, obstacleAtlas, pickupAtlas;

  /// How each layer is drawn; a stand-in costume tints the default art.
  final Paint runnerPaint, obstaclePaint, backdropPaint;
  static final pickupPaint = _paint();

  /// The worn effect, if any.
  final RunnerEffectStyle? effect;

  /// The colour of the border (the short curtain the game draws) on the
  /// worn backdrop; null for the theatre's red.
  final ui.Color? border;

  /// What the backdrop's own collectibles are called; empty for the game's
  /// own (and whenever its collectibles did not load).
  final Map<PickupKind, String> pickupNames;

  /// Closing lines for the loaded obstacle set; empty for the default art.
  final Map<ObstacleKind, String> obstacleCrashLines;

  /// Wire points of the worn character's own atlas that differ from
  /// [RunnerSprite.harness].
  final Map<RunnerSprite, ui.Offset> harness;

  ui.Offset harnessOf(RunnerSprite sprite) => harness[sprite] ?? sprite.harness;

  /// This art in another costume: what is left out stays as it is.
  RunnerArt dressed({
    ui.Image? runner,
    ui.Image? obstacles,
    ui.Image? pickups,
    ui.Image? backdrop,
    ColorFilter? runnerFilter,
    ColorFilter? obstacleFilter,
    ColorFilter? backdropFilter,
    Map<RunnerSprite, ui.Offset> harness = const {},
    RunnerEffectStyle? effect,
    ui.Color? border,
    Map<ObstacleKind, String> obstacleCrashLines = const {},
    Map<PickupKind, String> pickupNames = const {},
  }) => RunnerArt._dressed(
    atlas,
    backdrop ?? this.backdrop,
    runnerAtlas: runner ?? atlas,
    obstacleAtlas: obstacles ?? atlas,
    pickupAtlas: pickups ?? atlas,
    runnerPaint: _paint(runnerFilter),
    obstaclePaint: _paint(obstacleFilter),
    backdropPaint: _paint(backdropFilter),
    harness: runner == null ? const {} : harness,
    effect: effect,
    border: border,
    obstacleCrashLines: obstacles == null ? const {} : obstacleCrashLines,
    pickupNames: pickups == null ? const {} : pickupNames,
  );

  ui.Image imageOf(RunnerSprite sprite) => switch (sprite.layer) {
    RunnerLayer.runner => runnerAtlas,
    RunnerLayer.obstacles => obstacleAtlas,
    RunnerLayer.pickups => pickupAtlas,
  };

  Paint paintOf(RunnerSprite sprite) => switch (sprite.layer) {
    RunnerLayer.runner => runnerPaint,
    RunnerLayer.obstacles => obstaclePaint,
    RunnerLayer.pickups => pickupPaint,
  };

  static const _dir = 'assets/games/stage_runner';
  static RunnerArt? _loaded;
  static Future<RunnerArt?>? _loading;

  /// Already decoded art, without waiting.
  static RunnerArt? get loaded => _loaded;

  static Future<RunnerArt?> load([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle);

  static Future<RunnerArt?> _load(AssetBundle bundle) async {
    try {
      final images = await Future.wait([
        _decode(bundle, '$_dir/atlas.webp'),
        _decode(bundle, '$_dir/backdrop.webp'),
      ]);
      return _loaded = RunnerArt._(images[0], images[1]);
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Bilder fehlen: $e');
      // Try again the next time the game opens.
      _loading = null;
      return null;
    }
  }

  static Future<ui.Image> _decode(AssetBundle bundle, String key) async {
    final data = await bundle.load(key);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }
}
