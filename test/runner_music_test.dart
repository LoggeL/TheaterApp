import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/stage_runner_music.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

/// An M4A file as far as the app looks at it: an MP4 `ftyp` box.
final _m4a = Uint8List.fromList([0, 0, 0, 24, ...'ftypM4A '.codeUnits, 1, 2]);
final _mp3 = Uint8List.fromList([...'ID3'.codeUnits, 4, 0, 0, 0, 0, 0, 9]);

const _music = '/games/runner/skins/music-gruft.m4a?v=0123456789abcdef';

JsonMap _item(
  String id,
  String kind, {
  bool isDefault = false,
  JsonMap extra = const {},
}) => {
  'id': id,
  'kind': kind,
  'name': id,
  'rarity': 'blau',
  'rarities': ['blau'],
  if (isDefault) 'default': true,
  ...extra,
};

/// A wardrobe with a backdrop that brings its music, worn or not.
JsonMap _wardrobeJson({String backdrop = 'b1'}) => {
  'progress': {
    'meters': 0,
    'earned': 0,
    'opened': 0,
    'crates': 0,
    'nextAt': 2000,
  },
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'blau', 'name': 'Blau', 'color': '#4B69FF', 'weight': 100},
    ],
    'items': [
      _item('c0', 'character', isDefault: true),
      _item('b0', 'backdrop', isDefault: true),
      _item('o0', 'obstacles', isDefault: true),
      _item('f0', 'fx', isDefault: true),
      _item('b1', 'backdrop', extra: {'music': _music}),
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0', 'b1'],
  'selected': {
    'character': 'c0',
    'backdrop': backdrop,
    'obstacles': 'o0',
    'fx': 'f0',
  },
};

/// A sound that also takes the backdrop's music, and logs it.
class _MusicSound implements RunnerSound, RunnerMusic {
  final log = <String>[];
  final tunes = <Uint8List?>[];
  final _enabled = ValueNotifier(true);
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  void prepare() {}
  @override
  void warmUp() {}
  @override
  void play(RunnerSfx sfx) {}
  @override
  void startMusic() => log.add('start');
  @override
  void stopMusic() => log.add('stop');
  @override
  void useTune(Uint8List? tune) {
    tunes.add(tune);
    log.add('tune ${tune?.length}');
  }

  @override
  void pauseMusic() => log.add('pause');
  @override
  void resumeMusic() => log.add('resume');
  @override
  void dispose() => _enabled.dispose();
}

/// Logs the calls on the music player; any other call throws.
class _Player extends Fake implements AudioPlayer {
  _Player(this.log);
  final List<String> log;
  @override
  PlayerState state = PlayerState.stopped;
  @override
  set positionUpdater(PositionUpdater? updater) {}
  @override
  Future<void> setPlayerMode(PlayerMode mode) async {}
  @override
  Future<void> setReleaseMode(ReleaseMode mode) async =>
      log.add('release ${mode.name}');
  @override
  Future<void> setSource(Source source) async => log.add(switch (source) {
    AssetSource(:final path) => 'asset $path',
    BytesSource(:final bytes, :final mimeType) =>
      'bytes ${bytes.length} $mimeType',
    _ => 'source $source',
  });
  @override
  Future<void> setVolume(double volume) async =>
      log.add('volume ${volume.toStringAsFixed(3)}');
  @override
  Future<Duration?> getDuration() async => const Duration(milliseconds: 400);
  @override
  Future<void> setAudioContext(AudioContext ctx) async => log.add(
    'context ${ctx.android.audioFocus.name} ${ctx.android.usageType.name}',
  );
  @override
  Future<void> resume() async {
    state = PlayerState.playing;
    log.add('resume');
  }

  @override
  Future<void> pause() async {
    state = PlayerState.paused;
    log.add('pause');
  }

  @override
  Future<void> stop() async {
    state = PlayerState.stopped;
    log.add('stop');
  }

  @override
  Future<void> dispose() async {}
}

/// A plugin sound on [log]; [others] tells whether another app plays music.
PluginRunnerSound _plugin(List<String> log, {bool Function()? others}) =>
    PluginRunnerSound(
      newPlayer: () => _Player(log),
      othersPlaying: () async => others?.call() ?? false,
    );

/// Logs the Web Audio calls; a clip is named by its bytes' length.
class _WebAudio implements WebAudio {
  final log = <String>[];

  /// Lengths of sounds the browser cannot decode.
  final broken = <int>{};
  @override
  void resume() => log.add('resume');
  @override
  void suspend() => log.add('suspend');
  @override
  Future<WebAudioClip> decode(Uint8List bytes, double volume) async {
    if (broken.contains(bytes.length)) throw StateError('no decoder');
    return _Clip(this, bytes.length);
  }

