import 'dart:async';

import 'package:audio_session/audio_session.dart'
    show AVAudioSession, AndroidAudioManager;
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

/// The music of the worn backdrop: what a [RunnerSound] of the platform
/// plays besides the game's own tune. Kept apart from [RunnerSound], whose
/// stand-ins in tests then need none of it.
abstract interface class RunnerMusic {
  /// The tune to loop from the next [RunnerSound.startMusic] on (AAC in M4A
  /// or MP3); null for the game's own. A tune that does not play leaves the
  /// game's own in its place. Changed during a run, it takes over at once.
  void useTune(Uint8List? tune);

  /// Holds the music where it is while the app is in the background, and
  /// continues it after.
  void pauseMusic();
  void resumeMusic();
}

/// The music rises from silence when a run starts and fades out when it
/// ends.
@visibleForTesting
const musicFadeIn = Duration(milliseconds: 1200);
@visibleForTesting
const musicFadeOut = Duration(milliseconds: 800);

/// `audio/mp4` for AAC in M4A (an MP4 file starts with its `ftyp` box),
/// else `audio/mpeg`.
@visibleForTesting
String musicMimeType(Uint8List bytes) =>
    bytes.length > 8 && String.fromCharCodes(bytes, 4, 8) == 'ftyp'
    ? 'audio/mp4'
    : 'audio/mpeg';

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
class PluginRunnerSound
    with _RememberedSwitch
    implements RunnerSound, RunnerMusic {
  PluginRunnerSound({
    @visibleForTesting AudioPlayer Function()? newPlayer,
    @visibleForTesting Future<bool> Function()? othersPlaying,
    @visibleForTesting Future<void> Function(AudioContext)? setAudioContext,
  }) : _newPlayer = newPlayer ?? AudioPlayer.new,
       _othersPlaying = othersPlaying ?? _otherMusicPlays,
       // Stand-in players in tests: then no platform call either.
       _setAudioContext =
           setAudioContext ??
           (newPlayer == null
               ? (ctx) => AudioPlayer.global.setAudioContext(ctx)
               : (_) async {}) {
    _restore();
  }

  final AudioPlayer Function() _newPlayer;

  /// Sets the plugin's global audio context, which every player created
  /// after it takes.
  final Future<void> Function(AudioContext) _setAudioContext;

  /// Whether [effectsAudioContext] is set (or queued to be).
  bool _contextQueued = false;

  /// How the game sounds next to other apps: it never pauses their music.
  ///
  /// The plugin's defaults take Android's audio focus (`AUDIOFOCUS_GAIN`,
  /// at every play) and iOS's `playback` category without mixing; either
  /// way Spotify & Co. stop at the first effect. So:
  /// - Android: no audio focus at all; the effects are a game's
  ///   sonification. (A player without focus also does not pause when
  ///   another app takes it.)
  /// - iOS: `ambient`, which mixes with other apps and keeps quiet with the
  ///   ring/silent switch on silent.
  ///
  /// Set globally before the first player is created, so every player
  /// (also the music's) starts from it; on iOS there is only the one
  /// session anyway.
  @visibleForTesting
  static final effectsAudioContext = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.game,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
  );

  /// Whether another app plays music (Spotify, a podcast) right now.
  final Future<bool> Function() _othersPlaying;

  /// How long after an effect's start Android may still count it as music
  /// playing: the longest effect (the jackpot) lasts 1.6 s.
  @visibleForTesting
  static const ownSoundTail = Duration(milliseconds: 2500);

  /// Runs while an effect of the game may still sound.
  Timer? _ownSound;

  /// The last answer of [_othersPlaying] that the game's own effects did not
  /// spoil.
  bool _othersLast = false;

  void _heardOwnSound() {
    _ownSound?.cancel();
    if (_disposed) return;
    _ownSound = Timer(ownSoundTail, () => _ownSound = null);
  }

  /// [_othersPlaying], but Android's `isMusicActive` also hears the game's
  /// own effects (the crash or the curtain of the last run, the crate's
  /// reel): while one may still sound, the answer from before stands. iOS's
  /// hint only counts other apps.
  Future<bool> _othersPlayingNow() async {
    if (_ownSound != null && defaultTargetPlatform == TargetPlatform.android) {
      return _othersLast;
    }
    return _othersLast = await _othersPlaying();
  }

  /// Asks the system: Android's `AudioManager.isMusicActive`, iOS's
  /// `secondaryAudioShouldBeSilencedHint`. Unknown counts as no. (Android
  /// also counts the game's own effects; one that still sounds when a run
  /// starts may keep that run quiet.)
  static Future<bool> _otherMusicPlays() async {
    try {
      return switch (defaultTargetPlatform) {
        TargetPlatform.android => await AndroidAudioManager().isMusicActive(),
        TargetPlatform.iOS =>
          await AVAudioSession().secondaryAudioShouldBeSilencedHint,
        _ => false,
      };
    } catch (e) {
      _silent(e);
      return false;
    }
  }
  final Map<RunnerSfx, AudioPlayer> _players = {};
  final Set<RunnerSfx> _loaded = {};

  /// Length of the loaded effect, only where it is ended early.
  final Map<RunnerSfx, Duration> _lengths = {};

  /// Counts the plays per effect, so an early end only stops its own play.
  final Map<RunnerSfx, int> _plays = {};
  final Map<RunnerSfx, Timer> _ends = {};
  AudioPlayer? _musicPlayer;
  bool _musicWanted = false;

  /// The worn tune ([useTune]) and the one the music player has loaded.
  Uint8List? _tune, _loadedTune;
  bool _musicLoaded = false;

  /// The share of the music's volume, which a fade moves in steps: the
  /// plugin has no fades of its own.
  double _musicLevel = 0;
  Timer? _fade;

  /// Paused with the app in the background.
  bool _hidden = false;

  /// Plays run one after another, so a quick series never races.
  Future<void> _queue = Future.value();

  @override
  void setEnabled(bool on) {
    _remember(on);
    if (on) {
      prepare();
      if (_musicWanted && !_hidden) _run(_resumeMusic);
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
    // Once, ahead of the first task with the sound on: only those create
    // players. A muted game makes no platform call.
    if (_enabled.value && !_contextQueued) {
      _contextQueued = true;
      _queue = _queue
          .then((_) => _disposed ? null : _setAudioContext(effectsAudioContext))
          .catchError((Object e) => _silent(e));
    }
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
      _heardOwnSound();
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
    // Stopped again before its turn came.
    if (!_musicWanted) return;
    // Another app's music goes on alone; the game's own never stops it.
    if (_musicPlayer?.state != PlayerState.playing &&
        await _othersPlayingNow()) {
      return;
    }
    var player = _musicPlayer;
    if (player == null) {
      player = _musicPlayer = _create();
      await player.setReleaseMode(ReleaseMode.loop);
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Without the audio focus, so no other app pauses for the music.
        await player.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              usageType: AndroidUsageType.game,
              audioFocus: AndroidAudioFocus.none,
            ),
          ),
        );
      }
    }
    // First, or the worn tune changed (then it takes over at once).
    if (!_musicLoaded || !identical(_loadedTune, _tune)) {
      await _loadMusic(player);
    }
    await player.setVolume(_musicVolume * _musicLevel);
    await player.resume();
  }

  Future<void> _loadMusic(AudioPlayer player) async {
    final tune = _loadedTune = _tune;
    _musicLoaded = true;
    if (tune != null) {
      try {
        await player.setSource(
          BytesSource(tune, mimeType: musicMimeType(tune)),
        );
        return;
      } catch (e) {
        _silent(e);
      }
    }
    await player.setSource(AssetSource(_music));
  }

  /// Moves the music's volume to [to] (a share of its full volume) in small
  /// steps over [over], then runs [then]. A new fade replaces the last one.
  void _fadeMusic(double to, Duration over, {Future<void> Function()? then}) {
    _fade?.cancel();
    const steps = 12;
    final from = _musicLevel;
    var step = 0;
    _fade = Timer.periodic(over ~/ steps, (timer) {
      step++;
      final level = _musicLevel = from + (to - from) * step / steps;
      _run(() async => _musicPlayer?.setVolume(_musicVolume * level));
      if (step < steps) return;
      timer.cancel();
      _fade = null;
      if (then != null) _run(then);
    });
  }

  @override
  void startMusic() {
    _musicWanted = true;
    if (!_enabled.value || _hidden) return;
    _musicLevel = 0;
    _run(_resumeMusic);
    _fadeMusic(1, musicFadeIn);
  }

  @override
  void stopMusic() {
    _musicWanted = false;
    Future<void> stop() async {
      // A new run may have started the music again meanwhile.
      if (!_musicWanted) await _musicPlayer?.stop();
    }

    if (_enabled.value && !_hidden && _musicPlayer != null) {
      _fadeMusic(0, musicFadeOut, then: stop);
    } else {
      _fade?.cancel();
      _run(stop);
    }
  }

  @override
  void useTune(Uint8List? tune) {
    if (identical(tune, _tune)) return;
    _tune = tune;
    if (_musicWanted && _enabled.value && !_hidden && _musicPlayer != null) {
      _run(_resumeMusic);
    }
  }

  @override
  void pauseMusic() {
    _hidden = true;
    _run(() async => _musicPlayer?.pause());
  }

  @override
  void resumeMusic() {
    if (!_hidden) return;
    _hidden = false;
    if (_musicWanted && _enabled.value) _run(_resumeMusic);
  }

  @override
  void dispose() {
    _disposed = true;
    _fade?.cancel();
    _ownSound?.cancel();
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
  /// Starts the sound from its beginning; with [loop] it never ends. With
  /// [fadeIn] it rises from silence.
  WebAudioVoice play({bool loop = false, Duration fadeIn = Duration.zero});
}

