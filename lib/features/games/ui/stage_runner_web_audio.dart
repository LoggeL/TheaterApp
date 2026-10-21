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

  /// A buffer source plays once and is cheap: a new one for every play.
  @override
  WebAudioVoice play({bool loop = false}) {
    final source = _context.createBufferSource()
      ..buffer = _buffer
      ..loop = loop;
    source
      ..connect(_gain)
      ..start();
    return _BrowserVoice(source);
  }
}

class _BrowserVoice implements WebAudioVoice {
  _BrowserVoice(this._source);
  final web.AudioBufferSourceNode _source;

  /// Stopping a source that has already ended does nothing.
  @override
  void stop() => _source.stop();
}