  @override
  void close() => log.add('close');
}

class _Clip implements WebAudioClip {
  _Clip(this.audio, this.length);
  final _WebAudio audio;
  final int length;
  @override
  WebAudioVoice play({bool loop = false, Duration fadeIn = Duration.zero}) {
    // Only the music is followed here.
    if (loop) audio.log.add('play $length fadeIn ${fadeIn.inMilliseconds}');
    return _Voice(audio, length, loop);
  }
}

class _Voice implements WebAudioVoice {
  _Voice(this.audio, this.length, this.loop);
  final _WebAudio audio;
  final int length;
  final bool loop;
  @override
  void stop({Duration fadeOut = Duration.zero}) {
    if (loop) audio.log.add('stop $length fadeOut ${fadeOut.inMilliseconds}');
  }
}

/// The length of the game's own tune in the asset bundle.
Future<int> _ownTuneLength() async => (await rootBundle.load(
  'assets/games/stage_runner/music.mp3',
)).lengthInBytes;

Future<AppController> _signedIn(
  Future<http.Response>? Function(http.Request) handle,
) async {
  final server = TestServer();
  server.data['capabilities'] = {
    'features': ['stageRunner', 'runnerUnlocks'],
  };
  server.override = handle;
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(RunnerTunes.clear);

  group('catalog', () {
    test('a backdrop names its music; a role keeps it', () {
      final w = Wardrobe.fromJson(_wardrobeJson());
      final backdrop = w.worn(WardrobeKind.backdrop)!;
      expect(backdrop.music, _music);
      expect(backdrop.inRole(null).music, _music);
      expect(w.catalog.item('b0')!.music, isNull);
      expect(RunnerTunes.of(w), _music);
      // The default backdrop without music, and no wardrobe: the game's own tune.
      expect(
        RunnerTunes.of(Wardrobe.fromJson(_wardrobeJson(backdrop: 'b0'))),
        isNull,
      );
      expect(RunnerTunes.of(null), isNull);
      // Older servers send no music, an empty one counts as none.
      final json = _wardrobeJson();
      ((json['catalog'] as JsonMap)['items'] as List).last = _item(
        'b1',
        'backdrop',
        extra: {'music': ''},
      );
      expect(Wardrobe.fromJson(json).catalog.item('b1')!.music, isNull);
    });

    test('M4A and MP3 are told apart by their first bytes', () {
      expect(musicMimeType(_m4a), 'audio/mp4');
      expect(musicMimeType(_mp3), 'audio/mpeg');
      expect(musicMimeType(Uint8List(0)), 'audio/mpeg');
    });
  });

  group('screen', () {
    testWidgets(
      'the worn backdrop\'s music is loaded once and handed to the sound; '
      'it holds in the background',
      (tester) async {
        var loads = 0;
        final controller = await _signedIn((request) {
          final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
          if (path.endsWith('/leaderboard')) {
            return Future.value(
              jsonResponse({'players': 0, 'top': [], 'own': null}),
            );
          }
          if (path.endsWith('/wardrobe')) {
            return Future.value(jsonResponse(_wardrobeJson()));
          }
          if (path.endsWith('/games/runner/skins/music-gruft.m4a')) {
            loads++;
            return Future.value(
              http.Response.bytes(
                _m4a,
                200,
                headers: {'content-type': 'audio/mp4'},
              ),
            );
          }
          return null;
        });
        final sound = _MusicSound();
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: StageRunnerScreen(controller: controller, sound: sound),
          ),
        );
        // The music comes after the wardrobe, as its own request.
        for (var i = 0; i < 10 && sound.tunes.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(loads, 1);
        expect(sound.tunes.last, _m4a);
        expect(RunnerTunes.cached(_music), _m4a);

        sound.log.clear();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(sound.log, ['pause']);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(sound.log, ['pause', 'resume']);
        await tester.pumpWidget(const SizedBox());
        sound.dispose();
      },
    );
  });

  group('plugin', () {
    testWidgets('while another app plays music, the game keeps quiet', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final log = <String>[];
      var others = true;
      final sound = _plugin(log, others: () => others);
      await tester.pump();
      sound.startMusic();
      await tester.pump(musicFadeIn);
      expect(log, isNot(contains('resume')));
      sound.stopMusic();
      await tester.pump(musicFadeOut);

      // The next run, after the other music ended, has its music.
      others = false;
      sound.startMusic();
      await tester.pump(musicFadeIn);
      expect(log, contains('resume'));

      // Back from the background while the other app plays: still quiet.
      sound.pauseMusic();
      await tester.pump();
      others = true;
      log.clear();
      sound.resumeMusic();
      await tester.pump();
      expect(log, isNot(contains('resume')));
      sound.dispose();
    });

    testWidgets(
      'the music fades in, takes the backdrop\'s tune, pauses and fades out',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final log = <String>[];
        final sound = _plugin(log);
        await tester.pump();

        sound.useTune(_m4a);
        sound.startMusic();
        await tester.pump();
        // On Android without the audio focus: other apps' music goes on.
        expect(log, [
          'release loop',
          'context none game',
          'bytes ${_m4a.length} audio/mp4',
          'volume 0.000',
          'resume',
        ]);
        log.clear();
        await tester.pump(musicFadeIn);
        await tester.pump();
        final volumes = [for (final e in log) double.parse(e.split(' ').last)];
        expect(log.every((e) => e.startsWith('volume')), isTrue);
        expect(volumes, orderedEquals([...volumes]..sort()));
        expect(volumes.last, closeTo(.32, 1e-3));

        // In the background the music holds, and continues after.
        log.clear();
        sound.pauseMusic();
        await tester.pump();
        sound.resumeMusic();
        await tester.pump();
        expect(log, ['pause', 'volume 0.320', 'resume']);

        // The game's own tune again, at once.
        log.clear();
        sound.useTune(null);
        await tester.pump();
        expect(log, [
          'asset games/stage_runner/music.mp3',
          'volume 0.320',
          'resume',
        ]);

        log.clear();
        sound.stopMusic();
        await tester.pump(musicFadeOut);
        await tester.pump();
        expect(log.last, 'stop');
        expect(log.where((e) => e.startsWith('volume')).last, 'volume 0.000');
        sound.dispose();
      },
    );

    testWidgets('a new run during the fade-out keeps the music playing', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final log = <String>[];
      final sound = _plugin(log);
      await tester.pump();
      sound.startMusic();
      await tester.pump(musicFadeIn);
      sound.stopMusic();
      await tester.pump(musicFadeOut ~/ 2);
      log.clear();
      sound.startMusic();
      await tester.pump(musicFadeOut + musicFadeIn);
      expect(log, isNot(contains('stop')));
      expect(log.last, 'volume 0.320');
      sound.dispose();
    });

    testWidgets(
      'muted, nothing plays; stopped before its turn, nothing starts',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final log = <String>[];
        final sound = _plugin(log);
        await tester.pump();
        sound
          ..startMusic()
          ..stopMusic();
        await tester.pump(musicFadeIn);
        expect(log, isNot(contains('resume')));
        sound.setEnabled(false);
        sound.useTune(_m4a);
        sound.startMusic();
        await tester.pump(musicFadeIn);
        expect(log, isNot(contains('resume')));
        sound.dispose();
      },
    );
  });

  group('browser', () {
    test('the backdrop\'s tune is decoded in place of the game\'s own and '
        'fades in; a new one takes over with a fade', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final audio = _WebAudio();
      final sound = WebRunnerSound(open: () => audio);
      await pumpEventQueue();

      sound
        ..useTune(_m4a)
        ..prepare()
        ..startMusic();
      await pumpEventQueue();
      expect(audio.log, [
        'resume',
        'play ${_m4a.length} fadeIn ${musicFadeIn.inMilliseconds}',
      ]);

      // Changed in the wardrobe: the new tune takes over.
      audio.log.clear();
      sound.useTune(_mp3);
      await pumpEventQueue();
      expect(audio.log, [
        'stop ${_m4a.length} fadeOut ${musicFadeOut.inMilliseconds}',
        'play ${_mp3.length} fadeIn ${musicFadeIn.inMilliseconds}',
      ]);

      // In the background the whole context holds.
      audio.log.clear();
      sound
        ..pauseMusic()
        ..resumeMusic();
      expect(audio.log, ['suspend', 'resume']);

      audio.log.clear();
      sound.stopMusic();
      expect(audio.log, [
        'stop ${_mp3.length} fadeOut ${musicFadeOut.inMilliseconds}',
      ]);
      sound.dispose();
    });

    test('a tune the browser cannot decode leaves the game\'s own', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final audio = _WebAudio()..broken.add(_m4a.length);
      final own = await _ownTuneLength();
      final sound = WebRunnerSound(open: () => audio);
      await pumpEventQueue();
      sound
        ..useTune(_m4a)
        ..prepare()
        ..startMusic();
      await pumpEventQueue();
      expect(audio.log, [
        'resume',
        'play $own fadeIn ${musicFadeIn.inMilliseconds}',
      ]);

      // A late decode of an older tune never replaces a newer one.
      audio.log.clear();
      sound
        ..useTune(_mp3)
        ..useTune(null);
      await pumpEventQueue();
      expect(audio.log, isEmpty, reason: 'the own tune plays already');
      sound.dispose();
    });
  });
}
