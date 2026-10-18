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

/// Few players, shared by effects that never overlap: browsers give every
/// player its own audio context and Safari allows only a few of them.
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
  PluginRunnerSound() {
    _restore();
  }

  static const _key = 'stageRunner.sound';
  final _enabled = ValueNotifier(true);
  final Map<_Channel, AudioPlayer> _players = {};
  final Map<_Channel, RunnerSfx> _loaded = {};
  final Map<String, Uint8List> _bytes = {};
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

  Future<AudioPlayer> _player(_Channel channel) async {
    final existing = _players[channel];
    if (existing != null) return existing;
    final player = _players[channel] = AudioPlayer();
    // Android's SoundPool starts short effects without delay.
    if (!kIsWeb) await player.setPlayerMode(PlayerMode.lowLatency);
    await player.setReleaseMode(ReleaseMode.stop);
    return player;
  }

  @override
  void prepare() {
    if (!_enabled.value) return;
    _run(() async {
      // Each player gets its first effect, so the first play starts at once.
      for (final channel in _Channel.values) {
        final player = await _player(channel);
        final first = RunnerSfx.values.firstWhere((s) => s._channel == channel);
        if (_loaded[channel] == null) {
          await player.setSource(await _source(first.asset));
          _loaded[channel] = first;
        }
      }
      if (kIsWeb) {
        for (final sfx in RunnerSfx.values) {
          await _source(sfx.asset);
        }
      }
    });
  }

  @override
  void play(RunnerSfx sfx) {
    if (!_enabled.value) return;
    _run(() async {
      final player = await _player(sfx._channel);
      if (_loaded[sfx._channel] != sfx) {
        await player.setSource(await _source(sfx.asset));
        _loaded[sfx._channel] = sfx;
      } else {
        await player.stop();
      }
      await player.setVolume(sfx.volume);
      await player.resume();
    });
  }

  Future<void> _resumeMusic() async {
    var player = _musicPlayer;
    if (player == null) {
      player = _musicPlayer = AudioPlayer();
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
    final players = [..._players.values, ?_musicPlayer];
    _players.clear();
    _musicPlayer = null;
    for (final p in players) {
      unawaited(p.dispose().catchError((Object _) {}));
    }
    _enabled.dispose();
  }
}
