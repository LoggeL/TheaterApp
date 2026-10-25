import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/stage_runner_fx.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart';

// Captured with the uncached renderer. No fonts, downloaded images or random
// particles: these references isolate the stage's geometry and scrolling.
const _references = {
  0: 'portrait-start',
  7: 'portrait-scroll',
  9: 'portrait-curtain',
  10: 'landscape-start',
  17: 'landscape-scroll',
  60: 'portrait-dpr3-start',
  67: 'portrait-dpr3-scroll',
  68: 'portrait-dpr3-shake',
  69: 'portrait-dpr3-curtain',
};

void main() {
  testWidgets('decoration stays unchanged across scroll, resize and crash', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final game = StageRunner(random: Random(43))
        ..obstacles.clear()
        ..pickups.clear();
      final fx = RunnerFx(random: Random(17));
      var index = 0;
      for (final ratio in [1.0, 2.0, 3.0]) {
        final warm = stagePainterFor(game, null, fx: fx, pixelRatio: ratio);
        // The second portrait layout also checks invalidation after a resize.
        for (final size in [
          const Size(390, 700),
          const Size(800, 400),
          const Size(390, 700),
        ]) {
          // Each repeating decoration has its own period. Test either side
          // of fold/head boundaries and reuse after the 13-head variation.
          for (final (distance, crash) in [
            (0.0, 0.0),
            (.089, 0.0),
            (.091, 0.0),
            (.109, 0.0),
            (.111, 0.0),
            (1.429, 0.0),
            (1.431, 0.0),
            (13.7, 0.0),
            (13.7, .13),
            (13.7, .55),
          ]) {
            game
              ..distance = distance
              ..time = 4
              ..over = crash > 0
              ..sinceOver = crash;
            final actual = await _render(warm, size, ratio);
            final cold = await _render(
              stagePainterFor(game, null, fx: fx, pixelRatio: ratio),
              size,
              ratio,
            );
            expect(
              actual,
              cold,
              reason: 'Scene $index cache after scroll/resize, DPR $ratio',
            );
            if (_references[index] case final name?) {
              final codec = await ui.instantiateImageCodec(
                File(
                  'test/goldens/runner_decoration/$name.png',
                ).readAsBytesSync(),
              );
              final image = (await codec.getNextFrame()).image;
              final reference = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!.buffer.asUint8List();
              image.dispose();
              codec.dispose();
              expect(actual.length, reference.length, reason: name);
              var changed = 0, largest = 0;
              for (var i = 0; i < actual.length; i++) {
                final delta = (actual[i] - reference[i]).abs();
                if (delta > 0) {
                  changed++;
                }
                largest = max(largest, delta);
              }
              // Translating recorded vector shapes instead of every primitive
              // can round a few antialiased edge channels differently. The
              // original 90-scene comparison found at most 48 such channels,
              // with a maximum difference of 4/255. Geometry must not move.
              expect(largest, lessThanOrEqualTo(4), reason: name);
              expect(changed, lessThanOrEqualTo(64), reason: name);
            }
            index++;
          }
        }
      }
    });
  });
}

Future<Uint8List> _render(
  CustomPainter painter,
  Size size,
  double ratio,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(ratio);
  painter.paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (size.width * ratio).round(),
    (size.height * ratio).round(),
  );
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}
