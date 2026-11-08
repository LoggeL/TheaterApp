import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/runner_volume_settings.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

/// Logs the calls on a player as "n call", n counting the players in
/// the order they were made; any other call throws.
class _Player extends Fake implements AudioPlayer {
  _Player(this.log, this.n);
  final List<String> log;
  final int n;
  @override
  PlayerState state = PlayerState.stopped;
  @override
  set positionUpdater(PositionUpdater? updater) {}
  @override
  Future<void> setPlayerMode(PlayerMode mode) async {}
  @override
  Future<void> setReleaseMode(ReleaseMode mode) async {}
  @override
  Future<void> setSource(Source source) async => log.add('$n source');
  @override
  Future<void> setVolume(double volume) async =>
      log.add('$n volume ${volume.toStringAsFixed(3)}');
  @override
  Future<Duration?> getDuration() async => const Duration(milliseconds: 400);
  @override
  Future<void> setAudioContext(AudioContext ctx) async {}
  @override
  Future<void> resume() async {
    state = PlayerState.playing;
    log.add('$n resume');
  }

  @override
  Future<void> pause() async {
    state = PlayerState.paused;
    log.add('$n pause');
  }

  @override
  Future<void> stop() async {
    state = PlayerState.stopped;
    log.add('$n stop');
  }

  @override
  Future<void> dispose() async {}
}

PluginRunnerSound _plugin(List<String> log) {
  var players = 0;
  return PluginRunnerSound(
    newPlayer: () => _Player(log, ++players),
    othersPlaying: () async => false,
  );
}

/// Logs the Web Audio calls by channel; the volumes as last set.
class _WebAudio implements WebAudio {
  final log = <String>[];
  final volumes = <WebAudioChannel, double>{};
  var decoded = 0;
  @override
  void resume() {}
  @override
  void suspend() {}
  @override
  void close() {}
  @override
  void setVolume(WebAudioChannel channel, double gain) =>
      volumes[channel] = gain;
  @override
  Future<WebAudioClip> decode(
    Uint8List bytes,
    double volume,
    WebAudioChannel channel,
  ) async {
    decoded++;
    return _Clip(this, channel);
  }
}

class _Clip implements WebAudioClip {
  _Clip(this.audio, this.channel);
  final _WebAudio audio;
  final WebAudioChannel channel;
  @override
  WebAudioVoice play({bool loop = false, Duration fadeIn = Duration.zero}) {
    audio.log.add('play ${channel.name}');
    return _Voice(audio, channel);
  }
}

class _Voice implements WebAudioVoice {
  _Voice(this.audio, this.channel);
  final _WebAudio audio;
  final WebAudioChannel channel;
  @override
  void stop({Duration fadeOut = Duration.zero}) =>
      audio.log.add('stop ${channel.name}');
}

/// A sound with volumes that only logs.
class _Sound implements RunnerSound, RunnerVolumes {
  final _enabled = ValueNotifier(true);
  final _music = ValueNotifier(1.0), _effects = ValueNotifier(1.0);
  final played = <RunnerSfx>[];
  final musicSet = <double>[], effectsSet = <double>[];
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  ValueListenable<double> get musicVolume => _music;
  @override
  ValueListenable<double> get effectsVolume => _effects;
  @override
  void setMusicVolume(double share) {
    musicSet.add(share);
    _music.value = share;
  }

  @override
  void setEffectsVolume(double share) {
    effectsSet.add(share);
    _effects.value = share;
  }

  @override
  void previewEffect(RunnerSfx sfx) => played.add(sfx);

  @override
  void prepare() {}
  @override
  void play(RunnerSfx sfx) => played.add(sfx);
  @override
  void startMusic() {}
  @override
  void stopMusic() {}
  @override
  void dispose() {
    _enabled.dispose();
    _music.dispose();
    _effects.dispose();
  }
}

Future<void> _pumpGame(WidgetTester tester, RunnerSound sound) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
  );
  await controller.startDemo();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: StageRunnerScreen(controller: controller, sound: sound),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('runner-settings')));
  await tester.pumpAndSettle();
}

