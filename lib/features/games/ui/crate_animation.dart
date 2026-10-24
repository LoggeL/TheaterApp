import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../data/wardrobe_api.dart';
import 'crate_choice.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';

/// How a crate's lid comes off.
enum CrateLid {
  /// Wobbles, then bursts open (the Zufallskiste).
  pop,

  /// Two latches click, a flash, open (the Technik-Kiste's flightcase).
  unlatch,

  /// Snaps shut and open like a jaw (Creepshow).
  snap,

  /// Flickers, then the open crate glides up like a hologram (Nexus).
  slide,

  /// Squats, then a heavy lid lifts slowly with a thud (Anno 1146).
  heavy,

  /// Fades open while threads gather in it (Schicksalsfäden).
  weave,
}

/// What flies out of a crate.
enum CrateParticle { confetti, spark, leaf, pixel, dust, thread }

/// One opening animation, pure data: [CrateTarget.animation] names one of
/// [variants]; an unknown name (a future play) plays `generic`. Only
/// transforms, opacity and simple particles, so weak devices stay smooth.
class CrateMotion {
  const CrateMotion({
    required this.lid,
    required this.particle,
    required this.colors,
    required this.accent,
    this.count = 36,
    this.gravity = 1,
    this.speed = 1,
    this.flash = false,
    this.scanlines = false,
    this.shake = .06,
    this.millis = 1300,
  });
  final CrateLid lid;
  final CrateParticle particle;

  /// The particles' colours, and the crate's own colour (glow, marks).
  final List<Color> colors;
  final Color accent;
  final int count;

  /// Positive falls, negative rises; [speed] scales how far they fly.
  final double gravity, speed;

  /// A white flash when it opens; scanlines while it flickers.
  final bool flash, scanlines;

  /// How much the closed crate wobbles while the server draws (radians).
  final double shake;

  /// How long the opening takes.
  final int millis;

  static const variants = <String, CrateMotion>{
    'generic': CrateMotion(
      lid: CrateLid.pop,
      particle: CrateParticle.spark,
      colors: [Color(0xFFFFE7A3), Color(0xFFFFFFFF), Color(0xFFE88A3A)],
      accent: Color(0xFFE88A3A),
      count: 28,
      millis: 1100,
    ),
    'burst': CrateMotion(
      lid: CrateLid.pop,
      particle: CrateParticle.confetti,
      colors: [
        Color(0xFFE4AE39),
        Color(0xFFEB4B4B),
        Color(0xFF4B69FF),
        Color(0xFFD32CE6),
        Color(0xFF2FBF71),
        Color(0xFFFFFFFF),
      ],
      accent: Color(0xFFE4AE39),
      count: 48,
      shake: .09,
    ),
    'flightcase': CrateMotion(
      lid: CrateLid.unlatch,
      particle: CrateParticle.spark,
      colors: [Color(0xFFFFF4C2), Color(0xFFFFC14D), Color(0xFFFFFFFF)],
      accent: Color(0xFF2FBF71),
      count: 34,
      flash: true,
      shake: .03,
    ),
    'maw': CrateMotion(
      lid: CrateLid.snap,
      particle: CrateParticle.leaf,
      colors: [Color(0xFF5E8C31), Color(0xFF8DBF4A), Color(0xFF3E6B24)],
      accent: Color(0xFF7FBF3F),
      count: 30,
      gravity: .8,
      speed: .8,
      millis: 1500,
    ),
    'glitch': CrateMotion(
      lid: CrateLid.slide,
      particle: CrateParticle.pixel,
      colors: [Color(0xFF4FD8FF), Color(0xFF9B7BFF), Color(0xFFFFFFFF)],
      accent: Color(0xFF4FD8FF),
      count: 40,
      gravity: -.7,
      speed: .6,
      scanlines: true,
      shake: .02,
    ),
    'heavy': CrateMotion(
      lid: CrateLid.heavy,
      particle: CrateParticle.dust,
      colors: [Color(0xFFC9B48F), Color(0xFFE4AE39), Color(0xFF9C8566)],
      accent: Color(0xFFB07A45),
      count: 30,
      gravity: .5,
      speed: .7,
      shake: .025,
      millis: 1700,
    ),
    'threads': CrateMotion(
      lid: CrateLid.weave,
      particle: CrateParticle.thread,
      colors: [Color(0xFFFFD86B), Color(0xFFE08AD8), Color(0xFFB8F1FF)],
      accent: Color(0xFFE08AD8),
      count: 26,
      gravity: -.2,
      speed: .7,
      shake: .03,
      millis: 1600,
    ),
  };

