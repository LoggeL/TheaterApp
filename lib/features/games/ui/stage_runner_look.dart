import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/app_controller.dart';
import '../../../core/telemetry/perf_telemetry.dart';
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

/// Width and height of a WebP file ([bytes]) from its header, without
/// decoding it; null for anything else.
(int, int)? webpSize(Uint8List bytes) {
  bool tag(int at, String name) =>
      String.fromCharCodes(bytes, at, at + 4) == name;
  int number(int at, int length) {
    var value = 0;
    for (var i = length - 1; i >= 0; i--) {
      value = value * 256 + bytes[at + i];
    }
    return value;
  }

  // The first chunk's body starts at 20; all three kinds have the size
  // within its first ten bytes.
  if (bytes.length < 30 || !tag(0, 'RIFF') || !tag(8, 'WEBP')) return null;
  if (tag(12, 'VP8 ')) {
    // Lossy: a frame tag of 3 bytes, the start code, 14 bits for each side.
    if (number(23, 3) != 0x2a019d) return null;
    return (number(26, 2) & 0x3fff, number(28, 2) & 0x3fff);
  }
  if (tag(12, 'VP8L')) {
    // Lossless: a signature byte, then 14 bits for each side minus one.
    if (bytes[20] != 0x2f) return null;
    final sides = number(21, 4);
    return (sides % 0x4000 + 1, (sides ~/ 0x4000) % 0x4000 + 1);
  }
  if (tag(12, 'VP8X')) {
    // Extended: flags, three reserved bytes, 24 bits for each side minus one.
    return (number(24, 3) + 1, number(27, 3) + 1);
  }
  return null;
}

/// A picture waiting for its turn, see [WardrobePictures.load].
class _Turn {
  _Turn(this.shown);
  final bool Function()? shown;
  final done = Completer<void>();
}

/// The next of [waiting]: the first one still on screen, else the first.
_Turn? _nextTurn(List<_Turn> waiting) {
  if (waiting.isEmpty) return null;
  final i = waiting.indexWhere((turn) => turn.shown?.call() ?? true);
  return waiting.removeAt(max(i, 0));
}

/// Pictures of the wardrobe from the server, decoded once and kept while
/// they fit into [maxBytes]. Only what is worn or shown gets loaded; a
/// failure (offline) is tried again next time.
///
/// The cache only decides what stays without a holder: whoever shows a
/// picture keeps the image it got (the dressed [RunnerArt], a card's state,
/// the crate's reel), so a picture dropped from here never vanishes from the
/// screen; it is fetched again when it is needed anew.
///
/// Below the decoded pictures it keeps the files as they came from the
/// server ([maxFileBytes]): a portrait file is a few dozen KB, a decoded one
/// 1 MB, so a picture dropped from the decoded ones (scrolled away in a long
/// wardrobe) is decoded again without asking the server. The links carry the
/// file's hash (`?v=`), so a kept file never goes stale. A picture that
/// failed is not asked for again before [failurePause] has passed: cards
/// rebuild often, and each rebuild of one without its picture asked anew.
///
/// In the browser the pictures come one by one ([paced]): [maxDecoding]
/// decode at the same time and one reaches the screen per frame, only after
/// a frame that was on time ([frameBudgetMs]). Scrolling through a wardrobe
/// with an empty cache would otherwise decode and upload dozens in a frame.
/// Android is left alone: it decodes on its own threads.
abstract final class WardrobePictures {
  // In the order of last use: the first one is dropped first.
  static final _images = <String, ui.Image>{};
  static final _loading = <String, Future<ui.Image?>>{};
  static int _bytes = 0;
  static final _files = <String, Uint8List>{};
  static int _fileBytes = 0;
  static final _failedAt = <String, DateTime>{};

  /// File bytes kept at most (see above).
  @visibleForTesting
  static int maxFileBytes = (kIsWeb ? 12 : 24) << 20;

  /// How long a failed picture is not asked for again (except by the second
  /// try of [loadOrRetry]).
  @visibleForTesting
  static Duration failurePause = const Duration(seconds: 30);

  /// The kept file bytes, for tests.
  @visibleForTesting
  static int get fileBytes => _fileBytes;

