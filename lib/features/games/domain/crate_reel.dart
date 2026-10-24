import 'dart:math';

/// The motion of the reel when a costume crate opens, as in Counter-Strike:
/// a fast start, a long braking that makes every card count, a small slide
/// past the stop and back.
///
/// Positions are in card widths: 0 has the marker on the middle of the
/// first card, `n` on the middle of card `n`.
class CrateReel {
  CrateReel({
    required this.winner,
    this.duration = 6.4,
    double? landing,
    Random? random,
  }) : landing = landing ?? ((random ?? Random()).nextDouble() - .5) * .7;

  /// The card that is won.
  final int winner;

  /// Seconds until the reel rests.
  final double duration;

  /// Where on the won card the marker stops, from −.35 (left) to .35.
  final double landing;

  /// How far it slides past the stop before it settles, in cards.
  static const overshoot = .22;

  /// Share of [duration] for the slide back.
  static const settleShare = .12;

  double get stop => winner + landing;

  /// The position after [t] seconds.
  double position(double t) {
    final brake = duration * (1 - settleShare);
    if (t <= 0) return 0;
    if (t >= duration) return stop;
    if (t < brake) {
      // Quartic ease-out: full speed at once, then a long, even braking.
      final u = t / brake;
      return (stop + overshoot) * (1 - pow(1 - u, 4));
    }
    final u = (t - brake) / (duration - brake);
    final ease = u * u * (3 - 2 * u);
    return stop + overshoot * (1 - ease);
  }

  /// The card under the marker after [t] seconds.
  int cardAt(double t) => (position(t) + .5).floor();

  bool done(double t) => t >= duration;
}
