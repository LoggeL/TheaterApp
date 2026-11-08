/// The dice of a Bühnenlauf course: mulberry32, a small 32-bit generator.
///
/// Every value comes from integer arithmetic below 2^53 and masks to 32 bits,
/// so the Dart VM (64-bit integers) and the browser (dart2js and its 32-bit
/// bitwise operators on doubles) roll exactly the same numbers. That is what
/// lets everyone run the same course of the Wochenprobe from one seed.
/// `dart:math`'s `Random` does not promise that.
class CourseRandom {
  CourseRandom(int seed) : _state = seed & _mask;

  static const _mask = 0xFFFFFFFF;

  /// One more than the largest seed; a seed is any uint32.
  static const seeds = 0x100000000;

  int _state;

  /// a × b modulo 2^32 for uint32 values, in 16-bit halves so no product
  /// reaches 2^53 (where doubles on the web would lose bits).
  static int _mul(int a, int b) {
    final low = a * (b & 0xFFFF);
    final high = (a * (b >> 16)) & 0xFFFF;
    return (low + (high << 16)) & _mask;
  }

  /// The next uint32.
  int nextUint32() {
    _state = (_state + 0x6D2B79F5) & _mask;
    var t = _state;
    t = _mul(t ^ (t >> 15), t | 1);
    t = ((t + _mul(t ^ (t >> 7), t | 61)) & _mask) ^ t;
    return (t ^ (t >> 14)) & _mask;
  }

  /// A double in [0, 1).
  double nextDouble() => nextUint32() / seeds;

  /// An int in [0, max).
  int nextInt(int max) => (nextDouble() * max).floor();
}
