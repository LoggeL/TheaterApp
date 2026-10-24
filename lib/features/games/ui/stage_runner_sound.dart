import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stage_runner_web_audio_stub.dart'
    if (dart.library.js_interop) 'stage_runner_web_audio.dart'
    as platform;

/// The short effects of "Bühnenlauf", all synthesized for the game.
enum RunnerSfx {
  /// The flying wire pulls (when holding starts).
  whoosh(.3),
  rose(.7),
  mask(.7),
  star(.8),

  /// Boing, plump and cymbal.
  crash(.9),
  curtain(.6),

  /// Fanfare for a new personal best.
  record(.8),

  /// Applause at a milestone.
  bravo(.6),

  /// A card of the crate reel passes the marker.
  tick(.45),

  /// The crate reel stops on its card.
  reveal(.7),

  /// The crate held a gold item.
  jackpot(.85);

  const RunnerSfx(this.volume);
  final double volume;

  String get asset => 'games/stage_runner/$name.mp3';
}

const _music = 'games/stage_runner/music.mp3';
const _musicVolume = .32;

/// Sound of the game: effects, a quiet looping tune and the mute switch.
abstract class RunnerSound {
  /// The sound of this platform: the Web Audio API in browsers, the
  /// `audioplayers` plugin elsewhere.
  factory RunnerSound() => kIsWeb ? WebRunnerSound() : PluginRunnerSound();

  /// Whether sound is on; remembered on this device.
  ValueListenable<bool> get enabled;
  void setEnabled(bool on);

  /// Gets the sounds ready; called from the tap that starts a run, so web
  /// browsers allow playing them.
  void prepare();
  void play(RunnerSfx sfx);
  void startMusic();
  void stopMusic();
  void dispose();
}

void _silent(Object e) {
  if (kDebugMode) debugPrint('Bühnenlauf: Ton nicht verfügbar: $e');
}

/// The mute switch, remembered on this device.
mixin _RememberedSwitch {
  static const _key = 'stageRunner.sound';
  final _enabled = ValueNotifier(true);
  bool _disposed = false;

  ValueListenable<bool> get enabled => _enabled;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = prefs.getBool(_key);
      if (on != null && !_disposed) _enabled.value = on;
    } catch (_) {}
  }

  void _remember(bool on) {
    _enabled.value = on;
    unawaited(
      SharedPreferences.getInstance()
          .then((p) => p.setBool(_key, on))
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }
}

/// [RunnerSound] with the `audioplayers` plugin, for the native platforms.
/// Nothing is loaded before the game starts a run, and every failure only
/// means silence.
///
/// Every effect has its own player, so a run never loads a sound (on iOS a
/// new AVPlayerItem on the UI thread) while it is played.
class PluginRunnerSound with _RememberedSwitch implements RunnerSound {
  PluginRunnerSound({@visibleForTesting AudioPlayer Function()? newPlayer})
    : _newPlayer = newPlayer ?? AudioPlayer.new {
    _restore();
  }

  final AudioPlayer Function() _newPlayer;
  final Map<RunnerSfx, AudioPlayer> _players = {};
  final Set<RunnerSfx> _loaded = {};

  /// Length of the loaded effect, only where it is ended early.
  final Map<RunnerSfx, Duration> _lengths = {};

  /// Counts the plays per effect, so an early end only stops its own play.
  final Map<RunnerSfx, int> _plays = {};
  final Map<RunnerSfx, Timer> _ends = {};
  AudioPlayer? _musicPlayer;
  bool _musicWanted = false;

  /// Plays run one after another, so a quick series never races.
  Future<void> _queue = Future.value();

  @override
  void setEnabled(bool on) {
    _remember(on);
    if (on) {
      prepare();
      if (_musicWanted) _run(_resumeMusic);
    } else {
      _run(() async {
        await _musicPlayer?.pause();
        for (final p in _players.values) {
          await p.stop();
        }
      });
    }
  }

  void _run(Future<void> Function() task) {
    _queue = _queue
        .then((_) => _disposed ? null : task())
        .catchError((Object e) => _silent(e));
  }

