// Run this exporter explicitly with flutter test and REPLAY_OUT set.
// The game exposes its production painter specifically for tests and renders.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_fx.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart'
    show stagePainterFor;

import '../runner_agent.dart' show loadRunnerPolicy, runnerLandscape;
import 'policy.dart';

void _text(
  ui.Canvas canvas,
  String text,
  double x,
  double y, {
  double size = 21,
  ui.Color color = const ui.Color(0xfffff2df),
}) {
  final builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(fontFamily: 'Replay', fontSize: size),
        )
        ..pushStyle(ui.TextStyle(color: color))
        ..addText(text);
  final paragraph = builder.build()
    ..layout(const ui.ParagraphConstraints(width: 350));
  canvas.drawParagraph(paragraph, ui.Offset(x, y));
  paragraph.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'render a complete offline agent run',
    () async {
      const path = String.fromEnvironment('REPLAY_OUT');
      if (path.isEmpty) throw ArgumentError('Set REPLAY_OUT to an MP4 file.');
      const seed = int.fromEnvironment('COURSE', defaultValue: 1000000);
      const motor = int.fromEnvironment('MOTOR', defaultValue: 120000000);
      final game = StageRunner(seed: seed)..view = runnerLandscape;
      final player = HumanRunner(loadRunnerPolicy(), motor);
      final fx = RunnerFx(random: Random(1));
      game.onPickup = (k, x, y) => fx.pickup(k, x - game.distance, y);
      final art = await RunnerArt.load();
      expect(art, isNotNull);
      await (FontLoader('Replay')
            ..addFont(rootBundle.load('assets/fonts/roboto/Roboto-Bold.ttf')))
          .load();
      final painter = stagePainterFor(game, art, fx: fx);
      const w = 840, h = 400, header = 54;
      final output = File(path);
      await output.parent.create(recursive: true);
      final ffmpeg = await Process.start('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-n',
        '-f',
        'rawvideo',
        '-pixel_format',
        'rgba',
        '-video_size',
        '${w}x${h + header}',
        '-framerate',
        '30',
        '-i',
        'pipe:0',
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '22',
        '-pix_fmt',
        'yuv420p',
        '-movflags',
        '+faststart',
        path,
      ]);
      final errors = ffmpeg.stderr.transform(utf8.decoder).join();
      final out = ffmpeg.stdout.drain<void>();
      var frame = 0;
      double? reached;
      try {
        while (!game.over || game.sinceOver < .85) {
          if (!game.over) game.holding = player.hold(game);
          game.update(1 / 60);
          fx.update(1 / 60, game);
          if (game.score >= 4000) reached ??= game.time;
          if (++frame % 2 != 0) continue;
          final recorder = ui.PictureRecorder(), canvas = ui.Canvas(recorder);
          canvas.drawColor(const ui.Color(0xff181b18), ui.BlendMode.src);
          canvas.save();
          canvas.translate(0, header.toDouble());
          painter.paint(canvas, const ui.Size(840, 400));
          canvas.restore();
          _text(canvas, '${game.score} Punkte', 20, 13);
          _text(canvas, '${game.meters} m', 225, 15, size: 18);
          final seconds = game.time.floor();
          _text(
            canvas,
            '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
            463,
            15,
            size: 18,
          );
          final held = !game.over && game.holding;
          final tint = held
              ? const ui.Color(0xffffd680)
              : const ui.Color(0xffb7b7ad);
          canvas.drawCircle(
            const ui.Offset(650, 27),
            6,
            ui.Paint()
              ..style = held ? ui.PaintingStyle.fill : ui.PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = tint,
          );
          _text(
            canvas,
            game.over
                ? 'Lauf beendet'
                : held
                ? 'Gedrückt'
                : 'Losgelassen',
            667,
            15,
            size: 18,
            color: tint,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(w, h + header);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          ffmpeg.stdin.add(
            data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          await ffmpeg.stdin.flush();
          image.dispose();
          picture.dispose();
        }
      } finally {
        await ffmpeg.stdin.close();
        await out;
        final code = await ffmpeg.exitCode;
        expect(code, 0, reason: await errors);
      }
      final expected = int.fromEnvironment('EXPECTED_SCORE', defaultValue: -1);
      if (expected >= 0) expect(game.score, expected);
      // ignore: avoid_print
      print(
        'Course $seed, motor $motor: ${game.score} points; 4000 at $reached seconds.',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
