import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'stage_runner_sound.dart';

/// One audio context of the browser for all sounds of the game.
/// Uses `balanced` latency to avoid iOS Safari's aggressive ~5ms `interactive`
/// CoreAudio interrupt cadence while keeping SFX crisp (<25ms).
WebAudio openWebAudio() {
  try {
    return _BrowserAudio(
      web.AudioContext(web.AudioContextOptions(latencyHint: 'balanced'.toJS)),
    );
  } catch (_) {
    return _BrowserAudio(web.AudioContext());
  }
}

/// How long a change of a channel's volume takes: a short ramp instead of a
/// jump, which would click while a slider moves.
const _volumeRamp = .03;

/// Maximum concurrent `decodeAudioData` jobs in flight so iOS Safari does not
/// stall early gameplay frames decoding 12 audio files at once.
const _maxConcurrentDecodes = 2;

/// Maximum simultaneous non-looping SFX voices active in the audio graph.
const _maxActiveSfxVoices = 6;

class _DecodeJob {
  _DecodeJob(this.bytes, this.volume, this.channel);
  final Uint8List bytes;
  final double volume;
  final WebAudioChannel channel;
  final completer = Completer<WebAudioClip>();
}

class _BrowserAudio implements WebAudio {
  _BrowserAudio(this._context) {
    _syncState();
    _stateListener = ((web.Event _) => _syncState()).toJS;
    _context.addEventListener('statechange', _stateListener);
    _visibilityListener = ((web.Event _) => _onVisibilityChange()).toJS;
    web.document.addEventListener('visibilitychange', _visibilityListener);
  }

  final web.AudioContext _context;
  late final JSFunction _stateListener;
  late final JSFunction _visibilityListener;
  bool _running = false;
  bool _closed = false;
  bool _unlocked = false;
  bool _explicitlySuspended = false;
  bool _hiddenSuspended = false;

  int _activeDecodes = 0;
  final _effectDecodeQueue = Queue<_DecodeJob>();
  final _musicDecodeQueue = Queue<_DecodeJob>();

  /// Currently playing non-looping SFX voices, oldest first, capped at
  /// [_maxActiveSfxVoices] so CoreAudio's mixer never spikes on rapid pickups.
  final _activeSfx = <_BrowserVoice>[];

  /// A gain per channel, between the sounds' own gains and the output: its
  /// volume applies to what sounds now and what plays later, without
  /// decoding again.
  late final Map<WebAudioChannel, web.GainNode> _channels = {
    for (final channel in WebAudioChannel.values)
      channel: _context.createGain()..connect(_context.destination),
  };

  void _syncState() {
    final state = _context.state;
    _running = state == 'running';
    if (_running) _unlocked = true;
    if (state == 'closed') _closed = true;
  }

  void _onVisibilityChange() {
    if (_closed) return;
    if (web.document.hidden) {
      if (_running) {
        _hiddenSuspended = true;
        _running = false;
        _context.suspend().toDart.ignore();
      }
    } else if (_hiddenSuspended && !_explicitlySuspended) {
      _hiddenSuspended = false;
      _context.resume().toDart.ignore();
    }
  }

  /// Zero-interop fast path once running: every touch in Bühnenlauf calls
  /// `resumeMusic()`, so skipping JS interop while already running avoids
  /// redundant WebKit bridge traffic on every tap.
  @override
  void resume() {
    _explicitlySuspended = false;
    _hiddenSuspended = false;
    if (_closed || _running) return;
    final state = _context.state;
    if (state == 'running') {
      _running = true;
      return;
    }
    if (state == 'closed') {
      _closed = true;
      return;
    }
    _context.resume().toDart.ignore();
    // On iOS Safari & standalone PWAs, starting a 1-sample silent buffer inside
    // a user gesture reliably unlocks CoreAudio output until the context runs.
    if (!_unlocked) {
      try {
        final silent = _context.createBuffer(1, 1, 22050);
        final source = _context.createBufferSource()
          ..buffer = silent
          ..connect(_context.destination);
        source.start(0);
      } catch (_) {}
    }
  }

  @override
  void suspend() {
    _explicitlySuspended = true;
    _hiddenSuspended = false;
    if (_closed) return;
    _running = false;
    _context.suspend().toDart.ignore();
  }

  @override
  Future<WebAudioClip> decode(
    Uint8List bytes,
    double volume,
    WebAudioChannel channel,
  ) {
    if (_closed) {
      return Future<WebAudioClip>.error(StateError('AudioContext closed'));
    }
    final job = _DecodeJob(bytes, volume, channel);
    if (_activeDecodes < _maxConcurrentDecodes) {
      _startDecode(job);
    } else if (channel == WebAudioChannel.effects) {
      _effectDecodeQueue.addLast(job);
    } else {
      _musicDecodeQueue.addLast(job);
    }
    return job.completer.future;
  }

  void _startDecode(_DecodeJob job) {
    _activeDecodes++;
    _runDecode(job).whenComplete(() {
      _activeDecodes--;
      _pumpDecodeQueue();
    });
  }

  Future<void> _runDecode(_DecodeJob job) async {
    try {
      if (_closed) {
        job.completer.completeError(StateError('AudioContext closed'));
        return;
      }
      // The browser takes over (detaches) the buffer it decodes, so hand it a
      // tightly-sized native copy (`sublist` maps to TypedArray.slice).
      final data = job.bytes.sublist(0).buffer.toJS;
      final buffer = await _context.decodeAudioData(data).toDart;
      if (_closed) {
        job.completer.completeError(StateError('AudioContext closed'));
        return;
      }
      final gain = _context.createGain()..gain.value = job.volume;
      gain.connect(_channels[job.channel]!);
      job.completer.complete(
        _BrowserClip(this, _context, buffer, gain, job.channel),
      );
    } catch (e, st) {
      if (!job.completer.isCompleted) {
        job.completer.completeError(e, st);
      }
    }
  }

