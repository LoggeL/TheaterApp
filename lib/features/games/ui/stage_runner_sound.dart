import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The short effects of "Bühnenlauf", all synthesized for the game.
enum RunnerSfx {
  /// The flying wire pulls (when holding starts).
  whoosh(_Channel.wire, .3),
  rose(_Channel.pickup, .7),
  mask(_Channel.pickup, .7),
  star(_Channel.pickup, .8),

  /// Boing, plump and cymbal.
  crash(_Channel.crash, .9),
  curtain(_Channel.stinger, .6),

  /// Fanfare for a new personal best.
  record(_Channel.stinger, .8),

  /// Applause at a milestone.
  bravo(_Channel.stinger, .6);

  const RunnerSfx(this._channel, this.volume);
  final _Channel _channel;
  final double volume;

  String get asset => 'games/stage_runner/$name.mp3';
}

/// On the web, few players, shared by effects that never overlap: browsers
/// give every player its own audio context and Safari allows only a few of
/// them. Elsewhere every effect has its own player, so a run never loads a
/// sound (on iOS a new AVPlayerItem on the UI thread) while it is played.
enum _Channel { wire, pickup, crash, stinger }

const _music = 'games/stage_runner/music.mp3';

/// Sound of the game: effects, a quiet looping tune and the mute switch.
abstract class RunnerSound {
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

/// [RunnerSound] with the `audioplayers` plugin. Nothing is loaded before the
/// game starts a run, and every failure only means silence.
class PluginRunnerSound implements RunnerSound {
  PluginRunnerSound({@visibleForTesting AudioPlayer Function()? newPlayer})
    : _newPlayer = newPlayer ?? AudioPlayer.new {
    _restore();
  }

  static const _key = 'stageRunner.sound';
  final AudioPlayer Function() _newPlayer;
  final _enabled = ValueNotifier(true);

  /// Keyed by [_slot]: a channel on the web, the effect itself elsewhere.
  final Map<Object, AudioPlayer> _players = {};
  final Map<Object, RunnerSfx> _loaded = {};
  final Map<String, Uint8List> _bytes = {};

  /// Length of the loaded effect, only where it is ended early.
  final Map<Object, Duration> _lengths = {};

  /// Counts the plays per slot, so an early end only stops its own play.
  final Map<Object, int> _plays = {};
  final Map<Object, Timer> _ends = {};
  AudioPlayer? _musicPlayer;
  bool _musicWanted = false, _disposed = false;

  /// Plays run one after another, so a quick series never races.
  Future<void> _queue = Future.value();

  @override
  ValueListenable<bool> get enabled => _enabled;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = prefs.getBool(_key);
      if (on != null && !_disposed) _enabled.value = on;
    } catch (_) {}
  }

  @override
  void setEnabled(bool on) {
    _enabled.value = on;
    unawaited(
      SharedPreferences.getInstance()
          .then((p) => p.setBool(_key, on))
          .then<void>((_) {}, onError: (Object _) {}),
    );
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
    _queue = _queue.then((_) => _disposed ? null : task()).catchError((
      Object e,
    ) {
      if (kDebugMode) debugPrint('Bühnenlauf: Ton nicht verfügbar: $e');
    });
  }

  /// On the web the bytes come from Flutter's asset bundle (which knows the
  /// versioned asset path); elsewhere the plugin reads the asset itself.
  Future<Source> _source(String asset) async {
    if (!kIsWeb) return AssetSource(asset);
    final bytes = _bytes[asset] ??= (await rootBundle.load(
      'assets/$asset',
    )).buffer.asUint8List();
    return BytesSource(bytes, mimeType: 'audio/mpeg');
  }

  static Object _slot(RunnerSfx sfx) => kIsWeb ? sfx._channel : sfx;

  /// On iOS and macOS, an effect that plays to its natural end costs the main
  /// thread (since Flutter 3.29 also the Dart UI thread) a synchronous
  /// `AVAudioSession.setActive` call: audioplayers_darwin's completion
  /// handler runs it with an onComplete event and a seek. So every effect is
  /// stopped (paused and rewound) a little before its end. All effects end in
  /// at least 40 ms of silence, so nothing audible is cut.
  static bool get _endsEarly =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// How long before its end an effect is stopped.
  @visibleForTesting
  static const earlyEnd = Duration(milliseconds: 35);

  /// A new player without the position polling: by default every playing
  /// player asks the platform for its position once per frame, and the game
  /// never needs it.
  AudioPlayer _create() => _newPlayer()..positionUpdater = null;

  Future<AudioPlayer> _player(Object slot) async {
    final existing = _players[slot];
    if (existing != null) return existing;
    final player = _players[slot] = _create();
    // Android's SoundPool starts short effects without delay.
    if (!kIsWeb) await player.setPlayerMode(PlayerMode.lowLatency);
    await player.setReleaseMode(ReleaseMode.stop);
    return player;
  }

  @override
  void prepare() {
    if (!_enabled.value) return;
    _run(() async {
      // Each player gets its (first) effect, so the first play starts at once.
      for (final sfx in RunnerSfx.values) {
        final slot = _slot(sfx);
        if (_loaded[slot] != null) continue;
        await _load(slot, await _player(slot), sfx);
      }
      if (kIsWeb) {
        for (final sfx in RunnerSfx.values) {
          await _source(sfx.asset);
        }
      }
    });
  }

  Future<void> _load(Object slot, AudioPlayer player, RunnerSfx sfx) async {
    _loaded.remove(slot);
    _lengths.remove(slot);
    await player.setSource(await _source(sfx.asset));
    await player.setVolume(sfx.volume);
    _loaded[slot] = sfx;
    if (_endsEarly) {
      final length = await player.getDuration();
      if (length != null && _loaded[slot] == sfx) _lengths[slot] = length;
    }
  }

  @override
  void play(RunnerSfx sfx) {
    if (!_enabled.value) return;
    _run(() async {
      final slot = _slot(sfx);
      final player = await _player(slot);
      final count = _plays[slot] = (_plays[slot] ?? 0) + 1;
      _ends.remove(slot)?.cancel();
      if (_loaded[slot] != sfx) {
        // On the web when the channel switches effects, or before [prepare].
        await _load(slot, player, sfx);
      } else if (player.state == PlayerState.playing) {
        // Still sounding: start it over, as before.
        await player.stop();
      }
      await player.resume();
      final length = _lengths[slot];
      if (length == null || length <= earlyEnd || _disposed) return;
      _ends[slot] = Timer(length - earlyEnd, () {
        _ends.remove(slot);
        _run(() async {
          // A later play of the same effect has its own end.
          if (_plays[slot] == count && player.state == PlayerState.playing) {
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
      await player.setSource(await _source(_music));
      await player.setVolume(.32);
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
