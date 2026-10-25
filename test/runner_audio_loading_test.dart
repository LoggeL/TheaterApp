import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

const _musicAsset = 'assets/games/stage_runner/music.mp3';
final _assets = [
  for (final sfx in RunnerSfx.values) 'assets/${sfx.asset}',
  _musicAsset,
];

class _Player extends Fake implements AudioPlayer {
  _Player(this.log, {this.loading, this.sourceHandler});
  final List<String> log;
  final Completer<void>? loading;
  final Future<void> Function(Source)? sourceHandler;
  @override
  PlayerState state = PlayerState.stopped;
  @override
  set positionUpdater(PositionUpdater? updater) {}
  @override
  Future<void> setPlayerMode(PlayerMode mode) async {}
  @override
  Future<void> setReleaseMode(ReleaseMode mode) async {}
  @override
  Future<void> setAudioContext(AudioContext context) async {}
  @override
  Future<void> setSource(Source source) async {
    log.add('load');
    if (sourceHandler case final handle?) {
      await handle(source);
    } else {
      await loading?.future;
    }
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<Duration?> getDuration() async => const Duration(milliseconds: 500);
  @override
  Future<void> resume() async {
    state = PlayerState.playing;
    log.add('play');
  }

  @override
  Future<void> stop() async => state = PlayerState.stopped;
  @override
  Future<void> pause() async => state = PlayerState.paused;
  @override
  Future<void> dispose() async {}
}

class _Bundle extends CachingAssetBundle {
  _Bundle({this.hold = false});
  final bool hold;
  final calls = <String, int>{};
  final failOnce = <String>{};
  final _pending = <String, Completer<ByteData>>{};

  ByteData _data(String key) =>
      ByteData.sublistView(Uint8List.fromList([_assets.indexOf(key), 1, 2, 3]));

  @override
  Future<ByteData> load(String key) async {
    if (!_assets.contains(key)) throw StateError('unexpected asset: $key');
    calls[key] = (calls[key] ?? 0) + 1;
    if (failOnce.remove(key)) throw StateError('temporary asset failure');
    if (!hold) return _data(key);
    return (_pending[key] ??= Completer<ByteData>()).future;
  }

  void complete() {
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) entry.value.complete(_data(entry.key));
    }
  }
}

class _Audio implements WebAudio {
  final log = <String>[];
  final decoded = <int>[];
  final pending = <int, Completer<WebAudioClip>>{};
  @override
  void resume() => log.add('resume');
  @override
  void suspend() => log.add('suspend');
  @override
  void close() => log.add('close');
  @override
  Future<WebAudioClip> decode(Uint8List bytes, double volume) async {
    decoded.add(bytes.first);
    if (pending[bytes.first] case final completion?) return completion.future;
    return _Clip(this, bytes.first);
  }
}

class _Clip implements WebAudioClip {
  _Clip(this.audio, this.id);
  final _Audio audio;
  final int id;
  @override
  WebAudioVoice play({bool loop = false, Duration fadeIn = Duration.zero}) {
    audio.log.add('play $id ${loop ? 'loop' : 'once'}');
    return _Voice(audio);
  }
}

