import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';

// Frozen drawing routines from before the performance change. These are an
// independent visual oracle, including the alpha overlap of the four copies.
Color _opacity(double o) =>
    Color.fromRGBO(0, 0, 0, (o.clamp(0, 1) * 32).round() / 32);

void _beforeRim(
  Canvas canvas,
  ui.Image image,
  Rect src,
  Rect dst,
  double time,
) {
  final paint = Paint()
    ..filterQuality = FilterQuality.medium
    ..colorFilter = const ColorFilter.mode(Color(0xFFFFD86B), BlendMode.srcIn)
    ..color = _opacity(.45 + .2 * sin(time * 2.4));
  final d = max(1.0, dst.height * .014);
  canvas
    ..save()
    ..translate(d, 0)
    ..drawImageRect(image, src, dst, paint)
    ..translate(-2 * d, 0)
    ..drawImageRect(image, src, dst, paint)
    ..translate(d, d)
    ..drawImageRect(image, src, dst, paint)
    ..translate(0, -2 * d)
    ..drawImageRect(image, src, dst, paint)
    ..restore();
}

void _beforeSheen(
  Canvas canvas,
  ui.Image image,
  Rect src,
  Rect dst,
  double time,
) {
  final u = (time % 2.8) / .9;
  if (u >= 1) return;
  final band = dst.width * .3;
  final x = dst.left - band + u * (dst.width + band + .5 * dst.height);
  canvas
    ..saveLayer(
      dst,
      Paint()
        ..blendMode = BlendMode.plus
        ..color = _opacity(.6 * sin(pi * u)),
    )
    ..drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = const ColorFilter.mode(
          Color(0xFFFFF4C2),
          BlendMode.srcIn,
        ),
    )
    ..save()
    ..translate(x, dst.top)
    ..skew(-.5, 0)
    ..scale(band, dst.height)
    ..drawRect(
      Rect.fromLTRB(-40, -.05, 40, 1.05),
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          Offset.zero,
          const Offset(1, 0),
          const [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
          const [0, .5, 1],
        ),
    )
    ..restore()
    ..restore();
}

typedef _Shine = void Function(Canvas, ui.Image, Rect, Rect, double);

Future<Uint8List> _render(
  ui.Image atlas,
  Rect src,
  double scale,
  double time,
  double angle,
  double dpr,
  _Shine rim,
  _Shine sheen,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(dpr);
  const size = 240.0;
  canvas.drawColor(const Color(0xFF172623), BlendMode.src);
  canvas.translate(size / 2, size / 2);
  canvas.rotate(angle);
  final dst = Rect.fromCenter(
    center: Offset.zero,
    width: src.width * scale,
    height: src.height * scale,
  );
  rim(canvas, atlas, src, dst, time);
  canvas.drawImageRect(
    atlas,
    src,
    dst,
    Paint()..filterQuality = FilterQuality.medium,
  );
  sheen(canvas, atlas, src, dst, time);
  final picture = recorder.endRecording();
  final result = await picture.toImage(
    (size * dpr).round(),
    (size * dpr).round(),
  );
  final bytes = (await result.toByteData())!.buffer.asUint8List();
  result.dispose();
  picture.dispose();
  return bytes;
}

