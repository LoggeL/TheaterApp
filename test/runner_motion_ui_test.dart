import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/games/data/runner_motion_preferences.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

const _setting = 'stageRunner.sceneryMotion';
final _settings = find.byKey(const ValueKey('runner-settings'));
final _switch = find.byKey(const ValueKey('runner-scenery-motion'));

class _Sound implements RunnerSound, RunnerMusic {
  final _enabled = ValueNotifier(true);
  bool playing = false;
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  void prepare() {}
  @override
  void play(RunnerSfx sfx) {}
  @override
  void startMusic() => playing = true;
  @override
  void stopMusic() => playing = false;
  @override
  void pauseMusic() => playing = false;
  @override
  void resumeMusic() => playing = true;
  @override
  void warmUp() {}
  @override
  void useTune(Uint8List? tune) {}
  @override
  void dispose() => _enabled.dispose();
}

Future<void> _pumpGame(
  WidgetTester tester, {
  RunnerMotionPreferences? preferences,
  ValueChanged<StageRunner>? onRun,
  _Sound? sound,
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
  );
  await controller.startDemo();
  addTearDown(controller.dispose);
  final audio = sound ?? _Sound();
  addTearDown(audio.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: StageRunnerScreen(
        controller: controller,
        sound: audio,
        motionPreferences: preferences,
        onRun: onRun,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a quiet stage stays selected after reopening the game', (
    tester,
  ) async {
    await _pumpGame(tester, width: 320, textScale: 1.8);
    await tester.tap(_settings);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_switch).value, isTrue);
    await tester.ensureVisible(_switch);
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_switch).value, isFalse);
    expect((await SharedPreferences.getInstance()).getBool(_setting), isFalse);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Fertig'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());

    await _pumpGame(tester);
    await tester.tap(_settings);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_switch).value, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing motion pauses the run until the next stage tap', (
    tester,
  ) async {
    late StageRunner game;
    var runs = 0;
    final sound = _Sound();
    await _pumpGame(
      tester,
      sound: sound,
      onRun: (value) {
        game = value;
        runs++;
      },
    );
    await tester.scrollUntilVisible(find.text('Vorhang auf'), 300);
    await tester.tap(find.text('Vorhang auf'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(game.distance, greaterThan(0));
    await tester.tap(_settings);
    final pausedAt = game.distance;
    await tester.pumpAndSettle();
    expect(sound.playing, isFalse);
    expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);
    await tester.tap(_switch);
    await tester.pumpAndSettle();
    expect(game.distance, pausedAt);
    await tester.tap(find.text('Fertig'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(game.distance, pausedAt);
    expect(sound.playing, isFalse);
    await tester.tap(find.byKey(const ValueKey('runner-stage')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(game.distance, greaterThan(pausedAt));
    expect(sound.playing, isTrue);
    expect(runs, 1);
    expect(find.byKey(const ValueKey('runner-paused')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('system reduced motion overrides the saved moving setting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({_setting: true});
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _pumpGame(tester);
    await tester.tap(_settings);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_switch).value, isFalse);
    expect(tester.widget<SwitchListTile>(_switch).onChanged, isNull);
    expect(find.textContaining('Auf deinem Gerät ist'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(_setting), isTrue);

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(_switch).value, isTrue);
    expect(tester.widget<SwitchListTile>(_switch).onChanged, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('starting waits for a stored quiet setting to finish loading', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({_setting: false});
    final load = Completer<SharedPreferences>();
    final preferences = RunnerMotionPreferences(
      loadPreferences: () => load.future,
    );
    addTearDown(preferences.dispose);
    await _pumpGame(tester, preferences: preferences);
    Finder startButton() => find.widgetWithText(FilledButton, 'Vorhang auf');
    await tester.scrollUntilVisible(find.text('Vorhang auf'), 300);
    expect(tester.widget<FilledButton>(startButton()).onPressed, isNull);
    load.complete(await SharedPreferences.getInstance());
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(startButton()).onPressed, isNotNull);
    expect(preferences.sceneryMotion, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