  /// The motion called [name]; `generic` for any other.
  static CrateMotion of(String name) => variants[name] ?? variants['generic']!;
}

/// A crate of [target] on stage: wobbling while [opening] is false (the
/// server draws), then its opening; [onOpened] when it is done. [quick]
/// (reduced motion) plays it in a third of the time.
class CrateUnboxing extends StatefulWidget {
  const CrateUnboxing({
    super.key,
    required this.target,
    required this.controller,
    this.art,
    this.opening = false,
    this.onOpened,
    this.quick = false,
    this.size = 220,
  });
  final CrateTarget target;
  final AppController controller;
  final RunnerArt? art;
  final bool opening, quick;
  final VoidCallback? onOpened;
  final double size;

  @override
  State<CrateUnboxing> createState() => _CrateUnboxingState();
}

class _CrateUnboxingState extends State<CrateUnboxing>
    with TickerProviderStateMixin {
  late CrateMotion _motion = CrateMotion.of(widget.target.animation);
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  )..repeat();
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: Duration(
      milliseconds: (_motion.millis * (widget.quick ? .33 : 1)).round(),
    ),
  );
  late List<_Particle> _particles = _Particle.many(
    _motion,
    Random(widget.target.id.hashCode),
  );
  ui.Image? _fx;

  @override
  void initState() {
    super.initState();
    _loadFx();
    if (widget.opening) _start();
  }

  void _loadFx() {
    final fx = widget.target.fxImage;
    _fx = WardrobePictures.cached(fx);
    if (fx != null && _fx == null) {
      WardrobePictures.loadPortrait(widget.controller, fx).then((image) {
        if (mounted && image != null && fx == widget.target.fxImage) {
          setState(() => _fx = image);
        }
      });
    }
  }

  @override
  void didUpdateWidget(CrateUnboxing old) {
    super.didUpdateWidget(old);
    // Another crate in the same place: its own motion, particles and fx.
    if (widget.target.id != old.target.id ||
        widget.target.animation != old.target.animation ||
        widget.target.fxImage != old.target.fxImage) {
      _motion = CrateMotion.of(widget.target.animation);
      _particles = _Particle.many(_motion, Random(widget.target.id.hashCode));
      _open.duration = Duration(
        milliseconds: (_motion.millis * (widget.quick ? .33 : 1)).round(),
      );
      _loadFx();
    }
    if (widget.opening && !old.opening) _start();
    // Closed again (the next crate): back to waiting.
    if (!widget.opening && old.opening) {
      _open.reset();
      _idle.repeat();
    }
  }

  void _start() {
    _idle.stop();
    _open.forward(from: 0).whenComplete(() {
      if (mounted && _open.isCompleted) widget.onOpened?.call();
    });
  }

  @override
  void dispose() {
    _idle.dispose();
    _open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final closed = CratePicture(
      target: widget.target,
      controller: widget.controller,
      art: widget.art,
    );
    final open = widget.target.openImage == null
        ? closed
        : CratePicture(
            target: widget.target,
            controller: widget.controller,
            art: widget.art,
            open: true,
          );
    return SizedBox(
      width: size * 1.8,
      height: size * 1.8,
      child: AnimatedBuilder(
        animation: Listenable.merge([_idle, _open]),
        builder: (context, _) {
          final t = _open.value, idle = _idle.value;
          final pose = _CratePose.of(_motion, t, idle, widget.opening);
          Widget layer(
            Widget child,
            double opacity,
            Offset shift,
            double sx,
            double sy,
          ) => opacity <= 0
              ? const SizedBox.shrink()
              : Opacity(
                  opacity: opacity.clamp(0, 1).toDouble(),
                  child: Transform.translate(
                    offset: shift * size,
                    child: Transform(
                      alignment: Alignment.bottomCenter,
                      transform: Matrix4.diagonal3Values(sx, sy, 1),
                      child: SizedBox.square(dimension: size, child: child),
                    ),
                  ),
                );
          return Stack(
            alignment: Alignment.center,
            children: [
              // Glow and flash behind, particles in front: one painter each.
              Positioned.fill(
                child: CustomPaint(
                  painter: _BackPainter(_motion, t, pose.flash),
                ),
              ),
              Transform.rotate(
                angle: pose.angle,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    layer(closed, pose.closed, pose.shift, pose.sx, pose.sy),
                    layer(
                      open,
                      pose.open,
                      pose.openShift,
                      pose.openSx,
                      pose.openSy,
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _ParticlePainter(
                      _motion,
                      _particles,
                      t,
                      size,
                      _fx,
                      pose.flash,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Where the crate's layers stand at opening progress [t] (0..1), or while
/// waiting at the idle phase [idle].
class _CratePose {
  const _CratePose({
    this.angle = 0,
    this.closed = 1,
    this.open = 0,
    this.shift = Offset.zero,
    this.openShift = Offset.zero,
    this.sx = 1,
    this.sy = 1,
    this.openSx = 1,
    this.openSy = 1,
    this.flash = 0,
  });

  /// [flash] lights the stage behind the crate and, fainter, in front of it:
  /// the closed and the open picture are drawn apart (only their feet
  /// match), so their swap hides under a flash, a pop or a squash.
  final double angle, closed, open, sx, sy, openSx, openSy, flash;
  final Offset shift, openShift;

  /// From 0 to 1 while [t] goes from [a] to [b].
  static double span(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0, 1).toDouble();

  factory _CratePose.of(CrateMotion m, double t, double idle, bool opening) {
    final wobble = sin(idle * 2 * pi);
    if (!opening) return _CratePose(angle: wobble * m.shake);
    switch (m.lid) {
      case CrateLid.pop:
        // Wobbles harder, swells, bursts: the open crate pops in.
        final build = span(t, 0, .32);
        final out = span(t, .3, .38);
        final settle = Curves.elasticOut.transform(span(t, .38, .8));
        return _CratePose(
          angle: sin(t * 40) * m.shake * 1.6 * (1 - out),
          sx: 1 + .1 * build,
          sy: 1 + .1 * build,
          openSx: 1.1 - .1 * settle,
          openSy: 1.1 - .1 * settle,
          closed: 1 - out,
          open: out,
          flash: out * (1 - span(t, .4, .58)),
        );
      case CrateLid.unlatch:
        // Two clicks (a short squash each), a flash, open.
        double click(double at) => 1 - (t - at).abs() / .04;
        final squash = max(0.0, max(click(.15), click(.3))) * .05;
        final out = span(t, .41, .46);
        final settle = Curves.easeOutBack.transform(span(t, .44, .7));
        return _CratePose(
          sx: 1 + squash,
          sy: 1 - squash,
          openSy: .94 + .06 * settle,
          closed: 1 - out,
          open: out,
          flash: span(t, .36, .43) * (1 - span(t, .46, .62)),
        );
      case CrateLid.snap:
        // Shut – open – shut – open, each bite a squash.
        final bites = [(.12, .22), (.32, .4)];
        final bite = bites.any((b) => t >= b.$1 && t < b.$2);
        final open = t >= .45 || bite;
        final chew = sin(t * pi * 10).abs() * .04 * (1 - span(t, .45, .6));
        return _CratePose(
          sx: 1 + chew,
          sy: 1 - chew,
          closed: open ? 0 : 1,
          open: open ? 1 : 0,
        );
      case CrateLid.slide:
        // Glitch: the closed crate jumps sideways for a few frames, the open
        // one flickers and glides up into place.
        final glitch = t < .5 && (t * 23).floor().isOdd;
        final rise = span(t, .2, .62);
        final flicker = t < .62 && (t * 31).floor() % 3 == 0 ? .35 : 1.0;
        return _CratePose(
          shift: Offset(glitch ? .03 * sin(t * 97) : 0, 0),
          closed: 1 - span(t, .25, .55),
          open: rise * flicker,
          openShift: Offset(0, .12 * (1 - Curves.easeOutCubic.transform(rise))),
          flash: .5 * span(t, .3, .4) * (1 - span(t, .45, .62)),
        );
      case CrateLid.heavy:
        // Squats, heaves (stretches up), the lid swings back in a puff of
        // dust and rocks on its hinges (the stage shakes).
        final squat = span(t, 0, .25) * (1 - span(t, .25, .35));
        final heave = span(t, .3, .4) * (1 - span(t, .4, .46));
        final thud = t > .42 && t < .58 ? sin(t * 90) * .012 : 0.0;
        final out = span(t, .4, .45);
        final rock = t > .45
            ? sin((t - .45) * 38) * (1 - span(t, .45, .9))
            : 0.0;
        return _CratePose(
          sx: 1 + .04 * squat - .02 * heave,
          sy: 1 - .06 * squat + .05 * heave,
          shift: Offset(thud, 0),
          openSy: 1 + .035 * rock,
          closed: 1 - out,
          open: out,
          openShift: Offset(thud, 0),
          flash: .7 * span(t, .37, .43) * (1 - span(t, .45, .6)),
        );
      case CrateLid.weave:
        // A slow fade while the threads gather.
        // The threads gather into a glow, under it the crate is open.
        final out = Curves.easeInOut.transform(span(t, .46, .58));
        final rise = Curves.easeOutCubic.transform(span(t, .5, .85));
        return _CratePose(
          angle: sin(t * 6) * .01,
          sx: 1 + .02 * sin(span(t, .1, .5) * pi),
          sy: 1 + .02 * sin(span(t, .1, .5) * pi),
          openSy: .97 + .03 * rise,
          closed: 1 - out,
          open: out,
          flash: .75 * span(t, .3, .5) * (1 - span(t, .56, .9)),
        );
    }
  }
}

/// One particle, fixed once per crate: where it flies, when, how it turns.
class _Particle {
  const _Particle(
    this.angle,
    this.speed,
    this.size,
    this.spin,
    this.color,
    this.delay,
    this.sprite,
  );
  final double angle, speed, size, spin, delay;
  final int color;

  /// Drawn as the crate's fx picture (if it has one).
  final bool sprite;

  static List<_Particle> many(CrateMotion m, Random r) => [
    for (var i = 0; i < m.count; i++)
      _Particle(
        // Mostly upwards and to the sides; rising ones all around.
        m.gravity < 0
            ? r.nextDouble() * 2 * pi
            : -pi / 2 + (r.nextDouble() - .5) * pi * 1.3,
        (.35 + r.nextDouble() * .65) * m.speed,
        .5 + r.nextDouble(),
        (r.nextDouble() - .5) * 12,
        r.nextInt(m.colors.length),
        r.nextDouble() * .15,
        i % 3 == 0,
      ),
  ];
}

/// When the particles of each lid set off, as a share of the opening.
double _burstAt(CrateLid lid) => switch (lid) {
  CrateLid.pop => .32,
  CrateLid.unlatch => .4,
  CrateLid.snap => .45,
  CrateLid.slide => .2,
  CrateLid.heavy => .4,
  CrateLid.weave => .15,
};

/// The glow behind the crate and the flash of an opening; plain circles.
class _BackPainter extends CustomPainter {
  _BackPainter(this.motion, this.t, this.flash);
  final CrateMotion motion;
  final double t, flash;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero), r = size.shortestSide / 2;
    final glow = .18 + .3 * _CratePose.span(t, _burstAt(motion.lid), 1);
    for (var i = 3; i >= 1; i--) {
      canvas.drawCircle(
        c,
        r * (.3 + .2 * i),
        Paint()..color = motion.accent.withValues(alpha: glow / (i + 1)),
      );
    }
    if (flash > 0) {
      canvas.drawCircle(
        c,
        r * (.5 + .4 * flash),
        Paint()..color = Colors.white.withValues(alpha: .4 * flash),
      );
    }
    if (motion.scanlines && t > .1 && t < .75) {
      final paint = Paint()..color = motion.accent.withValues(alpha: .14);
      final step = size.height / 18, drift = (t * 40 % 1) * step;
      // Over the crate only, not the whole stage.
      final left = size.width * .2, width = size.width * .6;
      for (var y = size.height * .2 + drift; y < size.height * .8; y += step) {
        canvas.drawRect(Rect.fromLTWH(left, y, width, step * .3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_BackPainter old) => old.t != t || old.flash != flash;
}

/// The particles: the crate's fx sprite if it has one, else simple shapes.
class _ParticlePainter extends CustomPainter {
  _ParticlePainter(
    this.motion,
    this.particles,
    this.t,
    this.crate,
    this.fx,
    this.flash,
  );
  final CrateMotion motion;
  final List<_Particle> particles;
  final double t, crate, flash;
  final ui.Image? fx;

  @override
  void paint(Canvas canvas, Size size) {
    if (flash > 0) {
      // Fainter than behind: enough to hide the swap of the two pictures.
      final c = size.center(Offset(0, crate * .1));
      canvas.drawCircle(
        c,
        crate * (.3 + .25 * flash),
        Paint()..color = Colors.white.withValues(alpha: .35 * flash * flash),
      );
      canvas.drawCircle(
        c,
        crate * (.5 + .2 * flash),
        Paint()..color = motion.accent.withValues(alpha: .18 * flash),
      );
    }
    final start = _burstAt(motion.lid);
    if (t <= start) return;
    final origin = size.center(Offset(0, -crate * .1));
    final reach = size.shortestSide * .55;
    final paint = Paint()..filterQuality = FilterQuality.low;
    for (final p in particles) {
      final u = ((t - start - p.delay) / (1 - start)).clamp(0, 1).toDouble();
      if (u <= 0 || u >= 1) continue;
      final ease = Curves.easeOutCubic.transform(u);
      final at =
          origin +
          Offset(cos(p.angle), sin(p.angle)) * (reach * p.speed * ease) +
          Offset(0, motion.gravity * reach * .6 * u * u);
      final alpha = 1 - u * u;
      final s = crate * .045 * p.size;
      final color = motion.colors[p.color].withValues(alpha: alpha);
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(p.spin * u);
      // Every third one is the crate's own piece (a star, a coin, a leaf …)
      // if it has one, the others the simple shapes around it.
      final sprite = p.sprite ? fx : null;
      if (sprite != null) {
        paint.color = Colors.white.withValues(alpha: alpha);
        canvas.drawImageRect(
          sprite,
          Rect.fromLTWH(
            0,
            0,
            sprite.width.toDouble(),
            sprite.height.toDouble(),
          ),
          Rect.fromCenter(center: Offset.zero, width: s * 3, height: s * 3),
          paint,
        );
      } else {
        paint.color = color;
        switch (motion.particle) {
          case CrateParticle.confetti:
            canvas.drawRect(
              Rect.fromCenter(center: Offset.zero, width: s, height: s * .5),
              paint,
            );
          case CrateParticle.spark:
            paint.strokeWidth = s * .25;
            canvas.drawLine(Offset(-s * .8, 0), Offset(s * .8, 0), paint);
          case CrateParticle.leaf:
            canvas.drawOval(
              Rect.fromCenter(
                center: Offset.zero,
                width: s * 1.3,
                height: s * .6,
              ),
              paint,
            );
          case CrateParticle.pixel:
            canvas.rotate(-p.spin * u);
            canvas.drawRect(
              Rect.fromCenter(
                center: Offset.zero,
                width: s * .6,
                height: s * .6,
              ),
              paint,
            );
          case CrateParticle.dust:
            paint.color = color.withValues(alpha: alpha * .6);
            canvas.drawCircle(Offset.zero, s * (.5 + u), paint);
          case CrateParticle.thread:
            paint
              ..strokeWidth = s * .12
              ..style = PaintingStyle.stroke;
            canvas.drawArc(
              Rect.fromCenter(center: Offset.zero, width: s * 3, height: s * 3),
              0,
              pi * (.4 + u),
              false,
              paint,
            );
            paint.style = PaintingStyle.fill;
        }
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) =>
      old.t != t || old.fx != fx || old.flash != flash;
}
