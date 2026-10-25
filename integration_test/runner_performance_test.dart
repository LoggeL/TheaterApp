import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

// Native rendering/audio smoke with synthetic data only. This is a behavior
// check, not an FPS benchmark. Screenshots are written to the app's temp folder.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('runner controls, rotation, curtain and restart on Android', (
    tester,
  ) async {
    await initializeDateFormatting('de');
    SharedPreferences.setMockInitialValues({'stageRunner.sound': false});
    final controller = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await controller.init();
    await controller.startDemo();
    final sound = RunnerSound();
    await runnerSoundSettingsReady(sound);
    await RunnerArt.load();
    StageRunner? game;
    var runs = 0;
    var screenshotSurface = false;

    Future<void> frames(int count) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    Future<void> screenshot(String name) async {
      if (Platform.isAndroid && !screenshotSurface) {
        // The integration binding restores the original surface at teardown.
        await binding.convertFlutterSurfaceToImage();
        screenshotSurface = true;
      }
      await tester.pump();
      final bytes = await binding.takeScreenshot(name);
      final file = File('${Directory.systemTemp.path}/$name.png');
      await file.writeAsBytes(bytes);
      debugPrint('Runner screenshot: ${file.path}');
    }

    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: StageRunnerScreen(
            controller: controller,
            sound: sound,
            random: Random(4),
            onRun: (next) {
              game = next..invincible = true;
              runs++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sound.enabled.value, isFalse);
      final start = find.text('Vorhang auf');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await frames(5);
      final stage = find.byKey(const ValueKey('runner-stage'));
      expect(stage, findsOneWidget);
      final first = game!;
      final ground = first.y;
      final hold = await tester.startGesture(tester.getCenter(stage));
      await frames(30);
      expect(first.holding, isTrue);
      expect(first.y, lessThan(ground - .05));
      await hold.up();
      final lifted = first.y;
      await frames(50);
      expect(first.holding, isFalse);
      expect(first.y, greaterThan(lifted));
      expect(first.meters, greaterThan(0));
      await screenshot('runner-smoke-portrait');

      // Exercise the real native audio plugin, with no member service involved.
      await tester.tap(find.byKey(const ValueKey('runner-sound')));
      await frames(15);
      expect(sound.enabled.value, isTrue);
      final soundingHold = await tester.startGesture(tester.getCenter(stage));
      await frames(12);
      await soundingHold.up();
      await tester.tap(find.byKey(const ValueKey('runner-sound')));
      expect(sound.enabled.value, isFalse);

      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        if (find.text('Tippen zum Weiterlaufen').evaluate().isNotEmpty) break;
      }
      expect(find.text('Tippen zum Weiterlaufen'), findsOneWidget);
      expect(
        tester.getSize(stage).width,
        greaterThan(tester.getSize(stage).height),
      );
      final pausedAt = first.time;
      await frames(6);
      expect(first.time, pausedAt);
      await tester.tap(find.text('Tippen zum Weiterlaufen'));
      await frames(15);
      expect(first.time, greaterThan(pausedAt));
      await screenshot('runner-smoke-landscape');

      // Put one ordinary crate across the runner to exercise the real collision
      // and curtain path without depending on the random course's timing.
      first
        ..invincible = false
        ..obstacles.add(
          Obstacle()
            ..left = first.runnerWorldX - .05
            ..width = .5
            ..top = 0
            ..bottom = 1,
        );
      await frames(2);
      expect(first.over, isTrue);
      expect(first.hitBy, ObstacleKind.crate);
      final score = first.score;
      for (var i = 0; i < 150 && find.text('Nochmal').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Der Vorhang fällt!'), findsOneWidget);
      expect(first.score, score);
      await tester.ensureVisible(find.text('Nochmal'));
      await tester.tap(find.text('Nochmal'));
      await frames(5);
      expect(runs, 2);
      expect(identical(first, game), isFalse);
      expect(game!.over, isFalse);
      expect(game!.meters, lessThan(first.meters));
      expect(stage, findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      sound.dispose();
      controller.dispose();
      await SystemChrome.setPreferredOrientations([]);
    }
  });
}