  /// Decoded bytes kept at most. A portrait takes 1 MB (512²), a thumbnail
  /// 0.6 MB (384²), an atlas or backdrop about 2.5 MB: more than a screen of
  /// cards with the worn costume and the reel of a crate. Less in the browser
  /// (the PWA), whose memory a tab shares with everything else.
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
    while (_bytes > maxBytes) {
      final drop = _images.keys
          .where((key) => key != path && !_worn.contains(key))
          .firstOrNull;
      if (drop == null) break;
      _bytes -= _sizeOf(_images.remove(drop)!);
    }
  }

  /// The pictures of the worn costume: they stay when the wardrobe's cards
  /// push others out, as the game needs them again for the next dressing.
  static Set<String> _worn = const {};

  /// Makes [paths] the worn pictures, instead of those before.
  static void wear(Iterable<String> paths) => _worn = paths.toSet();

  /// Whether the picture at [path] stays (see [wear]), for tests.
  @visibleForTesting
  static bool isWorn(String path) => _worn.contains(path);

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
    String? path, {
    bool Function()? shown,
  }) => load(
    controller,
    path,
    maxPixels: portraitPixels(
      ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 3,
    ),
    shown: shown,
  );

  /// The picture at [path]; [maxPixels] decodes it smaller if its longer
  /// side exceeds that (never larger). The first load of a path decides its
  /// size, so a path is always loaded with the same [maxPixels]. Where
  /// pictures wait for their turn ([paced]), those [shown] says are still on
  /// screen go first, and without it a picture counts as shown.
  static Future<ui.Image?> load(
    AppController controller,
    String? path, {
    int? maxPixels,
    bool Function()? shown,
  }) => _load(controller, path, maxPixels: maxPixels, shown: shown);

  static Future<ui.Image?> _load(
    AppController controller,
    String? path, {
    int? maxPixels,
    bool Function()? shown,
    bool again = false,
  }) {
    if (path == null) return Future.value();
    final done = cached(path);
    if (done != null) return Future.value(done);
    final failed = _failedAt[path];
    if (!again &&
        failed != null &&
        DateTime.now().difference(failed) < failurePause &&
        !_loading.containsKey(path)) {
      return Future.value();
    }
    // A block body: an arrow would hand whenComplete the removed future,
    // which is this very one, and it would wait for itself.
    return _loading[path] ??= _fetch(controller, path, maxPixels, shown)
        .whenComplete(() {
          _loading.remove(path);
        });
  }

  /// [path] as if its file had been fetched before.
  @visibleForTesting
  static void keepFileForTest(String path, Uint8List bytes) {
    _files[path] = bytes;
    _fileBytes += bytes.length;
  }

  /// The file of [path]: kept from before, else from the server.
  static Future<Uint8List> _file(AppController controller, String path) async {
    final kept = _files.remove(path);
    if (kept != null) {
      _files[path] = kept;
      return kept;
    }
    final bytes = (await controller.mediaBytes(path, cache: false)).bytes;
    _files[path] = bytes;
    _fileBytes += bytes.length;
    while (_fileBytes > maxFileBytes && _files.length > 1) {
      _fileBytes -= _files.remove(_files.keys.first)!.length;
    }
    return bytes;
  }

  static Future<ui.Image?> _fetch(
    AppController controller,
    String path,
    int? maxPixels,
    bool Function()? shown,
  ) async {
    try {
      final bytes = await _file(controller, path);
      final image = paced
          ? await _decodeInTurn(bytes, maxPixels, shown)
          : await _decode(bytes, maxPixels);
      _failedAt.remove(path);
      _keep(path, image);
      return image;
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Bild $path fehlt: $e');
      _failedAt[path] = DateTime.now();
      // A file that does not decode is not kept either.
      final file = _files.remove(path);
      if (file != null) _fileBytes -= file.length;
      return null;
    }
  }

  /// Asks for the size first, which the engine answers from the file's
  /// header on Android, but in the browser only by decoding it a first time.
  static Future<ui.Image> _decode(Uint8List bytes, int? maxPixels) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
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
    return frame.image;
  }

  /// Whether pictures take turns (see the class).
  @visibleForTesting
  static bool paced = kIsWeb;

  /// Pictures decoding at the same time, in the browser.
  static const maxDecoding = 2;

  /// A frame longer than this (ms) after the one before makes the next
  /// picture wait a frame.
  static const frameBudgetMs = 20.0;

  /// Frames a picture gives way at most: the pictures come even while every
  /// frame is slow.
  static const maxHeldFrames = 3;

  /// Below this share of the file's size a picture is decoded smaller. Just
  /// below full size scaling saves little memory, but in the browser it costs
  /// a draw on a canvas on the main thread.
  static const minScale = .75;

  /// Opens a codec for [bytes], in the browser; replaced in tests.
  @visibleForTesting
  static Future<ui.Codec> Function(Uint8List, {int? width, int? height})
  openCodec = (bytes, {width, height}) => ui.instantiateImageCodec(
    bytes,
    targetWidth: width,
    targetHeight: height,
    allowUpscaling: false,
  );

  /// The size to decode a [width] by [height] picture with for [maxPixels],
  /// null for the size of the file.
  @visibleForTesting
  static (int, int)? decodeSize(int width, int height, int? maxPixels) {
    if (maxPixels == null) return null;
    final scale = maxPixels / max(width, height);
    if (scale >= minScale) return null;
    return (max(1, (width * scale).round()), max(1, (height * scale).round()));
  }

  /// One decode in the browser. The size comes from the file's header: the
  /// engine would decode the whole picture for it and then once more.
  static Future<ui.Image> _decodeOnce(Uint8List bytes, int? maxPixels) async {
    final size = webpSize(bytes);
    if (size == null) return _decode(bytes, maxPixels);
    final target = decodeSize(size.$1, size.$2, maxPixels);
    final codec = await openCodec(bytes, width: target?.$1, height: target?.$2);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static int _decoding = 0;
  static final _decodeTurns = <_Turn>[];
  static final _showTurns = <_Turn>[];
  static bool _frameAsked = false;
  static Duration? _lastFrame;
  static double _lastFrameMs = 0;
  static int _heldFrames = 0;

  static Future<ui.Image> _decodeInTurn(
    Uint8List bytes,
    int? maxPixels,
    bool Function()? shown,
  ) async {
    if (_decoding < maxDecoding) {
      _decoding++;
    } else {
      // The one finishing hands its place on.
      final turn = _Turn(shown);
      _decodeTurns.add(turn);
      await turn.done.future;
    }
    final ui.Image image;
    try {
      image = await _decodeOnce(bytes, maxPixels);
    } finally {
      final next = _nextTurn(_decodeTurns);
      if (next == null) {
        _decoding--;
      } else {
        next.done.complete();
      }
    }
    final turn = _Turn(shown);
    _showTurns.add(turn);
    _askFrame();
    await turn.done.future;
    return image;
  }

  /// Hands out the next picture in a frame of its own. Asks for that frame
  /// itself, as nothing may be going on on screen.
  static void _askFrame() {
    if (_frameAsked || _showTurns.isEmpty) return;
    _frameAsked = true;
    SchedulerBinding.instance
      ..scheduleFrameCallback(_frame)
      ..ensureVisualUpdate();
  }

  /// How long a frame took is its distance to the one before: known at once,
  /// unlike the engine's FrameTimings, which come in batches of 100 ms on the
  /// web, and the whole of it. The first frame of a burst has none (nothing
  /// may have been going on), the following ones were asked for right here.
  static void _frame(Duration now) {
    _frameAsked = false;
    final last = _lastFrame;
    final ms = last == null ? 0.0 : (now - last).inMicroseconds / 1000;
    // Held back and hardly quicker: the pictures are not why. A display at
    // 30 Hz (a phone saving power) has every frame above the budget.
    final slow =
        ms > frameBudgetMs && (_heldFrames == 0 || ms < _lastFrameMs * .75);
    _lastFrameMs = ms;
    if (slow && _heldFrames < maxHeldFrames) {
      _heldFrames++;
    } else {
      _heldFrames = 0;
      final turn = _nextTurn(_showTurns);
      if (turn != null) {
        PerfTelemetry.markImage(1);
        turn.done.complete();
      }
    }
    _lastFrame = _showTurns.isEmpty ? null : now;
    _askFrame();
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
    final again = await _load(controller, path, again: true);
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
    _files.clear();
    _fileBytes = 0;
    _failedAt.clear();
    _worn = const {};
    _decoding = 0;
    _decodeTurns.clear();
    _showTurns.clear();
    _frameAsked = false;
    _lastFrame = null;
    _lastFrameMs = 0;
    _heldFrames = 0;
    RunnerArt.forgetCells();
  }
}