class _Voice implements WebAudioVoice {
  _Voice(this.audio);
  final _Audio audio;
  @override
  void stop({Duration fadeOut = Duration.zero}) => audio.log.add('stop');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('native audio loading', () {
    testWidgets('opening a remembered muted game creates no audio players', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'stageRunner.sound': false});
      final log = <String>[];
      final players = <_Player>[];
      final sound = PluginRunnerSound(
        newPlayer: () {
          final player = _Player(log);
          players.add(player);
          return player;
        },
        othersPlaying: () async => false,
        setAudioContext: (_) async => log.add('context'),
      );
      addTearDown(sound.dispose);
      // This is the screen's real ordering: it does not wait for preferences.
      sound
        ..warmUp()
        ..prepare()
        ..startMusic();
      await tester.pump();
      expect(sound.enabled.value, isFalse);
      expect(players, isEmpty);
      expect(log, isEmpty);

      sound.setEnabled(true);
      await tester.pump();
      expect(players, hasLength(RunnerSfx.values.length + 1));
      expect(log.where((call) => call == 'context'), hasLength(1));
      expect(log, contains('play'));
      await tester.pump(musicFadeIn);
    });

    testWidgets('muting while the audio context opens cancels queued loads', (
      tester,
    ) async {
      final context = Completer<void>();
      final log = <String>[];
      final players = <_Player>[];
      final sound = PluginRunnerSound(
        newPlayer: () {
          final player = _Player(log);
          players.add(player);
          return player;
        },
        othersPlaying: () async => false,
        setAudioContext: (_) {
          log.add('context');
          return context.future;
        },
      );
      addTearDown(sound.dispose);
      sound.warmUp();
      await tester.pump();
      expect(log, ['context']);
      sound
        ..play(RunnerSfx.rose)
        ..startMusic()
        ..setEnabled(false);
      context.complete();
      await tester.pump();
      expect(players, isEmpty);
      expect(log, ['context']);

      sound.setEnabled(true);
      await tester.pump();
      expect(players, hasLength(RunnerSfx.values.length + 1));
      expect(log, contains('play'));
      await tester.pump(musicFadeIn);
    });

    testWidgets('muting during a sound load stops the remaining warmup', (
      tester,
    ) async {
      final firstLoad = Completer<void>();
      final log = <String>[];
      final players = <_Player>[];
      final sound = PluginRunnerSound(
        newPlayer: () {
          final player = _Player(
            log,
            loading: players.isEmpty ? firstLoad : null,
          );
          players.add(player);
          return player;
        },
        othersPlaying: () async => false,
      );
      addTearDown(sound.dispose);
      sound.warmUp();
      await tester.pump();
      expect(players, hasLength(1));
      expect(log, ['load']);
      sound
        ..play(RunnerSfx.rose)
        ..startMusic()
        ..setEnabled(false);
      firstLoad.complete();
      await tester.pump();
      expect(players, hasLength(1));
      expect(log, ['load']);

      sound.setEnabled(true);
      await tester.pump();
      expect(players, hasLength(RunnerSfx.values.length + 1));
      expect(log, contains('play'));
      await tester.pump(musicFadeIn);
    });

    testWidgets('a user switch wins over a pending saved setting', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'stageRunner.sound': false});
      final sound = PluginRunnerSound(newPlayer: () => _Player([]));
      addTearDown(sound.dispose);
      sound
        ..setEnabled(true)
        ..warmUp();
      await tester.pump();
      expect(sound.enabled.value, isTrue);
    });

    for (final leave in [false, true]) {
      testWidgets(
        'a failed custom tune does not load fallback after ${leave ? 'dispose' : 'mute'}',
        (tester) async {
          final loading = Completer<void>();
          final sources = <Source>[];
          final sound = PluginRunnerSound(
            newPlayer: () => _Player(
              [],
              sourceHandler: (source) {
                sources.add(source);
                return source is BytesSource ? loading.future : Future.value();
              },
            ),
            othersPlaying: () async => false,
          );
          var disposed = false;
          addTearDown(() {
            if (!disposed) sound.dispose();
          });
          sound
            ..useTune(Uint8List.fromList([250, 1, 2, 3]))
            ..startMusic();
          await tester.pump();
          expect(sources, [isA<BytesSource>()]);
          if (leave) {
            sound.dispose();
            disposed = true;
          } else {
            sound.setEnabled(false);
          }
          loading.completeError(StateError('custom tune rejected'));
          await tester.pump();
          expect(sources, [isA<BytesSource>()]);
          await tester.pump(musicFadeIn);
        },
      );
    }
  });

  group('browser audio preload', () {
    testWidgets('intro loads bytes without opening or decoding audio', (
      tester,
    ) async {
      final bundle = _Bundle();
      final audio = _Audio();
      var opened = 0;
      final sound = WebRunnerSound(
        bundle: bundle,
        open: () {
          opened++;
          return audio;
        },
      );
      addTearDown(sound.dispose);
      sound
        ..warmUp()
        ..warmUp();
      await tester.pump();
      expect(bundle.calls, {for (final asset in _assets) asset: 1});
      expect(opened, 0);
      expect(audio.decoded, isEmpty);
      expect(audio.log, isEmpty);

      sound
        ..prepare()
        ..startMusic();
      // This must happen synchronously within the user's gesture.
      expect(opened, 1);
      expect(audio.log, ['resume']);
      await tester.pump();
      expect(bundle.calls.values, everyElement(1));
      expect(audio.decoded.toSet(), {
        for (var i = 0; i < _assets.length; i++) i,
      });
      expect(audio.log, contains('play ${_assets.length - 1} loop'));
      sound.play(RunnerSfx.rose);
      expect(audio.log.last, 'play ${RunnerSfx.rose.index} once');
    });

    testWidgets('starting during preload shares the pending downloads', (
      tester,
    ) async {
      final bundle = _Bundle(hold: true);
      final audio = _Audio();
      final sound = WebRunnerSound(bundle: bundle, open: () => audio);
      addTearDown(sound.dispose);
      sound.warmUp();
      await tester.pump();
      sound
        ..prepare()
        ..startMusic();
      expect(audio.log, ['resume']);
      await tester.pump();
      expect(bundle.calls, {for (final asset in _assets) asset: 1});
      expect(audio.decoded, isEmpty);
      bundle.complete();
      await tester.pump();
      expect(audio.decoded, hasLength(_assets.length));
      expect(audio.log, contains('play ${_assets.length - 1} loop'));
    });

    testWidgets('a failed preload can retry when the run starts', (
      tester,
    ) async {
      final rose = 'assets/${RunnerSfx.rose.asset}';
      final bundle = _Bundle()..failOnce.add(rose);
      final audio = _Audio();
      final sound = WebRunnerSound(bundle: bundle, open: () => audio);
      addTearDown(sound.dispose);
      sound.warmUp();
      await tester.pump();
      sound.prepare();
      await tester.pump();
      expect(bundle.calls[rose], 2);
      expect(
        bundle.calls.entries
            .where((entry) => entry.key != rose)
            .map((e) => e.value),
        everyElement(1),
      );
      sound.play(RunnerSfx.rose);
      expect(audio.log.last, 'play ${RunnerSfx.rose.index} once');
    });

    testWidgets('remembered mute skips preload until sound is enabled', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'stageRunner.sound': false});
      final bundle = _Bundle();
      final audio = _Audio();
      var opened = 0;
      final sound = WebRunnerSound(
        bundle: bundle,
        open: () {
          opened++;
          return audio;
        },
      );
      addTearDown(sound.dispose);
      sound.warmUp();
      await tester.pump();
      expect(sound.enabled.value, isFalse);
      expect(bundle.calls, isEmpty);
      expect(opened, 0);
      sound.setEnabled(true);
      expect(opened, 1);
      expect(audio.log, ['resume']);
      await tester.pump();
      expect(bundle.calls, {for (final asset in _assets) asset: 1});
      expect(audio.decoded, hasLength(_assets.length));
    });

    testWidgets('disposing during preload never opens or decodes audio', (
      tester,
    ) async {
      final bundle = _Bundle(hold: true);
      final audio = _Audio();
      var opened = 0;
      final sound = WebRunnerSound(
        bundle: bundle,
        open: () {
          opened++;
          return audio;
        },
      );
      sound.warmUp();
      await tester.pump();
      sound.dispose();
      bundle.complete();
      await tester.pump();
      expect(opened, 0);
      expect(audio.decoded, isEmpty);
      expect(audio.log, isEmpty);
    });

    testWidgets('muting pending downloads postpones decoding until unmute', (
      tester,
    ) async {
      final bundle = _Bundle(hold: true);
      final audio = _Audio();
      final sound = WebRunnerSound(bundle: bundle, open: () => audio);
      addTearDown(sound.dispose);
      sound.warmUp();
      await tester.pump();
      sound
        ..prepare()
        ..startMusic()
        ..setEnabled(false);
      bundle.complete();
      await tester.pump();
      expect(audio.log, ['resume', 'suspend']);
      expect(audio.decoded, isEmpty);

      sound.setEnabled(true);
      await tester.pump();
      expect(audio.decoded, hasLength(_assets.length));
      expect(audio.log, contains('play ${_assets.length - 1} loop'));
    });

    testWidgets('late downloads do not decode on a closed audio context', (
      tester,
    ) async {
      final bundle = _Bundle(hold: true);
      final audio = _Audio();
      final sound = WebRunnerSound(bundle: bundle, open: () => audio);
      sound.warmUp();
      await tester.pump();
      sound
        ..prepare()
        ..startMusic()
        ..dispose();
      bundle.complete();
      await tester.pump();
      expect(audio.log, ['resume', 'close']);
      expect(audio.decoded, isEmpty);
    });

    testWidgets('returning to the default tune ignores a late custom decode', (
      tester,
    ) async {
      final audio = _Audio();
      final sound = WebRunnerSound(bundle: _Bundle(), open: () => audio);
      addTearDown(sound.dispose);
      sound
        ..prepare()
        ..startMusic();
      await tester.pump();
      expect(audio.log.last, 'play ${_assets.length - 1} loop');
      audio.log.clear();
      final pending = audio.pending[250] = Completer<WebAudioClip>();
      sound.useTune(Uint8List.fromList([250, 1, 2, 3]));
      await tester.pump();
      expect(audio.decoded.where((id) => id == 250), hasLength(1));
      sound.useTune(null);
      pending.complete(_Clip(audio, 250));
      await tester.pump();
      expect(audio.log, isEmpty);
      sound
        ..stopMusic()
        ..startMusic();
      expect(audio.log.last, 'play ${_assets.length - 1} loop');
    });

    testWidgets('prepare shares an in-flight custom tune decode', (
      tester,
    ) async {
      final audio = _Audio();
      final sound = WebRunnerSound(bundle: _Bundle(), open: () => audio);
      addTearDown(sound.dispose);
      sound
        ..prepare()
        ..startMusic();
      await tester.pump();
      final pending = audio.pending[250] = Completer<WebAudioClip>();
      sound.useTune(Uint8List.fromList([250, 1, 2, 3]));
      await tester.pump();
      sound.prepare();
      await tester.pump();
      expect(audio.decoded.where((id) => id == 250), hasLength(1));
      pending.complete(_Clip(audio, 250));
      await tester.pump();
      expect(
        audio.log.where((event) => event == 'play 250 loop'),
        hasLength(1),
      );
    });
  });
}
