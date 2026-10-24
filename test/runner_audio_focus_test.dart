import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

/// Logs what a player is asked to do; any other call throws.
class _Player extends Fake implements AudioPlayer {
  _Player(this.log) {
    log.add('new player');
  }
  final List<String> log;
  @override
  PlayerState state = PlayerState.stopped;
  @override
  set positionUpdater(PositionUpdater? updater) {}
  @override
  Future<void> setPlayerMode(PlayerMode mode) async {}
  @override
  Future<void> setReleaseMode(ReleaseMode mode) async {
    if (mode == ReleaseMode.loop) {
      music = true;
      log.add('music player');
    }
  }

  /// The looping player is the music's.
  bool music = false;
  @override
  Future<void> setAudioContext(AudioContext ctx) async =>
      log.add('player context');
  @override
  Future<void> setSource(Source source) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<Duration?> getDuration() async => const Duration(milliseconds: 400);
  @override
  Future<void> resume() async {
    state = PlayerState.playing;
    log.add(music ? 'music' : 'resume');
  }

  @override
  Future<void> stop() async => state = PlayerState.stopped;
  @override
  Future<void> pause() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('next to other apps\' music', () {
    test('the effects take no audio focus and mix on iOS', () {
      final android = PluginRunnerSound.effectsAudioContext.android;
      expect(android.audioFocus, AndroidAudioFocus.none);
      expect(android.usageType, AndroidUsageType.game);
      expect(android.contentType, AndroidContentType.sonification);
      expect(android.isSpeakerphoneOn, isFalse);
      expect(android.audioMode, AndroidAudioMode.normal);
      expect(android.stayAwake, isFalse);

      // Ambient mixes by itself and keeps to the silent switch.
      final iOS = PluginRunnerSound.effectsAudioContext.iOS;
      expect(iOS.category, AVAudioSessionCategory.ambient);
      expect(iOS.options, isEmpty);
    });

    testWidgets('Android gets AUDIOFOCUS_NONE, USAGE_GAME and '
        'CONTENT_TYPE_SONIFICATION', (tester) async {
      expect(PluginRunnerSound.effectsAudioContext.toJson(), {
        'isSpeakerphoneOn': false,
        'audioMode': 0,
        'stayAwake': false,
        'contentType': 4,
        'usageType': 14,
        'audioFocus': 0,
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets(
      'iOS gets the ambient category',
      (tester) async {
        expect(PluginRunnerSound.effectsAudioContext.toJson(), {
          'category': 'ambient',
          'options': <String>[],
        });
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets('the context is set once, before the first player', (
      tester,
    ) async {
      final log = <String>[];
      final contexts = <AudioContext>[];
      final setting = Completer<void>();
      final sound = PluginRunnerSound(
        newPlayer: () => _Player(log),
        othersPlaying: () async => false,
        setAudioContext: (ctx) {
          contexts.add(ctx);
          log.add('context');
          return setting.future;
        },
      );
      await tester.pump();

      // The first tap: the effects wait until the platform has the context.
      sound.prepare();
      sound.play(RunnerSfx.whoosh);
      await tester.pump(const Duration(milliseconds: 50));
      expect(log, ['context']);
      setting.complete();
      await tester.pump();
      expect(log.first, 'context');
      expect(
        log.where((e) => e == 'new player'),
        hasLength(RunnerSfx.values.length),
      );
      expect(log.last, 'resume');

      // Later plays and runs set nothing again.
      sound.play(RunnerSfx.rose);
      sound.prepare();
      await tester.pump();
      expect(contexts, [PluginRunnerSound.effectsAudioContext]);
      sound.dispose();
    });

    testWidgets('a muted game sets nothing until the sound is on', (
      tester,
    ) async {
      final log = <String>[];
      final sound = PluginRunnerSound(
        newPlayer: () => _Player(log),
        othersPlaying: () async => false,
        setAudioContext: (ctx) async => log.add('context'),
      );
      await tester.pump();
      sound.setEnabled(false);
      sound.play(RunnerSfx.whoosh);
      await tester.pump();
      expect(log, isEmpty);

      sound.setEnabled(true);
      sound.play(RunnerSfx.whoosh);
      await tester.pump();
      expect(log.first, 'context');
      expect(log.where((e) => e == 'context'), hasLength(1));
      expect(log.last, 'resume');
      sound.dispose();
    });

    testWidgets('a context the platform refuses leaves the effects playing', (
      tester,
    ) async {
      final log = <String>[];
      final sound = PluginRunnerSound(
        newPlayer: () => _Player(log),
        othersPlaying: () async => false,
        setAudioContext: (ctx) async => throw Exception('no session'),
      );
      await tester.pump();
      sound.play(RunnerSfx.whoosh);
      await tester.pump();
      expect(log, ['new player', 'resume']);
      sound.dispose();
    });

    // Android's isMusicActive also hears the game's own effects: right after
    // the crash of the last run, a new run would keep quiet.
    testWidgets('the game\'s own effect does not count as other music', (
      tester,
    ) async {
      final log = <String>[];
      var asked = 0;
      var others = true;
      final sound = PluginRunnerSound(
        newPlayer: () => _Player(log),
        othersPlaying: () async {
          asked++;
          return others;
        },
        setAudioContext: (ctx) async {},
      );
      await tester.pump();
      sound.play(RunnerSfx.crash);
      await tester.pump(const Duration(milliseconds: 500));
      sound.startMusic();
      await tester.pump();
      expect(asked, 0);
      expect(log, contains('music'));
      sound.stopMusic();
      await tester.pump(musicFadeOut);
      await tester.pump();

      // Once the effects have sounded out, the system's answer counts.
      await tester.pump(PluginRunnerSound.ownSoundTail);
      log.clear();
      sound.startMusic();
      await tester.pump(musicFadeIn);
      expect(asked, 1);
      expect(log, isNot(contains('music')));
      sound.stopMusic();
      await tester.pump(musicFadeOut);

      // Within the tail the last answer stands: still the other app's.
      sound.play(RunnerSfx.curtain);
      await tester.pump();
      others = false;
      sound.startMusic();
      await tester.pump(musicFadeIn);
      expect(asked, 1);
      expect(log, isNot(contains('music')));
      sound.dispose();
    });

    testWidgets('iOS asks right after an effect: its hint hears only other '
        'apps', (tester) async {
      final log = <String>[];
      var asked = 0;
      final sound = PluginRunnerSound(
        newPlayer: () => _Player(log),
        othersPlaying: () async {
          asked++;
          return true;
        },
        setAudioContext: (ctx) async {},
      );
      await tester.pump();
      sound.play(RunnerSfx.crash);
      await tester.pump();
      sound.startMusic();
      await tester.pump(musicFadeIn);
      expect(asked, 1);
      expect(log, isNot(contains('music')));
      sound.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