  /// On iOS and macOS, an effect that plays to its natural end costs the main
  /// thread (since Flutter 3.29 also the Dart UI thread) a synchronous
  /// `AVAudioSession.setActive` call: audioplayers_darwin's completion
  /// handler runs it with an onComplete event and a seek. So every effect is
  /// stopped (paused and rewound) a little before its end. All effects end in
  /// at least 40 ms of silence, so nothing audible is cut.
  static bool get _endsEarly =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// How long before its end an effect is stopped.
  @visibleForTesting
  static const earlyEnd = Duration(milliseconds: 35);

  /// A new player without the position polling: by default every playing
  /// player asks the platform for its position once per frame, and the game
  /// never needs it.
  AudioPlayer _create() => _newPlayer()..positionUpdater = null;

  Future<AudioPlayer> _player(RunnerSfx sfx) async {
    final existing = _players[sfx];
    if (existing != null) return existing;
    final player = _players[sfx] = _create();
    // Android's SoundPool starts short effects without delay.
    await player.setPlayerMode(PlayerMode.lowLatency);
    await player.setReleaseMode(ReleaseMode.stop);
    return player;
  }

  @override
  void prepare() {
    if (!_enabled.value) return;
    _run(() async {
      // Each effect is loaded once, so the first play starts at once.
      for (final sfx in RunnerSfx.values) {
        if (_loaded.contains(sfx)) continue;
        await _load(await _player(sfx), sfx);
      }
    });
  }

  Future<void> _load(AudioPlayer player, RunnerSfx sfx) async {
    await player.setSource(AssetSource(sfx.asset));
    await player.setVolume(sfx.volume);
    _loaded.add(sfx);
    if (_endsEarly) {
      final length = await player.getDuration();
      if (length != null) _lengths[sfx] = length;
    }
  }

  @override
  void play(RunnerSfx sfx) {
    if (!_enabled.value) return;
    _run(() async {
      final player = await _player(sfx);
      final count = _plays[sfx] = (_plays[sfx] ?? 0) + 1;
      _ends.remove(sfx)?.cancel();
      if (!_loaded.contains(sfx)) {
        // Before [prepare].
        await _load(player, sfx);
      } else if (player.state == PlayerState.playing) {
        // Still sounding: start it over, as before.
        await player.stop();
      }
      await player.resume();
      final length = _lengths[sfx];
      if (length == null || length <= earlyEnd || _disposed) return;
      _ends[sfx] = Timer(length - earlyEnd, () {
        _ends.remove(sfx);
        _run(() async {
          // A later play of the same effect has its own end.
          if (_plays[sfx] == count && player.state == PlayerState.playing) {
            await player.stop();
          }
        });
      });
    });
  }

  Future<void> _resumeMusic() async {
    var player = _musicPlayer;
    if (player == null) {
      player = _musicPlayer = _create();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setSource(AssetSource(_music));
      await player.setVolume(_musicVolume);
    }
    await player.resume();
  }

  @override
  void startMusic() {
    _musicWanted = true;
    if (_enabled.value) _run(_resumeMusic);
  }

  @override
  void stopMusic() {
    _musicWanted = false;
    _run(() async {
      await _musicPlayer?.stop();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _ends.values) {
      t.cancel();
    }
    _ends.clear();
    final players = [..._players.values, ?_musicPlayer];
    _players.clear();
    _musicPlayer = null;
    for (final p in players) {
      unawaited(p.dispose().catchError((Object _) {}));
    }
    _enabled.dispose();
  }
}

/// The few calls of the Web Audio API that [WebRunnerSound] makes.
abstract class WebAudio {
  /// Starts the output, or continues it after [suspend]. Safari starts it
  /// only within a user gesture.
  void resume();

  /// Holds everything that sounds where it is.
  void suspend();

