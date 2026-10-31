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
  drop(479, 4, 128, 176),
  // A pile in one picture (Creepshow's sarcophagus), shaped like its two
  // hitboxes: the lower half as wide as the cell, the upper half over its
  // middle half. Only obstacle sets that draw something here have one
  // ([RunnerArt.ownPile]); the others, the game's own atlas, too, pile up
  // crates.
  pile(966, 386, 154, 150),
  // A tall crate in one picture (Creepshow's tall brain-swap chair), for
  // crates higher than 1.35 times their width ([Obstacle.tall]); its shape,
  // 1.57 times as high as wide, lies in the middle of those, so it is
  // stretched or squeezed by at most a sixth. Only obstacle sets that draw
  // something here have one ([RunnerArt.ownTallCrate]); their low crates are
  // the game's own, and the others put two crates on each other.
  tallCrate(4, 360, 136, 214),
  // The cells of a set with its own scenery ([RunnerArt.ownScenery]). They
  // lie where the game's own atlas has poses and pickups, which an obstacle
  // set does not hold ([RunnerSprite.scenery]). The crate cell then is what
  // stands in place of one crate; two crates are [twoCrates], as high as
  // [tallCrate] is, and the pile of three [threeCrates], shaped like [pile].
  twoCrates(4, 4, 126, 200),
  threeCrates(134, 4, 190, 196),
  // A gap as a guillotine: the blade at the lower edge of the border, the
  // block at the upper edge of the flat, whatever their height, and between
  // them and towards the fly loft and the floor the timber of [guillotine]:
  // an upright at either side of it, in stretchable vertical grain.
  guillotineBlade(621, 4, 170, 113),
  guillotineBlock(621, 121, 170, 85),
  guillotine(330, 4, 130, 196);

  const RunnerSprite(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
  ui.Rect get rect => ui.Rect.fromLTWH(x, y, width, height);

  /// The cells only a set with its own scenery has: never drawn from the
  /// game's own atlas, so they may lie over a pose or a pickup there.
  static const scenery = [
    twoCrates,
    threeCrates,
    guillotineBlade,
    guillotineBlock,
    guillotine,
  ];

  /// The bookcase of a set with its own scenery, in the flat's cell: between
  /// [shelfTop] and [shelfFoot] lie [shelves] rows, [shelfHeight] pixels each,
  /// which repeat as far as a flat is high. The cell is squeezed by
  /// [shelfStretch] to hold a whole bookcase for older apps, which stretch
  /// it as a flat.
  static const shelves = 3,
      shelfTop = 125.0,
      shelfHeight = 65.0,
      shelfFoot = 40.0,
      shelfStretch = 1.71;

  /// The uprights take this much of the width of [guillotine] on either side.
  static const guillotineUpright = 1 / 6;

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
  /// for the velvet border, which is drawn. A pile is crates, unless the
  /// obstacle set has [ownPile] or [ownScenery], which also has a border.
  static RunnerSprite? ofObstacle(
    ObstacleKind kind, {
    bool ownPile = false,
    bool ownScenery = false,
  }) => switch (kind) {
    ObstacleKind.crate => crate,
    ObstacleKind.flat => flat,
    ObstacleKind.lamp => lamp,
    ObstacleKind.border => ownScenery ? guillotineBlade : null,
    ObstacleKind.sandbag => sandbag,
    ObstacleKind.drum => drum,
    ObstacleKind.pile =>
      ownScenery
          ? threeCrates
          : ownPile
          ? pile
          : crate,
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
      pickupNames = const {},
      ownPile = false,
      ownTallCrate = false,
      ownScenery = false,
      sceneryCrashLines = const {};

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
    this.ownPile = false,
    this.ownTallCrate = false,
    this.ownScenery = false,
    this.sceneryCrashLines = const {},
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

  /// Whether the obstacle set draws a pile in one picture
  /// ([RunnerSprite.pile]) instead of crates; never the default art.
  final bool ownPile;

  /// Whether the obstacle set draws a tall crate in one picture
  /// ([RunnerSprite.tallCrate]) instead of two crates; never the default art.
  /// It then shows that picture at this height only: its low crates are the
  /// game's own from [atlas], which is decoded whatever is worn, as dressing
  /// starts from it.
  final bool ownTallCrate;

  /// Whether the obstacle set draws all of its scenery by itself, seen by
  /// [RunnerSprite.threeCrates] and never partly so: a picture for one, two
  /// and three crates ([RunnerSprite.crate], [RunnerSprite.twoCrates],
  /// [RunnerSprite.threeCrates]), a flat in shelves and a gap as a guillotine.
  /// The cells [ownPile] and [ownTallCrate] then stay for older apps. Hitboxes
  /// and physics stay the same. Never the default art.
  final bool ownScenery;

  /// The closing lines that only fit [ownScenery]; [ownSceneryLines] are the
  /// keys. They are in `obstacleCrashLines` of the catalog, whose plain
  /// obstacle kinds stay what older apps show.
  final Map<String, String> sceneryCrashLines;

  static const ownSceneryLines = ['twoCrates', 'threeCrates', 'guillotine'];

  /// The closing lines of a run that ended on a crate [tall] or not, and in
  /// a [gap] or not. The line of a set with [ownTallCrate] is about that
  /// picture; a low crate is the game's own and keeps the game's own line. A
  /// set with [ownScenery] has a line for each of its pictures.
  Map<ObstacleKind, String> crashLines({required bool tall, bool gap = false}) {
    if (ownScenery) {
      final lines = {...obstacleCrashLines};
      void say(ObstacleKind kind, String key) {
        final line = sceneryCrashLines[key];
        if (line == null) {
          lines.remove(kind);
        } else {
          lines[kind] = line;
        }
      }

      if (tall) say(ObstacleKind.crate, 'twoCrates');
      say(ObstacleKind.pile, 'threeCrates');
      if (gap) {
        say(ObstacleKind.border, 'guillotine');
        say(ObstacleKind.flat, 'guillotine');
      }
      return lines;
    }
    return ownTallCrate && !tall
        ? {
            for (final MapEntry(:key, :value) in obstacleCrashLines.entries)
              if (key != ObstacleKind.crate) key: value,
          }
        : obstacleCrashLines;
  }

  /// The cells an obstacle set may leave empty.
  static const _optionalCells = [
    RunnerSprite.pile,
    RunnerSprite.tallCrate,
    RunnerSprite.threeCrates,
  ];

  /// Whether [image] draws anything in the optional cell of [sprite]. Reading
  /// the pixels back is slow (on the web it stalls the frame), so all optional
  /// cells are looked at in one read, kept per [path] (the link carries the
  /// file's hash) or, without one, per picture: a costume decoded anew does
  /// not read again, and those asking at the same time share the read.
  static Future<bool> draws(
    ui.Image image,
    RunnerSprite sprite, {
    String? path,
  }) async {
    assert(_optionalCells.contains(sprite));
    final cells = path == null
        ? _cells[image] ??= _readCells(image)
        : _cellsByPath[path] ??= _readCells(image);
    final found = await cells;
    if (found != null) return found[sprite] ?? false;
    // Not readable just now: the next one tries again.
    if (path == null) {
      _cells[image] = null;
    } else {
      _cellsByPath.remove(path);
    }
    return false;
  }

  /// The optional cells of [image]; null if its pixels could not be read,
  /// which the web engine reports with an error.
  static Future<Map<RunnerSprite, bool>?> _readCells(ui.Image image) async {
    pixelReads++;
    final ByteData? bytes;
    try {
      bytes = await image.toByteData();
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Atlas nicht lesbar: $e');
      return null;
    }
    if (bytes == null) return null;
    return {
      for (final sprite in _optionalCells)
        sprite: _drawn(bytes, image, sprite.rect),
    };
  }

  static bool _drawn(ByteData bytes, ui.Image image, ui.Rect cell) {
    final r = cell.intersect(
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    );
    for (var y = r.top.toInt(); y < r.bottom; y++) {
      for (var x = r.left.toInt(); x < r.right; x++) {
        // Alpha of the straight RGBA; a faint veil does not count.
        if (bytes.getUint8((y * image.width + x) * 4 + 3) > 32) return true;
      }
    }
    return false;
  }

  static final _cells = Expando<Future<Map<RunnerSprite, bool>?>>();
  static final _cellsByPath = <String, Future<Map<RunnerSprite, bool>?>>{};

  /// How often the pixels of a picture were read back, for tests.
  @visibleForTesting
  static int pixelReads = 0;

  /// Forgets what the cells were found to hold, with the pictures.
  static void forgetCells() {
    _cellsByPath.clear();
    pixelReads = 0;
  }

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
    bool ownPile = false,
    bool ownTallCrate = false,
    bool ownScenery = false,
    Map<String, String> sceneryCrashLines = const {},
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
    ownPile: obstacles != null && ownPile,
    ownTallCrate: obstacles != null && ownTallCrate,
    ownScenery: obstacles != null && ownScenery,
    sceneryCrashLines: obstacles == null ? const {} : sceneryCrashLines,
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

  /// Makes [art] the loaded art, null forgets it.
  @visibleForTesting
  static void useForTest(RunnerArt? art) {
    _loaded = art;
    _loading = art == null ? null : Future.value(art);
  }

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
