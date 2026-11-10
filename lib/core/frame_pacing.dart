import 'dart:math';

import 'package:flutter/widgets.dart';

import 'frame_clock_io.dart'
    if (dart.library.js_interop) 'frame_clock_web.dart';

/// Frame pacing for browsers whose frame time stamps jitter.
///
/// Animations, scrolling and the Bühnenlauf move by the time between two
/// frames' time stamps. Chromium and Firefox stamp a frame with its vsync,
/// so those distances are even. WebKit (Safari, and every browser on iOS)
/// stamps it with the moment the main thread got to it, rounded to a
/// millisecond: the pictures still come at the display's rate, but their
/// stamps are 16, 17 or 18 ms apart, and whenever the main thread was busy a
/// stamp is several milliseconds late and the next one early by as much.
/// The telemetry of November 2026 shows that for about 7 % of all frames on
/// iOS (below 0.2 % on Android): the picture judders although no frame is
/// missing. [PacedBinding] hands the framework evened-out stamps instead
/// ([FramePacer]).
///
/// The telemetry keeps measuring the stamps as the browser gave them
/// ([rawTimeStamp], [rawInterval]), so its numbers stay comparable.
abstract final class FramePacing {
  /// Off when the server says so (`noFramePacing` in
  /// `capabilities.features`): the stamps then pass as they come.
  static bool enabled = true;

  /// The current frame's stamp as the engine gave it, and its distance to
  /// the frame before; null without a [PacedBinding] or before its frames.
  static Duration? rawTimeStamp, rawInterval;

  /// The binding of the app: a [PacedBinding] where the frame clock jitters
  /// ([frameClockJitters]), else Flutter's own.
  static WidgetsBinding ensureInitialized() => frameClockJitters
      ? PacedBinding.ensureInitialized()
      : WidgetsFlutterBinding.ensureInitialized();
}

/// A [WidgetsFlutterBinding] whose frames begin with paced time stamps.
class PacedBinding extends WidgetsFlutterBinding {
  static PacedBinding? _instance;

  static WidgetsBinding ensureInitialized() {
    if (_instance == null) PacedBinding();
    return WidgetsBinding.instance;
  }

  final _pacer = FramePacer();

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    // A warm-up frame has no stamp of its own.
    if (rawTimeStamp == null) return super.handleBeginFrame(null);
    final last = FramePacing.rawTimeStamp;
    FramePacing.rawInterval = last == null ? null : rawTimeStamp - last;
    FramePacing.rawTimeStamp = rawTimeStamp;
    super.handleBeginFrame(
      _pacer.pace(rawTimeStamp, enabled: FramePacing.enabled),
    );
  }
}

/// Evens out frame time stamps that jitter around a steady display rate.
///
/// It learns the display's period from the first steady frames and then
/// keeps its own clock: each frame is a whole number of periods after the
/// one before, and the clock follows the stamps it is given only slowly (a
/// phase-locked loop), so a stamp that is late by a few milliseconds moves
/// the picture by a few tenths of one. A frame that really was skipped
/// counts as two periods. Pauses between frames (the app draws only when
/// something changes) and long hitches pass as measured, and whenever the
/// stamps stop fitting the period (another refresh rate, e.g. the 30 Hz of
/// the iPhone's low power mode) it passes them through and learns anew.
///
/// The paced clock never runs backwards and stays close to the stamps it is
/// given: it cannot drift away from them.
class FramePacer {
  /// Intervals to see before pacing starts, how many of them must be
  /// alike, and how far from their median "alike" reaches: that share of
  /// it, at least the rounding of two stamps.
  static const _learned = 16, _alike = 13, _spread = .12, _rounding = 1500;

  /// The share of the distance to the given stamp the clock follows per
  /// frame, and how much of it goes into the period; of a distance beyond
  /// [_trust] of a period only that much counts (a single late stamp says
  /// little about the display).
  static const _follow = .1, _tune = .002, _trust = .15;

  /// A stamp this share of a period before the clock's next step still
  /// belongs to it; up to the rest of the period after it, too. Stamps are
  /// late far more often than early (a busy main thread), on iOS about
  /// 1.5 % of them by half to three quarters of a period.
  static const _early = .15;

  /// A stamp further than this share of a period from the clock does not
  /// fit; after [_patience] of them in a row the period is learned anew.
  static const _fit = .35, _patience = 5;

  /// Intervals a display can have: 20 to 400 Hz.
  static const _shortest = 2500, _longest = 50000;

  /// The display's period in microseconds; 0 while it is being learned.
  double get period => _period;
  double _period = 0, _learnedPeriod = 0;

  int? _lastRaw;
  int _lastStamp = 0;

  /// The paced clock at the last frame, and how far it is ahead of the
  /// stamps' clock, in microseconds.
  double _clock = 0, _ahead = 0;
  final List<int> _intervals = [];
  int _misfits = 0;

  /// The stamp to begin the frame of [raw] with. With [enabled] false the
  /// stamps pass with their own distances.
  Duration pace(Duration raw, {bool enabled = true}) {
    final t = raw.inMicroseconds, last = _lastRaw;
    _lastRaw = t;
    if (last == null) {
      _clock = t.toDouble();
      return _stamp();
    }
    final d = t - last;
    // The stamps' clock never runs backwards; if it did, wait for it.
    if (d <= 0) return _stamp();
    if (!enabled) {
      _forget();
      return _pass(t, d);
    }
    if (_period == 0) {
      _learn(d);
      return _pass(t, d);
    }
    // A pause between frames or a long hitch: as measured.
    if (d > 3.5 * _period) {
      _misfits = 0;
      return _pass(t, d);
    }
    final at = t + _ahead;
    final steps = max(1, ((at - _clock) / _period + _early).floor());
    final expected = _clock + steps * _period;
    final off = at - expected;
    _misfits = off.abs() <= _fit * _period ? 0 : _misfits + 1;
    if (_misfits >= _patience) {
      _forget();
      return _pass(t, d);
    }
    final limit = _trust * _period, counted = off.clamp(-limit, limit);
    _clock = expected + _follow * counted;
    _period = (_period + _tune * counted / steps).clamp(
      _learnedPeriod * .8,
      _learnedPeriod * 1.25,
    );
    return _stamp();
  }

  /// The frame is as far from the last one as its stamps are.
  Duration _pass(int t, int d) {
    _clock += d;
    _ahead = _clock - t;
    return _stamp();
  }

  Duration _stamp() {
    // Whole microseconds that never run backwards.
    _lastStamp = max(_lastStamp, _clock.round());
    return Duration(microseconds: _lastStamp);
  }

  void _forget() {
    _period = 0;
    _misfits = 0;
    _intervals.clear();
  }

  /// Learns the period from [_learned] intervals in a row of which most are
  /// alike: their mean, as single stamps are rounded.
  void _learn(int d) {
    if (d < _shortest || d > _longest) {
      _intervals.clear();
      return;
    }
    _intervals.add(d);
    if (_intervals.length < _learned) return;
    final sorted = [..._intervals]..sort();
    final median = sorted[sorted.length ~/ 2];
    final alike = [
      for (final i in _intervals)
        if ((i - median).abs() <= max(median * _spread, _rounding)) i,
    ];
    if (alike.length < _alike) {
      _intervals.removeAt(0);
      return;
    }
    _period = _learnedPeriod = alike.reduce((a, b) => a + b) / alike.length;
    _intervals.clear();
  }
}
