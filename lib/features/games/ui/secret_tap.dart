import 'dart:math';

import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';

/// Calls [onUnlocked] after [taps] quick taps on [child]; a pause longer than
/// [window] between two taps starts the count again.
///
/// Every tap gives a small playful hop that grows with the series, with a
/// warm glow and, from the third tap, a spotlight glint. The last tap ends
/// in a short sparkle before [onUnlocked] runs. At rest [child] looks
/// exactly as before, and screen readers get nothing extra: no button, no
/// tap action. With reduced motion only the glow shows and the last tap
/// unlocks at once.
class SecretTap extends StatefulWidget {
  const SecretTap({
    super.key,
    required this.child,
    required this.onUnlocked,
    this.taps = 7,
    this.window = const Duration(milliseconds: 900),
  });
  final Widget child;
  final VoidCallback onUnlocked;
  final int taps;
  final Duration window;

  @override
  State<SecretTap> createState() => _SecretTapState();
}

class _SecretTapState extends State<SecretTap> with TickerProviderStateMixin {
  static const _fadeOut = Duration(milliseconds: 300);

  /// One hop per tap.
  late final _kick = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// Runs from each tap through [SecretTap.window] and the glow fading out;
  /// it also times the series, so it keeps its pace with reduced motion.
  late final _series = AnimationController(
    vsync: this,
    duration: widget.window + _fadeOut,
    animationBehavior: AnimationBehavior.preserve,
  );

  /// The closing sparkle; the game opens when it ends.
  late final AnimationController _finale =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 320),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _finale.value = 0;
          widget.onUnlocked();
        }
      });

  int _count = 0;

  /// The glow of the series so far, from 0 to 1.
  double _level = 0;

  double get _windowShare =>
      widget.window.inMicroseconds / _series.duration!.inMicroseconds;

  bool get _seriesAlive => _series.isAnimating && _series.value < _windowShare;

  @override
  void dispose() {
    _kick.dispose();
    _series.dispose();
    _finale.dispose();
    super.dispose();
  }

  void _tap() {
    if (_finale.isAnimating) return;
    _count = _seriesAlive ? _count + 1 : 1;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_count >= widget.taps) {
      _count = 0;
      _level = 1;
      _series.value = 0;
      if (reduced) {
        _level = 0;
        widget.onUnlocked();
      } else {
        _kick.value = 0;
        _finale.forward(from: 0);
      }
      return;
    }
    _level = _count / widget.taps;
    _series.forward(from: 0);
    if (!reduced) _kick.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: _tap,
    child: AnimatedBuilder(
      animation: Listenable.merge([_kick, _series, _finale]),
      child: widget.child,
      builder: (context, child) {
        final finale = _finale.value;
        // The glow holds through the window, then fades back to rest.
        final fade = _series.value <= _windowShare
            ? 1.0
            : 1 - (_series.value - _windowShare) / (1 - _windowShare);
        final double glow = _finale.isAnimating
            ? 1 - finale * .6
            : _series.isAnimating
            ? _level * fade
            : 0.0;
        final k = _kick.value, strength = .4 + .6 * _level;
        final wave = sin(k * 2 * pi) * (1 - k);
        final pulse = sin(finale * pi);
        final moving = _kick.isAnimating || _finale.isAnimating;
        final matrix = Matrix4.identity();
        if (moving) {
          matrix
            ..translateByDouble(0, -sin(k * pi) * 3 * strength, 0, 1)
            ..rotateZ(sin(k * 3 * pi) * (1 - k) * .14 * strength + pulse * .1)
            ..scaleByDouble(
              1 + .12 * strength * wave + .18 * pulse,
              1 - .12 * strength * wave + .18 * pulse,
              1,
              1,
            );
        }
        final glint = _count >= 3 && _kick.isAnimating ? k : null;
        return CustomPaint(
          painter: glow > 0 ? _GlowPainter(glow) : null,
          foregroundPainter: _finale.isAnimating
              ? _SparklePainter(finale)
              : null,
          child: Transform(
            alignment: Alignment.center,
            transform: matrix,
            child: CustomPaint(
              foregroundPainter: glint != null
                  ? _GlintPainter(glint, _level)
                  : null,
              child: child,
            ),
          ),
        );
      },
    ),
  );
}

/// A warm halo behind the logo: a radial gradient, no blur.
class _GlowPainter extends CustomPainter {
  _GlowPainter(this.level);
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * (.75 + .25 * level);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            StageTheme.orange.withValues(alpha: .55 * level),
            StageTheme.orange.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.level != level;
}

/// A spotlight glint sweeping across the logo.
class _GlintPainter extends CustomPainter {
  _GlintPainter(this.progress, this.level);
  final double progress, level;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(w * .16)),
    );
    final x = -w * .5 + progress * w * 2;
    final band = Path()
      ..moveTo(x, 0)
      ..lineTo(x + w * .22, 0)
      ..lineTo(x - w * .18, size.height)
      ..lineTo(x - w * .4, size.height)
      ..close();
    canvas.drawPath(
      band,
      Paint()..color = Colors.white.withValues(alpha: .25 + .4 * level),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlintPainter old) =>
      old.progress != progress || old.level != level;
}

/// Confetti puff of the last tap.
class _SparklePainter extends CustomPainter {
  _SparklePainter(this.progress);
  final double progress;

  static const _colors = [
    StageTheme.orange,
    Color(0xFFFFC94A),
    Color(0xFFE5486B),
    Colors.white,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final reach =
        size.shortestSide * (.55 + .75 * Curves.easeOut.transform(progress));
    final dot = size.shortestSide * .09 * (1 - progress);
    final paint = Paint();
    for (var i = 0; i < 10; i++) {
      final angle = i * 2 * pi / 10 + progress * .6;
      paint.color = _colors[i % _colors.length];
      canvas.drawCircle(
        center + Offset(cos(angle), sin(angle)) * reach * (i.isEven ? 1 : .8),
        dot,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.progress != progress;
}
