import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_fx.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart'
    show StageRunnerPainter, stagePainterFor;

/// Regression tests for [StageRunnerPainter]'s `ui.ImageShader` lifecycle
/// across orientation changes (portrait <-> landscape) and painter disposal.
///
/// Kept free of `dart:io` so it runs on both the VM and Flutter Web
/// (`--platform chrome`, CanvasKit), where `CkImageShader.dispose()` disposes
/// the image handle passed to its constructor.
void main() {
  Future<ui.Image> solidImage(int width, int height, Color color) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = color,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  Future<void> paintFrame(
    StageRunnerPainter painter,
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
    image.dispose();
    picture.dispose();
  }

  testWidgets(
    'portrait to landscape rotation and painter disposal keep shared backdrop alive',
    (tester) async {
      await tester.runAsync(() async {
        final atlas = await solidImage(1120, 580, const Color(0xFFCC8844));
        final backdrop = await solidImage(512, 256, const Color(0xFF225588));
        final art = RunnerArt.test(atlas, backdrop);
        final game = StageRunner(random: Random(11))
          ..distance = 1.2
          ..time = 2.0;
        final fx = RunnerFx(random: Random(13));
        const portrait = Size(393, 796);
        const landscape = Size(852, 337);
        const ratio = 2.0;

        try {
          for (final rasterize in [true, false]) {
            final painter = stagePainterFor(
              game,
              art,
              fx: fx,
              pixelRatio: ratio,
              rasterizeDecorations: rasterize,
            );
            try {
              // Simulate intro prewarm in portrait (builds backdrop shader
              // and baked decoration strips).
              for (var step = 0; step < 5; step++) {
                painter.prewarmStep(portrait, step);
              }
              await paintFrame(painter, portrait, ratio);

              // Rotate to landscape: disposes old backdrop shader and strips,
              // then rebuilds for landscape. Shared backdrop must stay valid.
              for (var step = 0; step < 5; step++) {
                painter.prewarmStep(landscape, step);
              }
              await paintFrame(painter, landscape, ratio);
              expect(backdrop.debugDisposed, isFalse);
              expect(backdrop.width, 512);
              expect(backdrop.height, 256);

              // Rotate back to portrait and once more to landscape.
              await paintFrame(painter, portrait, ratio);
              await paintFrame(painter, landscape, ratio);
              expect(backdrop.debugDisposed, isFalse);
            } finally {
              painter.dispose();
            }

            // Re-entering Bühnenlauf reuses the same RunnerArt.loaded backdrop.
            expect(backdrop.debugDisposed, isFalse);
            final reopened = stagePainterFor(
              game,
              art,
              fx: fx,
              pixelRatio: ratio,
              rasterizeDecorations: rasterize,
            );
            try {
              await paintFrame(reopened, landscape, ratio);
              expect(backdrop.debugDisposed, isFalse);
            } finally {
              reopened.dispose();
            }
          }
        } finally {
          atlas.dispose();
          backdrop.dispose();
        }
      });
    },
  );
}