  /// Decodes a compressed sound, to be played at [volume].
  Future<WebAudioClip> decode(Uint8List bytes, double volume);
  void close();
}

/// A decoded sound.
abstract class WebAudioClip {
  /// Starts the sound from its beginning; with [loop] it never ends.
  WebAudioVoice play({bool loop = false});
}

/// One playing of a [WebAudioClip].
abstract class WebAudioVoice {
  void stop();
}

/// [RunnerSound] for browsers, on the Web Audio API: one audio context for
/// all sounds. Each sound is fetched and decoded once, from the tap that
/// starts a run; a play then only starts a buffer source on the decoded
/// sound. That needs no media element, loads nothing and sends no events
/// back, so a pickup costs the browser's single thread next to nothing.
///
/// (audioplayers_web gives every player its own audio context and media
/// element, sets the element's source anew as a data URI whenever a player
/// changes its sound, and seeks and restarts the element for every play.)
class WebRunnerSound with _RememberedSwitch implements RunnerSound {
  WebRunnerSound({@visibleForTesting WebAudio Function()? open})
    : _open = open ?? platform.openWebAudio {
    _restore();
  }

  final WebAudio Function() _open;
  WebAudio? _audio;
  Future<void>? _loading;
  final Map<RunnerSfx, WebAudioClip> _clips = {};

  /// The last play of each effect, so a new one starts it over.
  final Map<RunnerSfx, WebAudioVoice> _voices = {};
  WebAudioClip? _musicClip;
  WebAudioVoice? _musicVoice;
  bool _musicWanted = false;

  void _safely(void Function() call) {
    try {
      call();
    } catch (e) {
      _silent(e);
    }
  }

  @override
  void setEnabled(bool on) {
    _remember(on);
    if (on) {
      prepare();
      if (_musicWanted) _startMusic();
    } else {
      _safely(() {
        for (final voice in _voices.values) {
          voice.stop();
        }
        _voices.clear();
        // The music waits where it is.
        _audio?.suspend();
      });
    }
  }

  @override
  void prepare() {
    if (!_enabled.value || _disposed) return;
    _safely(() {
      final audio = _audio ??= _open();
      // Still within the tap: Safari only starts audio in a user gesture.
      audio.resume();
      _loading ??= _load(audio);
    });
  }

  /// Fetches and decodes all sounds side by side; one that fails stays
  /// silent.
  Future<void> _load(WebAudio audio) => Future.wait([
    for (final sfx in RunnerSfx.values)
      _decode(audio, sfx.asset, sfx.volume).then((clip) {
        if (clip != null) _clips[sfx] = clip;
      }),
    _decode(audio, _music, _musicVolume).then((clip) {
      _musicClip = clip;
      if (_musicWanted && _enabled.value) _startMusic();
    }),
  ]);

  /// The bytes come from Flutter's asset bundle, which knows the versioned
  /// asset path.
  Future<WebAudioClip?> _decode(
    WebAudio audio,
    String asset,
    double volume,
  ) async {
    try {
      final data = await rootBundle.load('assets/$asset');
      final clip = await audio.decode(Uint8List.sublistView(data), volume);
      return _disposed ? null : clip;
    } catch (e) {
      _silent(e);
      return null;
    }
  }

  @override
  void play(RunnerSfx sfx) {
    if (!_enabled.value || _disposed) return;
    // Not decoded (yet): silence rather than loading during a run.
    final clip = _clips[sfx];
    if (clip == null) return;
    _safely(() {
      // Still sounding: start it over, as on the other platforms.
      _voices.remove(sfx)?.stop();
      _voices[sfx] = clip.play();
    });
  }

  void _startMusic() {
    final clip = _musicClip;
    if (clip == null || _musicVoice != null || _disposed) return;
    _safely(() => _musicVoice = clip.play(loop: true));
  }

  @override
  void startMusic() {
    _musicWanted = true;
    if (_enabled.value) _startMusic();
  }

  @override
  void stopMusic() {
    _musicWanted = false;
    final voice = _musicVoice;
    _musicVoice = null;
    if (voice != null) _safely(voice.stop);
  }

  @override
  void dispose() {
    _disposed = true;
    final audio = _audio;
    _audio = null;
    _clips.clear();
    _voices.clear();
    _musicClip = null;
    _musicVoice = null;
    // Closing the context ends everything that still sounds.
    if (audio != null) _safely(audio.close);
    _enabled.dispose();
  }
}