/// What of a [Wardrobe] counts for [dressArt].
class _Worn {
  factory _Worn(Wardrobe wardrobe) {
    WardrobeItem? worn(WardrobeKind kind) {
      final item = wardrobe.worn(kind);
      return item == null || item.isDefault ? null : item;
    }

    // The worn role of the character, if one is chosen.
    final plain = worn(WardrobeKind.character);
    final backdrop = worn(WardrobeKind.backdrop);
    // A backdrop with obstacles of its own brings them along (the default
    // stage keeps the game's own); otherwise the worn obstacle set counts.
    final stageSet = backdrop?.obstacles;
    return _Worn._(
      plain?.inRole(wardrobe.variantOf(plain)),
      plain != null && wardrobe.isShiny(plain),
      backdrop,
      stageSet,
      stageSet == null ? worn(WardrobeKind.obstacles) : null,
      worn(WardrobeKind.fx),
    );
  }
  _Worn._(
    this.character,
    this.shiny,
    this.backdrop,
    this.stageSet,
    this.obstacles,
    this.fx,
  );
  final WardrobeItem? character, backdrop, obstacles, fx;
  final bool shiny;
  final String? stageSet;

  /// The atlas of the obstacles.
  String? get obstacleAtlas => stageSet ?? obstacles?.image;