  void _pumpDecodeQueue() {
    while (!_closed && _activeDecodes < _maxConcurrentDecodes) {
      final next = _effectDecodeQueue.isNotEmpty
          ? _effectDecodeQueue.removeFirst()
          : _musicDecodeQueue.isNotEmpty
          ? _musicDecodeQueue.removeFirst()
          : null;
      if (next == null) return;
      _startDecode(next);
    }
  }

  void _trackSfxVoice(_BrowserVoice voice, double now) {
    // Cheaply prune finished voices using the audio clock.
    var write = 0;
    for (var i = 0; i < _activeSfx.length; i++) {
      final existing = _activeSfx[i];
      if (!existing._stopped && now < existing._endTime) {
        _activeSfx[write++] = existing;
      }
    }
    if (write < _activeSfx.length) {
      _activeSfx.length = write;
    }
    while (_activeSfx.length >= _maxActiveSfxVoices) {
      _activeSfx.removeAt(0).stop();
    }
    _activeSfx.add(voice);
  }

  /// Ramps to [gain] from where the channel is now; a ramp to 0 ends in
  /// silence exactly.
  @override
  void setVolume(WebAudioChannel channel, double gain) {
    if (_closed) return;
    final param = _channels[channel]!.gain, now = _context.currentTime;
    param
      ..cancelScheduledValues(now)
      ..setValueAtTime(param.value, now)
      ..linearRampToValueAtTime(gain, now + _volumeRamp);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _running = false;
    _activeSfx.clear();
    final err = StateError('AudioContext closed');
    while (_effectDecodeQueue.isNotEmpty) {
      final job = _effectDecodeQueue.removeFirst();
      if (!job.completer.isCompleted) job.completer.completeError(err);
    }
    while (_musicDecodeQueue.isNotEmpty) {
      final job = _musicDecodeQueue.removeFirst();
      if (!job.completer.isCompleted) job.completer.completeError(err);
    }
    _context.removeEventListener('statechange', _stateListener);
    web.document.removeEventListener('visibilitychange', _visibilityListener);
    for (final channel in _channels.values) {
      try {
        channel.disconnect();
      } catch (_) {}
    }
    _context.close().toDart.ignore();
  }
}

class _BrowserClip implements WebAudioClip {
  _BrowserClip(
    this._owner,
    this._context,
    this._buffer,
    this._gain,
    this._channel,
  );
  final _BrowserAudio _owner;
  final web.AudioContext _context;
  final web.AudioBuffer _buffer;

  /// The sound's own volume, into its channel.
  final web.GainNode _gain;
  final WebAudioChannel _channel;

  /// A buffer source plays once and is cheap: a new one for every play. A
  /// loop (the music) gets a gain of its own, to fade in and out; an effect
  /// goes straight to the clip's gain with minimal JS interop calls.
  @override
  WebAudioVoice play({bool loop = false, Duration fadeIn = Duration.zero}) {
    final source = _context.createBufferSource()..buffer = _buffer;
    if (loop) source.loop = true;
    final now = _context.currentTime;
    web.GainNode? fader;
    if (loop || fadeIn > Duration.zero) {
      fader = _context.createGain()..connect(_gain);
      if (fadeIn > Duration.zero) {
        fader.gain
          ..setValueAtTime(0, now)
          ..linearRampToValueAtTime(1, now + _seconds(fadeIn));
      }
      source.connect(fader);
    } else {
      source.connect(_gain);
    }
    source.start();
    final endTime = loop ? double.infinity : now + _buffer.duration;
    final voice = _BrowserVoice(_context, source, fader, loop, endTime);
    if (!loop && _channel == WebAudioChannel.effects) {
      _owner._trackSfxVoice(voice, now);
    }
    return voice;
  }
}

double _seconds(Duration d) => d.inMicroseconds / 1e6;

class _BrowserVoice implements WebAudioVoice {
  _BrowserVoice(
    this._context,
    this._source,
    this._fader,
    this._loop,
    this._endTime,
  );
  final web.AudioContext _context;
  final web.AudioBufferSourceNode _source;
  final web.GainNode? _fader;
  final bool _loop;
  final double _endTime;
  bool _stopped = false;

  void _disconnect() {
    _source.onended = null;
    try {
      _source.disconnect();
    } catch (_) {}
    final fader = _fader;
    if (fader != null) {
      try {
        fader.disconnect();
      } catch (_) {}
    }
  }

  /// Stopping a source that has already ended is an immediate no-op (zero
  /// `source.stop()` JS calls on finished SFX). A fade runs on the audio clock
  /// and disconnects its fader GainNode on completion so WebKit's audio graph
  /// never accumulates dangling nodes.
  @override
  void stop({Duration fadeOut = Duration.zero}) {
    if (_stopped) return;
    _stopped = true;
    final fader = _fader;
    if (!_loop && fader == null && _context.currentTime >= _endTime) {
      return;
    }
    if (fader == null || fadeOut <= Duration.zero) {
      try {
        _source.stop();
      } catch (_) {}
      _disconnect();
      return;
    }
    final now = _context.currentTime, end = now + _seconds(fadeOut);
    fader.gain
      ..cancelScheduledValues(now)
      ..setValueAtTime(fader.gain.value, now)
      ..linearRampToValueAtTime(0, end);
    _source.onended = ((web.Event _) => _disconnect()).toJS;
    try {
      _source.stop(end);
    } catch (_) {
      _disconnect();
    }
  }
}