/// One playing of a [WebAudioClip].
abstract class WebAudioVoice {
  /// Ends the playing; with [fadeOut] (only for loops) after fading it to
  /// silence.
  void stop({Duration fadeOut = Duration.zero});
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
class WebRunnerSound
    with _RememberedSwitch
    implements RunnerSound, RunnerMusic {
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

  /// The worn tune ([useTune]); the game's own tune stays decoded for when
  /// no backdrop brings one.
  Uint8List? _tune;
  WebAudioClip? _ownTune;

  /// Counts the tunes asked for, so a late decode of an older one is
  /// dropped.
  int _tunes = 0;

  /// Paused with the app in the background.
  bool _hidden = false;

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
    _loadMusic(audio),
  ]);

  /// Decodes the worn tune, else the game's own, and plays it in place of
  /// the one before if the music is on.
  Future<void> _loadMusic(WebAudio audio) async {
    final asked = ++_tunes, tune = _tune;
    var clip = tune == null
        ? null
        : await _decodeBytes(audio, tune, _musicVolume);
    clip ??= _ownTune ??= await _decode(audio, _music, _musicVolume);
    if (asked != _tunes || _disposed || identical(clip, _musicClip)) return;
    _musicClip = clip;
    final before = _musicVoice;
    if (before != null) {
      _musicVoice = null;
      _safely(() => before.stop(fadeOut: musicFadeOut));
    }
    if (_musicWanted && _enabled.value) _startMusic();
  }

  /// The bytes come from Flutter's asset bundle, which knows the versioned
  /// asset path.
  Future<WebAudioClip?> _decode(
    WebAudio audio,
    String asset,
    double volume,
  ) async {
    try {
      final data = await rootBundle.load('assets/$asset');
      return await _decodeBytes(audio, Uint8List.sublistView(data), volume);
    } catch (e) {
      _silent(e);
      return null;
    }
  }

  Future<WebAudioClip?> _decodeBytes(
    WebAudio audio,
    Uint8List bytes,
    double volume,
  ) async {
    try {
      final clip = await audio.decode(bytes, volume);
      return _disposed ? null : clip;
    } catch (e) {
      // E.g. a browser without an AAC decoder.
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
    _safely(() => _musicVoice = clip.play(loop: true, fadeIn: musicFadeIn));
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
    if (voice != null) _safely(() => voice.stop(fadeOut: musicFadeOut));
  }

  @override
  void useTune(Uint8List? tune) {
    if (identical(tune, _tune)) return;
    _tune = tune;
    final audio = _audio;
    // Before the first [prepare] it is decoded with the other sounds.
    if (audio != null && _loading != null && !_disposed) {
      unawaited(_loadMusic(audio));
    }
  }

  @override
  void pauseMusic() {
    _hidden = true;
    final audio = _audio;
    if (audio != null) _safely(audio.suspend);
  }

  /// Back from the background. Safari lets a context continue that a tap
  /// once started; otherwise the next "Vorhang auf" starts it.
  @override
  void resumeMusic() {
    if (!_hidden) return;
    _hidden = false;
    final audio = _audio;
    if (audio != null && _enabled.value) _safely(audio.resume);
  }

  @override
  void dispose() {
    _disposed = true;
    final audio = _audio;
    _audio = null;
    _clips.clear();
    _voices.clear();
    _musicClip = null;
    _ownTune = null;
    _musicVoice = null;
    // Closing the context ends everything that still sounds.
    if (audio != null) _safely(audio.close);
    _enabled.dispose();
  }
}
