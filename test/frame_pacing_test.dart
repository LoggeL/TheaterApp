import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/frame_pacing.dart';

/// Frame stamps as Safari on iOS gives them (the Bühnenlauf's telemetry of
/// November 2026, 2.5 million frames): the display runs at [hz], each stamp
/// is late by what the main thread was busy with (mostly under a
/// millisecond, 2.4 % by 1.3 to 8.3 ms, 1.5 % by 8.3 to 12.7 ms, 0.03 % by
/// more) and rounded down to a millisecond; [drops] of the frames are
/// skipped altogether. Returns the stamps in microseconds and the display's
/// true frame numbers.
({List<int> stamps, List<int> frames}) _safari(
  int count, {
  double hz = 60,
  double drops = .002,
  int seed = 1,
}) {
  final random = Random(seed), period = 1e6 / hz;
  final stamps = <int>[], frames = <int>[];
  var frame = 0;
  for (var i = 0; i < count; i++) {
    frame += random.nextDouble() < drops ? 2 : 1;
    final roll = random.nextDouble();
    // Scaled to the period: a stamp is never late by a whole one.
    final late =
        (roll < .0003
            ? 12700 + random.nextDouble() * 3300
            : roll < .0153
            ? 8300 + random.nextDouble() * 4400
            : roll < .0393
            ? 1300 + random.nextDouble() * 7000
            : random.nextDouble() * 1000) *
        min(1, 60 / hz);
    final at = 1e6 + frame * period + late;
    // A late frame never passes the next one.
    final stamp = (at / 1000).floor() * 1000;
    stamps.add(stamps.isEmpty ? stamp : max(stamp, stamps.last + 1000));
    frames.add(frame);
  }
  return (stamps: stamps, frames: frames);
}

/// The root mean square of how far each step in [times] is from the display
/// time between its frames, in milliseconds.
double _unevenness(List<int> times, List<int> frames, double period) {
  var sum = 0.0;
  for (var i = 1; i < times.length; i++) {
    final ideal = (frames[i] - frames[i - 1]) * period;
    sum += pow((times[i] - times[i - 1] - ideal) / 1000, 2);
  }
  return sqrt(sum / (times.length - 1));
}

List<int> _paced(FramePacer pacer, List<int> stamps) => [
  for (final t in stamps) pacer.pace(Duration(microseconds: t)).inMicroseconds,
];

