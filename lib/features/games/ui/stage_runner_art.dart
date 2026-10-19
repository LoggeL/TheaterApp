import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/stage_runner.dart';

/// Where each picture sits in `assets/games/stage_runner/atlas.webp`.
enum RunnerSprite {
  fly(4, 4, 175, 179),
  dangle(183, 4, 144, 182),
  // The run, in this order: the near leg forward ([runA]), passing under
  // the body ([passA]), back while the far leg is forward ([runB]), and
  // the far leg passing ([passB]). The far leg is in the shade.
  runA(331, 4, 144, 187),
  passA(576, 386, 144, 187),
  runB(4, 386, 144, 187),
  passB(724, 386, 144, 187),
  cheer(621, 4, 152, 200),
  crash(777, 4, 180, 110),
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

  /// The poses of the run in order; a whole cycle covers two ninths of a
  /// unit, so the legs keep pace with the floor.
  static const strides = [runA, passA, runB, passB];

  /// The pose of the run after running [distance].
  static RunnerSprite stride(double distance) =>
      strides[(distance * 18).floor() % strides.length];

  static RunnerSprite of(PickupKind kind) => switch (kind) {
    PickupKind.rose => rose,
    PickupKind.mask => mask,
    PickupKind.star => star,
  };
}

/// The decoded pictures of the game. They are loaded when the game opens,
/// not with the app, and stay decoded for the rest of the session. Offline
/// on the web they may be missing; the stage then draws simple shapes.
class RunnerArt {
  RunnerArt._(this.atlas, this.backdrop);
  final ui.Image atlas, backdrop;

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