String _percent(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(ValueKey('runner-volume-$id-text'))).data!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('volume math', () {
    test('a share is heard by its square, exactly silent and full at the '
        'ends', () {
      expect(runnerVolumeGain(0), 0);
      expect(runnerVolumeGain(1), 1);
      expect(runnerVolumeGain(.5), .25);
      expect(runnerVolumeGain(.8), closeTo(.64, 1e-12));
      expect(runnerVolumeGain(-.2), 0);
      expect(runnerVolumeGain(1.3), 1);
      expect(runnerVolumeGain(double.nan), 0);
      // Louder all the way up.
      var last = -1.0;
      for (var i = 0; i <= 20; i++) {
        final gain = runnerVolumeGain(i / 20);
        expect(gain, greaterThan(last));
        last = gain;
      }
    });

    test('only finite shares from 0 to 1 are taken from storage', () {
      expect(runnerVolumeShare(.4), .4);
      expect(runnerVolumeShare(1), 1.0);
      expect(runnerVolumeShare(1.5), 1.0);
      expect(runnerVolumeShare(-1), 0.0);
      expect(runnerVolumeShare(double.nan), isNull);
      expect(runnerVolumeShare(double.infinity), isNull);
      expect(runnerVolumeShare('0.5'), isNull);
      expect(runnerVolumeShare(null), isNull);
    });

    test('the settings show whole percents', () {
      expect(runnerVolumeText(0), '0 %');
      expect(runnerVolumeText(.85), '85 %');
      expect(runnerVolumeText(1), '100 %');
      expect(runnerVolumeText(.333), '33 %');
    });
  });

  group('native', () {
    testWidgets('the volumes are remembered on this device, the latest of a '
        'quick series', (tester) async {
      final log = <String>[];
      final sound = _plugin(log);
      await tester.pump();
      expect((sound.musicVolume.value, sound.effectsVolume.value), (1.0, 1.0));
      for (final share in [.9, .7, .55]) {
        sound.setMusicVolume(share);
      }
      sound.setEffectsVolume(.25);
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(runnerMusicVolumeKey), .55);
      expect(prefs.getDouble(runnerEffectsVolumeKey), .25);
      sound.dispose();

      final again = _plugin(log);
      await tester.pump();
      expect(again.musicVolume.value, .55);
      expect(again.effectsVolume.value, .25);
      // Mute stays a switch of its own.
      expect(again.enabled.value, isTrue);
      again.dispose();
    });

    testWidgets('a broken stored volume leaves the full one', (tester) async {
      SharedPreferences.setMockInitialValues({
        runnerMusicVolumeKey: 'laut',
        runnerEffectsVolumeKey: 7.0,
        'stageRunner.sound': false,
      });
      final sound = _plugin([]);
      await tester.pump();
      expect(sound.musicVolume.value, 1.0);
      expect(sound.effectsVolume.value, 1.0, reason: 'at most 100 %');
      expect(sound.enabled.value, isFalse);
      sound.dispose();
    });

    testWidgets('effects play at their share; at 0 % no player starts and '
        'one still sounding ends', (tester) async {
      final log = <String>[];
      final sound = _plugin(log);
      await tester.pump();
      sound
        ..setEffectsVolume(.5)
        ..play(RunnerSfx.rose);
      await tester.pump();
      // The pickup's own .7, at half the slider a quarter of it.
      expect(log, ['1 source', '1 volume 0.175', '1 resume']);

      log.clear();
      sound.setEffectsVolume(0);
      await tester.pump();
      expect(log, ['1 stop']);
      log.clear();
      sound.play(RunnerSfx.rose);
      sound.play(RunnerSfx.crash);
      await tester.pump(const Duration(seconds: 1));
      expect(log, isEmpty);

      // Up again: the player takes the new volume before it plays.
      sound
        ..setEffectsVolume(1)
        ..play(RunnerSfx.rose);
      await tester.pump();
      expect(log, ['1 volume 0.700', '1 resume']);
      sound.dispose();
    });

    testWidgets('the music follows its volume at once, through its fades', (
      tester,
    ) async {
      final log = <String>[];
      final sound = _plugin(log);
      await tester.pump();
      sound.startMusic();
      await tester.pump(musicFadeIn);
      await tester.pump();
      expect(log.last, '1 volume 0.320');

      log.clear();
      sound.setMusicVolume(.5);
      await tester.pump();
      expect(log, ['1 volume 0.080']);

      // A drag sets the latest volume, not every step of it.
      log.clear();
      for (var i = 1; i <= 9; i++) {
        sound.setMusicVolume(i / 10);
      }
      await tester.pump();
      expect(log, ['1 volume ${(.32 * .81).toStringAsFixed(3)}']);

      // 0 % holds the player; up again it goes on.
      log.clear();
      sound.setMusicVolume(0);
      await tester.pump();
      expect(log, ['1 pause']);
      log.clear();
      sound.setMusicVolume(.5);
      await tester.pump();
      expect(log, ['1 volume 0.080', '1 resume']);

      // The fade-out goes down from the chosen volume.
      log.clear();
      sound.stopMusic();
      await tester.pump(musicFadeOut);
      await tester.pump();
      final volumes = [
        for (final e in log)
          if (e.contains('volume')) double.parse(e.split(' ').last),
      ];
      expect(volumes, isNotEmpty);
      expect(volumes.every((v) => v <= .08), isTrue);
      expect(volumes.last, 0);
      expect(log.last, '1 stop');
      sound.dispose();
    });

    testWidgets('at 0 % the music of a run never starts', (tester) async {
      SharedPreferences.setMockInitialValues({runnerMusicVolumeKey: 0.0});
      final log = <String>[];
      final sound = _plugin(log);
      await tester.pump();
      sound.startMusic();
      await tester.pump(musicFadeIn);
      await tester.pump();
      expect(log.where((e) => e.endsWith('resume')), isEmpty);
      // Turned up during the run, it comes in.
      sound.setMusicVolume(1);
      await tester.pump();
      await tester.pump(musicFadeIn);
      expect(log.where((e) => e.endsWith('resume')), hasLength(1));
      expect(log.indexOf('1 volume 0.320'), log.indexOf('1 resume') - 1);
      sound.dispose();
    });

    testWidgets('a change waiting while the sound is muted does not block '
        'later ones', (tester) async {
      final log = <String>[];
      var players = 0;
      Completer<void>? gate;
      final sound = PluginRunnerSound(
        newPlayer: () => _Player(log, ++players),
        othersPlaying: () async {
          await gate?.future;
          return false;
        },
      );
      await tester.pump();
      sound.startMusic();
      await tester.pump(musicFadeIn);
      await tester.pump();
      // Paused, then on again: its resume waits for a slow platform call,
      // the volume behind it, and mute behind that.
      sound.pauseMusic();
      await tester.pump();
      gate = Completer<void>();
      sound
        ..resumeMusic()
        ..setMusicVolume(.5)
        ..setEnabled(false);
      gate.complete();
      await tester.pump();
      sound.setEnabled(true);
      await tester.pump();
      expect(log.last, '1 resume');

      // Later changes still reach the music playing.
      log.clear();
      sound.setMusicVolume(.25);
      await tester.pump();
      expect(log, ['1 volume ${(.32 * .0625).toStringAsFixed(3)}']);
      sound.setMusicVolume(0);
      await tester.pump();
      expect(log.last, '1 pause');
      sound.dispose();
    });
  });

  group('browser', () {
    test(
      'each channel takes its volume at once, without decoding again',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        SharedPreferences.setMockInitialValues({
          runnerMusicVolumeKey: .5,
          runnerEffectsVolumeKey: .2,
        });
        final audio = _WebAudio();
        final sound = WebRunnerSound(open: () => audio);
        await pumpEventQueue();
        sound
          ..prepare()
          ..startMusic();
        for (
          var i = 0;
          i < 200 && audio.decoded < RunnerSfx.values.length + 1;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(audio.volumes[WebAudioChannel.music], .25);
        expect(audio.volumes[WebAudioChannel.effects], closeTo(.04, 1e-12));
        expect(audio.log, ['play music']);
        final decoded = audio.decoded;

        audio.log.clear();
        sound
          ..setMusicVolume(1)
          ..setEffectsVolume(.5)
          ..play(RunnerSfx.rose);
        expect(audio.volumes, {
          WebAudioChannel.music: 1.0,
          WebAudioChannel.effects: .25,
        });
        expect(audio.log, ['play effects'], reason: 'the music plays on');
        expect(audio.decoded, decoded);

        // 0 %: silent channels, the music ends, nothing new starts.
        audio.log.clear();
        sound
          ..setEffectsVolume(0)
          ..setMusicVolume(0)
          ..play(RunnerSfx.rose)
          ..startMusic();
        expect(audio.volumes, {
          WebAudioChannel.music: 0.0,
          WebAudioChannel.effects: 0.0,
        });
        expect(audio.log, ['stop effects', 'stop music']);

        // Up again during the run: the music comes back.
        audio.log.clear();
        sound.setMusicVolume(.5);
        expect(audio.log, ['play music']);
        expect(audio.decoded, decoded);
        sound.dispose();
      },
    );

    test('a preview before the first run sounds once the effects are '
        'decoded', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final audio = _WebAudio();
      final sound = WebRunnerSound(open: () => audio);
      await pumpEventQueue();
      // A quick drag before anything is decoded: one preview, the latest.
      sound
        ..previewEffect(RunnerSfx.rose)
        ..previewEffect(RunnerSfx.rose);
      expect(audio.log, isEmpty, reason: 'only being decoded yet');
      for (var i = 0; i < 200 && audio.log.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await pumpEventQueue();
      expect(audio.log, ['play effects']);

      // Decoded: at once (the one before starts over).
      audio.log.clear();
      sound.previewEffect(RunnerSfx.rose);
      expect(audio.log, ['stop effects', 'play effects']);

      // At 0 % and muted: nothing.
      audio.log.clear();
      sound
        ..setEffectsVolume(0)
        ..previewEffect(RunnerSfx.rose)
        ..setEffectsVolume(1)
        ..setEnabled(false)
        ..previewEffect(RunnerSfx.rose);
      expect(audio.log.where((e) => e.startsWith('play')), isEmpty);
      sound.dispose();
    });

    test('a preview waiting for decoding stays silent once muted', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final audio = _WebAudio();
      final sound = WebRunnerSound(open: () => audio);
      await pumpEventQueue();
      sound
        ..previewEffect(RunnerSfx.rose)
        ..setEnabled(false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await pumpEventQueue();
      expect(audio.log.where((e) => e.startsWith('play')), isEmpty);
      sound.dispose();
    });

    test('a context opened before the volumes were known gets them', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({runnerMusicVolumeKey: .5});
      final audio = _WebAudio();
      final sound = WebRunnerSound(open: () => audio)..prepare();
      await pumpEventQueue();
      expect(audio.volumes, {
        WebAudioChannel.music: .25,
        WebAudioChannel.effects: 1.0,
      });
      sound.dispose();
    });
  });

  group('settings', () {
    testWidgets('"Ton" has a slider each for the music and the effects, '
        'read out with their percent', (tester) async {
      final sound = _Sound();
      addTearDown(sound.dispose);
      await _pumpGame(tester, sound);
      await _openSettings(tester);
      expect(find.text('Spieleinstellungen'), findsOneWidget);
      expect(find.text('Ton'), findsOneWidget);
      expect(find.text('Bewegung'), findsOneWidget);
      expect(_percent(tester, 'music'), '100 %');
      expect(_percent(tester, 'effects'), '100 %');

      final handle = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.byKey(const ValueKey('runner-volume-music'))),
        isSemantics(
          label: 'Musik',
          value: '100 %',
          decreasedValue: '95 %',
          isSlider: true,
          isEnabled: true,
          hasIncreaseAction: true,
          hasDecreaseAction: true,
        ),
      );
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('runner-volume-effects')),
        ),
        isSemantics(label: 'Effekte', value: '100 %', isSlider: true),
      );
      // Turned down by a screen reader: one step of 5 %.
      final music = tester.getSemantics(
        find.byKey(const ValueKey('runner-volume-music')),
      );
      music.owner!.performAction(music.id, SemanticsAction.decrease);
      await tester.pumpAndSettle();
      expect(sound.musicSet.last, closeTo(.95, 1e-9));
      expect(_percent(tester, 'music'), '95 %');
      handle.dispose();
    });

    testWidgets('the music changes as the slider moves; the effects play a '
        'preview, not at every step', (tester) async {
      final sound = _Sound();
      addTearDown(sound.dispose);
      await _pumpGame(tester, sound);
      await _openSettings(tester);

      final music = find.byKey(const ValueKey('runner-volume-music'));
      await tester.tap(music);
      await tester.pump();
      expect(sound.musicSet.last, closeTo(.5, .05));
      expect(_percent(tester, 'music'), runnerVolumeText(sound.musicSet.last));
      expect(sound.played, isEmpty, reason: 'the music is its own preview');

      // A drag right across: one preview at once, one at its end.
      final effects = find.byKey(const ValueKey('runner-volume-effects'));
      final gesture = await tester.startGesture(tester.getCenter(effects));
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(-5, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
      expect(sound.effectsSet.length, greaterThan(3));
      expect(sound.played, [RunnerVolumeSettings.previewSfx]);
      await tester.pump(RunnerVolumeSettings.previewGap);
      expect(sound.played, hasLength(2));
      await tester.pump(RunnerVolumeSettings.previewGap * 3);
      expect(sound.played, hasLength(2));
      expect(
        _percent(tester, 'effects'),
        runnerVolumeText(sound.effectsSet.last),
      );

      // Muted, the sliders stay and say why nothing sounds.
      sound.setEnabled(false);
      await tester.pump();
      await tester.drag(effects, const Offset(20, 0));
      await tester.pump(RunnerVolumeSettings.previewGap * 2);
      expect(sound.played, hasLength(2), reason: 'nothing to hear');
      expect(
        find.text(
          'Der Ton ist gerade aus. Die Lautstärke gilt, sobald du ihn wieder einschaltest.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Fertig'));
      await tester.pumpAndSettle();
    });

    testWidgets('in the pause of a run the music is heard while it is turned, '
        'and the volume stays on this device', (tester) async {
      final log = <String>[];
      final sound = _plugin(log);
      addTearDown(sound.dispose);
      StageRunner? game;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
      );
      await controller.startDemo();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: StageRunnerScreen(
            controller: controller,
            sound: sound,
            onRun: (g) => game = g,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vorhang auf'));
      await tester.pump();
      expect(game, isNotNull);
      // On until the music has risen in full.
      game!.invincible = true;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      log.clear();
      await _openSettings(tester);
      final time = game!.time;
      // The pause holds the music player (the one that pauses).
      final paused = log.where((e) => e.endsWith(' pause')).toList();
      expect(paused, hasLength(1));
      final music = paused.single.split(' ').first;

      log.clear();
      await tester.tap(find.byKey(const ValueKey('runner-volume-music')));
      await tester.pump();
      final half = '$music volume ${(.32 * .25).toStringAsFixed(3)}';
      expect(log.take(2), [half, '$music resume']);
      expect(log.skip(2), everyElement(half));
      expect(sound.musicVolume.value, .5);

      log.clear();
      await tester.drag(
        find.byKey(const ValueKey('runner-volume-effects')),
        const Offset(-400, 0),
      );
      await tester.pump();
      expect(_percent(tester, 'effects'), '0 %');
      expect(game!.time, time);
      // At 0 % the drag's last previews stay silent.
      expect(log.where((e) => e.endsWith(' resume')).length, lessThan(3));
      await tester.tap(find.text('Fertig'));
      await tester.pumpAndSettle();
      // Closed, the run waits for its tap with the music held.
      expect(log.last, '$music pause');
      expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(runnerEffectsVolumeKey), 0.0);
      expect(prefs.getDouble(runnerMusicVolumeKey), .5);
      // The tail of the effects heard before.
      await tester.pump(PluginRunnerSound.ownSoundTail);
    });
  });
}