void _samePixels(Uint8List before, Uint8List after, String reason) {
  var differing = 0, largest = 0;
  for (var i = 0; i < before.length; i++) {
    if (before[i] != after[i]) differing++;
    largest = max(largest, (before[i] - after[i]).abs());
  }
  // Picture replay changes floating-point transform association. At rotated
  // antialiased edges this can round a channel one step differently. Bound
  // both the magnitude and the affected area; alpha/colour changes must fail.
  expect(largest, lessThanOrEqualTo(1), reason: reason);
  expect(differing / before.length, lessThan(.0001), reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.Image atlas;
  setUpAll(() async {
    final codec = await ui.instantiateImageCodec(
      File('assets/games/stage_runner/atlas.webp').readAsBytesSync(),
    );
    atlas = (await codec.getNextFrame()).image;
    codec.dispose();
  });
  tearDownAll(() => atlas.dispose());

  test(
    'eight shiny poses retain their pixels through motion, pulsing and sheen',
    () async {
      final cache = RunnerRimCache();
      addTearDown(cache.dispose);
      for (final sprite in RunnerSprite.values.where(
        (s) => s.layer == RunnerLayer.runner,
      )) {
        for (final config in [
          (.25, 0.0, 0.0, 1.0),
          (.75, .45, .2, 2.0),
          (.42, .89, -.2, 3.0),
          (.6, 2.1, .5, 1.0),
          (.33, .9, 0.0, 2.0),
          (.55, 2.8, -.1, 3.0),
        ]) {
          final (scale, time, angle, dpr) = config;
          final before = await _render(
            atlas,
            sprite.rect,
            scale,
            time,
            angle,
            dpr,
            _beforeRim,
            _beforeSheen,
          );
          final after = await _render(
            atlas,
            sprite.rect,
            scale,
            time,
            angle,
            dpr,
            cache.paint,
            paintSheen,
          );
          _samePixels(before, after, '${sprite.name} $config');
        }
      }
    },
  );

  test('partially transparent overlapping pixels keep their alpha', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(8, 8, 48, 48),
      Paint()..color = const Color(0x5588AACC),
    );
    canvas.drawCircle(
      const Offset(32, 32),
      24,
      Paint()..color = const Color(0x66EEAA55),
    );
    final picture = recorder.endRecording();
    final synthetic = await picture.toImage(64, 64);
    picture.dispose();
    addTearDown(synthetic.dispose);
    final cache = RunnerRimCache();
    addTearDown(cache.dispose);
    for (final time in [0.0, .23, .45, .7, .9, 1.8, 2.8, 3.1]) {
      final before = await _render(
        synthetic,
        const Rect.fromLTWH(0, 0, 64, 64),
        1.25,
        time,
        .2,
        2,
        _beforeRim,
        _beforeSheen,
      );
      final after = await _render(
        synthetic,
        const Rect.fromLTWH(0, 0, 64, 64),
        1.25,
        time,
        .2,
        2,
        cache.paint,
        paintSheen,
      );
      _samePixels(before, after, 'alpha at $time');
    }
  });

  test(
    'cache reuses moving poses, bounds resized entries and clears on costume change',
    () {
      final cache = RunnerRimCache();
      addTearDown(cache.dispose);
      void record(ui.Image image, Rect dst, double time) {
        final recorder = ui.PictureRecorder();
        cache.paint(Canvas(recorder), image, RunnerSprite.runA.rect, dst, time);
        recorder.endRecording().dispose();
      }

      record(atlas, const Rect.fromLTWH(0, 0, 43, 46.75), 0);
      record(atlas, const Rect.fromLTWH(22, 37, 43, 46.75), 0);
      expect(cache.recordings, 1);
      expect(cache.entries, 1);
      for (var i = 1; i <= RunnerRimCache.maxEntries + 10; i++) {
        record(atlas, Rect.fromLTWH(0, 0, i.toDouble(), i * 187 / 172), 0);
      }
      expect(cache.entries, RunnerRimCache.maxEntries);
      final another = atlas.clone();
      record(another, const Rect.fromLTWH(0, 0, 43, 46.75), 0);
      expect(cache.entries, 1);
      cache.dispose();
      expect(cache.entries, 0);
      another.dispose();
    },
  );

  test('warm rim recording benchmark', () {
    final cache = RunnerRimCache();
    addTearDown(cache.dispose);
    final src = RunnerSprite.runA.rect;
    const dst = Rect.fromLTWH(22, 37, 43, 46.75);
    double measure(_Shine draw) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < 10000; i++) {
        final recorder = ui.PictureRecorder();
        draw(Canvas(recorder), atlas, src, dst, .45);
        recorder.endRecording().dispose();
      }
      watch.stop();
      return watch.elapsedMicroseconds / 10000;
    }

    measure(paintRim);
    measure(cache.paint);
    final old = [for (var i = 0; i < 3; i++) measure(paintRim)]..sort();
    final cached = [for (var i = 0; i < 3; i++) measure(cache.paint)]..sort();
    // Informational, not a timing assertion that depends on CI machine load.
    // ignore: avoid_print
    print(
      'Rim recording, warm cache, desktop debug: old ${old[1].toStringAsFixed(3)} us, cached ${cached[1].toStringAsFixed(3)} us (no raster/GPU measurement).',
    );
    expect(cache.recordings, 1);
  });
}