void main() {
  test('Safari\'s jittering stamps come out evenly spaced', () {
    const period = 1e6 / 60;
    final run = _safari(6000);
    final paced = _paced(FramePacer(), run.stamps);
    // Skip the frames the period is learned from.
    final raw = _unevenness(
      run.stamps.sublist(60),
      run.frames.sublist(60),
      period,
    );
    final even = _unevenness(paced.sublist(60), run.frames.sublist(60), period);
    expect(raw, greaterThan(1.8));
    expect(even, lessThan(raw / 8));
    // Steps off by more than a millisecond: about 5 % of the stamps', next
    // to none of the paced ones.
    int off(List<int> times) => [
      for (var i = 61; i < times.length; i++)
        if ((times[i] -
                    times[i - 1] -
                    (run.frames[i] - run.frames[i - 1]) * period)
                .abs() >
            1000)
          i,
    ].length;
    expect(off(run.stamps), greaterThan(250));
    expect(off(paced), lessThan(off(run.stamps) / 20));
  });

  test('the paced clock neither drifts from the stamps nor runs back', () {
    final run = _safari(20000, seed: 7);
    final paced = _paced(FramePacer(), run.stamps);
    for (var i = 1; i < paced.length; i++) {
      expect(paced[i], greaterThanOrEqualTo(paced[i - 1]));
    }
    // Over five and a half minutes it runs as fast as the stamps' clock to
    // within a few frames: a stamp late by nearly a whole period counts as
    // a skipped frame, and that period stays.
    final rawSpan = run.stamps.last - run.stamps.first;
    final pacedSpan = paced.last - paced.first;
    expect(rawSpan, greaterThan(330 * 1000000));
    expect((pacedSpan - rawSpan).abs(), lessThan(6 * 16667));
  });

  test('a skipped frame counts as two periods', () {
    final pacer = FramePacer();
    var t = 1000000;
    for (var i = 0; i < 40; i++) {
      pacer.pace(Duration(microseconds: t += 16667));
    }
    final before = pacer.pace(Duration(microseconds: t += 16667));
    final after = pacer.pace(Duration(microseconds: t += 33334));
    expect((after - before).inMicroseconds, closeTo(33334, 300));
  });

  test('a late stamp followed by an early one is two even steps', () {
    final pacer = FramePacer();
    var t = 1000000;
    for (var i = 0; i < 40; i++) {
      pacer.pace(Duration(microseconds: t += 16667));
    }
    final a = pacer.pace(Duration(microseconds: t += 16667));
    // 11 ms late, the next one on time again: 28 and 5.6 ms apart.
    final b = pacer.pace(Duration(microseconds: t += 27667));
    final c = pacer.pace(Duration(microseconds: t += 5667));
    expect((b - a).inMicroseconds, closeTo(16667, 400));
    expect((c - b).inMicroseconds, closeTo(16667, 400));
    expect((c - a).inMicroseconds, closeTo(33334, 400));
  });

  test('pauses between frames and long hitches pass as measured', () {
    final pacer = FramePacer();
    var t = 1000000;
    for (var i = 0; i < 40; i++) {
      pacer.pace(Duration(microseconds: t += 16667));
    }
    final before = pacer.pace(Duration(microseconds: t += 16667));
    // The app drew nothing for 1.4 s, then a 120 ms hitch.
    final resumed = pacer.pace(Duration(microseconds: t += 1400000));
    expect((resumed - before).inMicroseconds, 1400000);
    final hitch = pacer.pace(Duration(microseconds: t += 120000));
    expect((hitch - resumed).inMicroseconds, 120000);
    // And it paces on right after.
    final next = pacer.pace(Duration(microseconds: t += 17000));
    expect((next - hitch).inMicroseconds, closeTo(16667, 400));
  });

  test('the first frames pass until the period is known', () {
    final pacer = FramePacer();
    final stamps = [for (var i = 0; i < 12; i++) 1000000 + i * 17000];
    expect(_paced(pacer, stamps), stamps);
    expect(pacer.period, 0);
  });

  test('uneven frames are never paced', () {
    final pacer = FramePacer(), random = Random(3);
    var t = 1000000;
    final stamps = [
      for (var i = 0; i < 300; i++) t += 5000 + random.nextInt(40000),
    ];
    expect(_paced(pacer, stamps), stamps);
  });

  test('another refresh rate is learned anew', () {
    final pacer = FramePacer();
    var t = 1000000;
    final stamps = <int>[
      for (var i = 0; i < 120; i++) t += 16667,
      // Low power mode: 30 Hz. Twice the period fits and is paced as such.
      for (var i = 0; i < 120; i++) t += 33333,
      // A display at 120 Hz: half the period does not fit.
      for (var i = 0; i < 240; i++) t += 8333,
    ];
    final paced = _paced(pacer, stamps);
    for (var i = 130; i < 240; i++) {
      expect(paced[i] - paced[i - 1], closeTo(33333, 300));
    }
    expect(pacer.period, closeTo(8333, 100));
    for (var i = 300; i < paced.length; i++) {
      expect(paced[i] - paced[i - 1], closeTo(8333, 200));
    }
    for (var i = 1; i < paced.length; i++) {
      expect(paced[i], greaterThanOrEqualTo(paced[i - 1]));
    }
    // The clock ran a little ahead while it still paced at the old rate,
    // never far, and not once the new one is known.
    for (var i = 0; i < paced.length; i++) {
      expect((paced[i] - stamps[i]).abs(), lessThan(40000));
    }
  });

  test('30 Hz and 120 Hz displays are paced like 60 Hz ones', () {
    for (final hz in [30.0, 120.0]) {
      final period = 1e6 / hz;
      final run = _safari(3000, hz: hz, drops: 0, seed: 5);
      final paced = _paced(FramePacer(), run.stamps);
      expect(
        _unevenness(paced.sublist(60), run.frames.sublist(60), period),
        lessThan(.3),
        reason: '$hz Hz',
      );
    }
  });

  test('switched off, the stamps keep their own distances', () {
    final pacer = FramePacer();
    final run = _safari(400, seed: 9);
    final half = run.stamps.length ~/ 2;
    final on = _paced(pacer, run.stamps.sublist(0, half));
    final off = [
      for (final t in run.stamps.sublist(half))
        pacer.pace(Duration(microseconds: t), enabled: false).inMicroseconds,
    ];
    expect(off.first, greaterThanOrEqualTo(on.last));
    for (var i = 1; i < off.length; i++) {
      expect(
        off[i] - off[i - 1],
        run.stamps[half + i] - run.stamps[half + i - 1],
      );
    }
  });
}
