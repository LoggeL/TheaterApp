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
  static final _identity = Matrix4.identity();

  /// Controllers are created lazily on first tap so idle HeaderLogos across
  /// every app screen carry zero tickers or AnimatedBuilders.
  AnimationController? _kick;
  AnimationController? _series;
  AnimationController? _finale;
  Listenable? _merged;

  int _count = 0;

  /// The glow of the series so far, from 0 to 1.
  double _level = 0;

  double get _windowShare =>
      widget.window.inMicroseconds / _series!.duration!.inMicroseconds;

  bool get _seriesAlive =>
      _series != null && _series!.isAnimating && _series!.value < _windowShare;

  void _ensureControllers() {
    if (_merged != null) return;
    final kick = _kick = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    final series = _series = AnimationController(
      vsync: this,
      duration: widget.window + _fadeOut,
      animationBehavior: AnimationBehavior.preserve,
    );
    final finale = _finale = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _finale!.value = 0;
          widget.onUnlocked();
        }
      });
    _merged = Listenable.merge([kick, series, finale]);
    setState(() {});
  }

  @override
  void dispose() {
    _kick?.dispose();
    _series?.dispose();
    _finale?.dispose();
    super.dispose();
  }

  void _tap() {
    if (_finale?.isAnimating ?? false) return;
    _ensureControllers();
    final kick = _kick!, series = _series!, finale = _finale!;
    _count = _seriesAlive ? _count + 1 : 1;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_count >= widget.taps) {
      _count = 0;
      _level = 1;
      series.value = 0;
      if (reduced) {
        _level = 0;
        widget.onUnlocked();
      } else {
        kick.value = 0;
        finale.forward(from: 0);
      }
      return;
    }
    _level = _count / widget.taps;
    series.forward(from: 0);
    if (!reduced) kick.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final merged = _merged;
    if (merged == null) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _tap,
        child: Transform(
          alignment: Alignment.center,
          transform: _identity,
          child: widget.child,
        ),
      );
    }
    final kick = _kick!, series = _series!, finale = _finale!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: _tap,
      child: AnimatedBuilder(
        animation: merged,
        child: widget.child,
        builder: (context, child) {
          final f = finale.value;
          // The glow holds through the window, then fades back to rest.
          final fade = series.value <= _windowShare
              ? 1.0
              : 1 - (series.value - _windowShare) / (1 - _windowShare);
          final double glow = finale.isAnimating
              ? 1 - f * .6
              : series.isAnimating
              ? _level * fade
              : 0.0;
          final k = kick.value, strength = .4 + .6 * _level;
          final wave = sin(k * 2 * pi) * (1 - k);
          final pulse = sin(f * pi);
          final moving = kick.isAnimating || finale.isAnimating;
          final matrix = moving ? Matrix4.identity() : _identity;
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
          final glint = _count >= 3 && kick.isAnimating ? k : null;
          return CustomPaint(
            painter: glow > 0 ? _GlowPainter(glow) : null,
            foregroundPainter: finale.isAnimating ? _SparklePainter(f) : null,
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

  static final _band = Path();
  static final _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(w * .16)),
    );
    final x = -w * .5 + progress * w * 2;
    _band
      ..reset()
      ..moveTo(x, 0)
      ..lineTo(x + w * .22, 0)
      ..lineTo(x - w * .18, size.height)
      ..lineTo(x - w * .4, size.height)
      ..close();
    _paint.color = Colors.white.withValues(alpha: .25 + .4 * level);
    canvas.drawPath(_band, _paint);
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
  static final _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final reach =
        size.shortestSide * (.55 + .75 * Curves.easeOut.transform(progress));
    final dot = size.shortestSide * .09 * (1 - progress);
    for (var i = 0; i < 10; i++) {
      final angle = i * 2 * pi / 10 + progress * .6;
      _paint.color = _colors[i % _colors.length];
      canvas.drawCircle(
        center + Offset(cos(angle), sin(angle)) * reach * (i.isEven ? 1 : .8),
        dot,
        _paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.progress != progress;
}