  /// The picture of each layer, those not worn null.
  List<String?> get pictures => [
    character?.image,
    obstacleAtlas,
    backdrop?.image,
    backdrop?.collectibles,
  ];
}

/// The costume [wardrobe] dresses the game in: equal for two wardrobes that
/// [dressArt] would dress alike, whatever else changed between them.
String outfitOf(Wardrobe wardrobe) {
  final worn = _Worn(wardrobe);
  return [
    worn.character?.id,
    worn.shiny,
    worn.obstacles?.id,
    worn.backdrop?.id,
    worn.fx?.id,
    ...worn.pictures,
  ].join('|');
}

/// [outfitOf] for art that came out of [dressArt] as worn; null if a picture
/// was missing, so that the next change dresses it again.
String? dressedOutfit(Wardrobe wardrobe) =>
    _Worn(wardrobe).pictures.every(
      (path) => path == null || WardrobePictures.cached(path) != null,
    )
    ? outfitOf(wardrobe)
    : null;

/// How often [dressArt] ran, for tests.
@visibleForTesting
int dressCount = 0;

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
  dressCount++;
  final worn = _Worn(wardrobe);
  final character = worn.character, backdrop = worn.backdrop;
  final obstacles = worn.obstacles, stageSet = worn.stageSet;
  final fx = worn.fx, shiny = worn.shiny;
  WardrobePictures.wear(worn.pictures.nonNulls);
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
    ownPile:
        set != null &&
        await RunnerArt.draws(set, RunnerSprite.pile, path: worn.obstacleAtlas),
    ownTallCrate:
        set != null &&
        await RunnerArt.draws(
          set,
          RunnerSprite.tallCrate,
          path: worn.obstacleAtlas,
        ),
    ownScenery:
        set != null &&
        await RunnerArt.draws(
          set,
          RunnerSprite.threeCrates,
          path: worn.obstacleAtlas,
        ),
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
    obstacleCrashLines: {
      if (stageSet != null)
        for (final kind in ObstacleKind.values)
          kind: ?backdrop?.obstacleCrashLines[kind.name],
    },
    sceneryCrashLines: {
      if (stageSet != null)
        for (final key in RunnerArt.ownSceneryLines)
          key: ?backdrop?.obstacleCrashLines[key],
    },
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

/// Records the rim once per pose, size and pulse opacity. Replaying a picture
/// keeps the four overlapping, separately translucent sprite copies intact:
/// flattening them and then applying opacity would change their overlap.
///
/// These are drawing commands, not raster snapshots, so scaling, rotation and
/// the atlas's mipmapped sampling stay with the renderer. The animated sheen
/// remains separate. A stage owns this cache and disposes it with its painter.
class RunnerRimCache {
  /// Eight poses and fourteen pulse opacities fit, with a little spare room.
  /// Resizing cannot retain an unbounded collection of old sizes.
  static const maxEntries = 128;
  final _pictures = <(Rect, Size, int), ui.Picture>{};
  ui.Image? _image;

  @visibleForTesting
  int get entries => _pictures.length;

  @visibleForTesting
  int get recordings => _recordings;
  int _recordings = 0;

  void paint(Canvas canvas, ui.Image image, Rect src, Rect dst, double time) {
    if (!identical(image, _image)) {
      dispose();
      _image = image;
    }
    final opacity = ((.45 + .2 * sin(time * 2.4)) * 32).round();
    final key = (src, dst.size, opacity);
    var picture = _pictures.remove(key);
    if (picture == null) {
      final recorder = ui.PictureRecorder();
      paintRim(Canvas(recorder), image, src, Offset.zero & dst.size, time);
      picture = recorder.endRecording();
      _recordings++;
      if (_pictures.length >= maxEntries) {
        _pictures.remove(_pictures.keys.first)!.dispose();
      }
    }
    _pictures[key] = picture;
    canvas
      ..save()
      ..translate(dst.left, dst.top)
      ..drawPicture(picture)
      ..restore();
  }

  void dispose() {
    for (final picture in _pictures.values) {
      picture.dispose();
    }
    _pictures.clear();
    _image = null;
  }
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
