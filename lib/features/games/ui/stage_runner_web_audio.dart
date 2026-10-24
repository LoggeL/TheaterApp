import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'stage_runner_sound.dart';

/// One audio context of the browser for all sounds of the game.
WebAudio openWebAudio() => _BrowserAudio(web.AudioContext());

class _BrowserAudio implements WebAudio {
  _BrowserAudio(this._context);
  final web.AudioContext _context;

  @override
  void resume() {
    if (_context.state != 'running') _context.resume().toDart.ignore();
  }

  @override
  void suspend() => _context.suspend().toDart.ignore();

  @override
  Future<WebAudioClip> decode(Uint8List bytes, double volume) async {
    // The browser takes over (detaches) the buffer it decodes, so it gets
    // its own copy.
    final data = Uint8List.fromList(bytes).buffer.toJS;
    final buffer = await _context.decodeAudioData(data).toDart;
    final gain = _context.createGain()..gain.value = volume;
    gain.connect(_context.destination);
    return _BrowserClip(_context, buffer, gain);
  }

  @override
  void close() => _context.close().toDart.ignore();
}

class _BrowserClip implements WebAudioClip {
  _BrowserClip(this._context, this._buffer, this._gain);
  final web.AudioContext _context;
  final web.AudioBuffer _buffer;
  final web.GainNode _gain;

  /// A buffer source plays once and is cheap: a new one for every play. A
  /// loop (the music) gets a gain of its own, to fade in and out; an effect
  /// goes straight to the clip's gain.
  @override
  WebAudioVoice play({bool loop = false, Duration fadeIn = Duration.zero}) {
    final source = _context.createBufferSource()
      ..buffer = _buffer
      ..loop = loop;
    web.GainNode? fader;
    if (loop || fadeIn > Duration.zero) {
      fader = _context.createGain()..connect(_gain);
      if (fadeIn > Duration.zero) {
        final now = _context.currentTime;
        fader.gain
          ..setValueAtTime(0, now)
          ..linearRampToValueAtTime(1, now + _seconds(fadeIn));
      }
      source.connect(fader);
    } else {
      source.connect(_gain);
    }
    source.start();
    return _BrowserVoice(_context, source, fader);
  }
}

double _seconds(Duration d) => d.inMicroseconds / 1e6;

class _BrowserVoice implements WebAudioVoice {
  _BrowserVoice(this._context, this._source, this._fader);
  final web.AudioContext _context;
  final web.AudioBufferSourceNode _source;
  final web.GainNode? _fader;

  /// Stopping a source that has already ended does nothing. A fade runs on
  /// the audio clock: the source stops by itself at its end.
  @override
  void stop({Duration fadeOut = Duration.zero}) {
    final fader = _fader;
    if (fader == null || fadeOut <= Duration.zero) return _source.stop();
    final now = _context.currentTime, end = now + _seconds(fadeOut);
    fader.gain
      ..cancelScheduledValues(now)
      ..setValueAtTime(fader.gain.value, now)
      ..linearRampToValueAtTime(0, end);
    _source.stop(end);
  }
}
