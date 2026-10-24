import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../data/wardrobe_api.dart';
import '../domain/crate_reel.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';
import 'stage_runner_sound.dart';
import 'wardrobe_cards.dart';

/// Opens a costume crate with the reel animation; returns the wardrobe as
/// it is afterwards (null if nothing changed).
Future<Wardrobe?> showCrateOpening(
  BuildContext context, {
  required AppController controller,
  required Wardrobe wardrobe,
  required RunnerSound sound,
  RunnerArt? art,
  bool ensemble = false,
}) => Navigator.of(context).push<Wardrobe>(
  PageRouteBuilder(
    opaque: false,
    barrierColor: Colors.black87,
    pageBuilder: (context, _, _) => CrateOpeningPage(
      controller: controller,
      wardrobe: wardrobe,
      sound: sound,
      art: art,
      ensemble: ensemble,
    ),
    transitionsBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ),
);

enum _Phase { opening, spinning, revealed, failed }

/// The unboxing: a short shake of the crate while the server draws, then the
/// reel runs fast and brakes long, ticking at every card, and stops on the
/// won item, which shines in its rarity colour. A tap skips to the end.
class CrateOpeningPage extends StatefulWidget {
  const CrateOpeningPage({
    super.key,
    required this.controller,
    required this.wardrobe,
    required this.sound,
    this.art,
    this.open,
    this.random,
    this.ensemble = false,
  });
  final AppController controller;
  final Wardrobe wardrobe;
  final RunnerSound sound;
  final RunnerArt? art;

  /// An Ensemble-Kiste (always shiny) instead of a crate of the own metres.
  final bool ensemble;

  /// Replaces the server call in tests.
  @visibleForTesting
  final Future<CrateOpening> Function()? open;

  /// Fixes where on the card the reel stops, in tests.
  @visibleForTesting
  final Random? random;

  @override
  State<CrateOpeningPage> createState() => _CrateOpeningPageState();
}

class _CrateOpeningPageState extends State<CrateOpeningPage>
    with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  final _position = ValueNotifier<double>(0);
  _Phase _phase = _Phase.opening;
  CrateOpening? _result;
  CrateReel? _reel;
  late Wardrobe _wardrobe = widget.wardrobe;
  bool _changed = false, _wearing = false;
  String? _error;
  int _card = 0;
  Duration _lastTick = Duration.zero;
  double _skipTo = -1;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _glow.dispose();
    _pop.dispose();
    _position.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.opening;
      _error = null;
      _result = null;
      _reel = null;
      _position.value = 0;
    });
    widget.sound.prepare();
    try {
      final opening =
          await (widget.open ??
              () => openCrate(
                widget.controller,
                dupes: dupesAvailable(widget.controller),
                ensemble: widget.ensemble,
              ))();
      // The cards' portraits, so the reel never shows an empty card; a slow
      // connection waits a moment at most.
      final ids = <String>{};
      await Future.wait([
        for (final item in opening.reel)
          if (ids.add(item.id) && item.portrait != null)
            WardrobePictures.load(widget.controller, item.portrait),
      ]).timeout(const Duration(milliseconds: 1500), onTimeout: () => []);
      if (!mounted) return;
      final quick = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      _wardrobe = opening.wardrobe;
      _changed = true;
      setState(() {
        _result = opening;
        _reel = CrateReel(
          winner: opening.winnerIndex,
          duration: quick ? 2.2 : 6.4,
          random: widget.random,
        );
        _phase = _Phase.spinning;
        _card = 0;
        _skipTo = -1;
      });
      _lastTick = Duration.zero;
      _ticker
        ..stop()
        ..start();
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = userMessage(e);
        });
      }
    }
  }

  void _tick(Duration elapsed) {
    final reel = _reel;
    if (reel == null) return;
    var t = elapsed.inMicroseconds / 1e6;
    if (_skipTo >= 0) t = _skipTo;
    _position.value = reel.position(t);
    final card = reel.cardAt(t);
    if (card != _card) {
      _card = card;
      // One tick per card, but never closer than 35 ms: at full speed the
      // cards pass faster than a click can sound.
      if (_skipTo < 0 &&
          elapsed - _lastTick >= const Duration(milliseconds: 35)) {
        _lastTick = elapsed;
        widget.sound.play(RunnerSfx.tick);
      }
    }
    if (reel.done(t)) {
      _ticker.stop();
      _reveal();
    }
  }

  /// A new shine: its own, bigger reveal.
  bool get _shine => _result?.outcome.shineNew ?? false;

  bool get _jackpot {
    final item = _result?.item;
    if (item == null) return false;
    if (_shine) return true;
    final rarities = _wardrobe.catalog.rarities;
    return rarities.isNotEmpty &&
        _wardrobe.catalog.rarityOf(item).id == rarities.last.id;
  }

  void _reveal() {
    widget.sound.play(_jackpot ? RunnerSfx.jackpot : RunnerSfx.reveal);
    setState(() => _phase = _Phase.revealed);
    _pop.forward(from: 0);
    _glow.repeat();
  }

  void _skip() {
    if (_phase == _Phase.spinning) _skipTo = _reel!.duration;
  }

  Future<void> _wear(WardrobeItem item, [WardrobeVariant? role]) async {
    setState(() => _wearing = true);
    try {
      final next = await wearItem(widget.controller, item, variant: role);
      if (mounted) setState(() => _wardrobe = next);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _wearing = false);
    }
  }

  void _close() => Navigator.of(context).pop(_changed ? _wardrobe : null);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _phase != _Phase.spinning,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _skip();
    },
    child: Scaffold(
      backgroundColor: const Color(0xF2101412),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _skip,
          child: switch (_phase) {
            _Phase.opening => _opening(context),
            _Phase.failed => _failed(context),
            _ => _stage(context),
          },
        ),
      ),
    ),
  );

  Widget _opening(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ShakingCrate(vsync: this),
        const SizedBox(height: 24),
        Text(
          widget.ensemble
              ? 'Die Ensemble-Kiste geht auf …'
              : 'Die Kostümkiste geht auf …',
          style: const TextStyle(color: Colors.white70, fontSize: 16),
        ),
      ],
    ),
  );

  Widget _failed(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.inventory_2_outlined,
            color: Colors.white54,
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            _error ?? 'Die Kiste klemmt.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                onPressed: _start,
                child: const Text('Erneut versuchen'),
              ),
              OutlinedButton(onPressed: _close, child: const Text('Schließen')),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _stage(BuildContext context) {
    final result = _result!;
    final revealed = _phase == _Phase.revealed;
    return LayoutBuilder(
      builder: (context, box) {
        final cardWidth = (box.maxWidth / 5.2).clamp(92.0, 150.0);
        return Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 16),
                Text(
                  revealed
                      ? 'Aus der Kiste:'
                      : widget.ensemble
                      ? 'Ensemble-Kiste'
                      : 'Kostümkiste',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 15,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: cardWidth * 1.25 + 40,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      key: const ValueKey('crate-reel'),
                      size: Size.infinite,
                      painter: _ReelPainter(
                        result.reel,
                        _wardrobe.catalog,
                        widget.art,
                        _position,
                        cardWidth,
                        dim: revealed,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                if (!revealed)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 24),
                    child: Text(
                      'Antippen zum Überspringen',
                      style: TextStyle(color: Colors.white38),
                    ),
                  ),
              ],
            ),
            if (revealed) Positioned.fill(child: _revealView(context, result)),
          ],
        );
      },
    );
  }

  Widget _revealView(BuildContext context, CrateOpening result) {
    final item = result.item;
    final catalog = _wardrobe.catalog;
    final rarity = catalog.rarityOf(item);
    final shine = _shine;
    final colors = shine ? shineColors : rarityColors(catalog, item);
    final jackpot = _jackpot;
    final outcome = result.outcome;
    final role = outcome.type == 'variant'
        ? item.variants.where((v) => v.id == outcome.variantId).firstOrNull
        : null;
    final worn =
        _wardrobe.worn(item.kind)?.id == item.id &&
        (role == null || _wardrobe.variantOf(item)?.id == role.id);
    final p = _wardrobe.progress;
    final left = widget.ensemble ? _wardrobe.ensemble?.crates ?? 0 : p.crates;
    final more = left > 0 && (widget.ensemble || p.dupes || !p.complete);
    final line = outcome.type == 'new' && outcome.shiny
        ? 'Neu – und gleich in Glanz!'
        : outcome.line;
    final label = catalog.labelOf(item);
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge([_glow, _pop]),
              builder: (context, _) => CustomPaint(
                painter: _GlowPainter(
                  colors,
                  _glow.value,
                  _pop.value,
                  jackpot: jackpot,
                ),
              ),
            ),
          ),
        ),
        SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (shine)
                ScaleTransition(
                  scale: CurvedAnimation(
                    parent: _pop,
                    curve: Curves.elasticOut,
                  ),
                  child: AnimatedBuilder(
                    animation: _glow,
                    builder: (context, child) => ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (bounds) => LinearGradient(
                        colors: const [
                          Color(0xFFFFD86B),
                          Color(0xFFFFFFFF),
                          Color(0xFFB8F1FF),
                          Color(0xFFFFC2F0),
                          Color(0xFFFFD86B),
                        ],
                        transform: GradientRotation(_glow.value * 2 * pi),
                      ).createShader(bounds),
                      child: child,
                    ),
                    child: const Text(
                      'GLANZ!',
                      key: ValueKey('crate-shine'),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 44,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 6,
                        shadows: [
                          Shadow(color: Color(0xFFFFE7A3), blurRadius: 28),
                        ],
                      ),
                    ),
                  ),
                )
              else if (jackpot)
                ScaleTransition(
                  scale: CurvedAnimation(
                    parent: _pop,
                    curve: Curves.elasticOut,
                  ),
                  child: Text(
                    '${rarity.name.toUpperCase()}!',
                    style: TextStyle(
                      color: rarity.color,
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 4,
                      shadows: [Shadow(color: rarity.color, blurRadius: 24)],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              ScaleTransition(
                scale: CurvedAnimation(
                  parent: _pop,
                  curve: jackpot ? Curves.elasticOut : Curves.easeOutBack,
                ),
                child: SizedBox(
                  width: 200,
                  height: 250,
                  child: WardrobeCard(
                    key: const ValueKey('crate-won'),
                    item: item,
                    wardrobe: _wardrobe,
                    controller: widget.controller,
                    art: widget.art,
                    worn: worn,
                    animateShine: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                item.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  item.kind.singular,
                  ...catalog.raritiesOf(item).map((r) => r.name),
                  ?label,
                ].join(' · '),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.first,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (line != null) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('crate-outcome'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: colors.first.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: colors.first.withValues(alpha: .6),
                    ),
                  ),
                  child: Text(
                    line,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
              if (item.rarityReason case final reason?) ...[
                const SizedBox(height: 6),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (!worn)
                    FilledButton.icon(
                      onPressed: _wearing ? null : () => _wear(item, role),
                      icon: const Icon(Icons.checkroom),
                      label: Text(role == null ? 'Anlegen' : 'Rolle anlegen'),
                    ),
                  if (more)
                    FilledButton.tonalIcon(
                      onPressed: _start,
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: Text('Nächste Kiste ($left)'),
                    ),
                  OutlinedButton(
                    onPressed: _close,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Fertig'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The closed crate wobbling while the server draws.
class _ShakingCrate extends StatefulWidget {
  const _ShakingCrate({required this.vsync});
  final TickerProvider vsync;
  @override
  State<_ShakingCrate> createState() => _ShakingCrateState();
}

class _ShakingCrateState extends State<_ShakingCrate> {
  late final AnimationController _shake = AnimationController(
    vsync: widget.vsync,
    duration: const Duration(milliseconds: 420),
  )..repeat();

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _shake,
    builder: (context, child) =>
        Transform.rotate(angle: sin(_shake.value * 2 * pi) * .08, child: child),
    child: const Icon(Icons.inventory_2, size: 96, color: Color(0xFFB07A45)),
  );
}

/// The reel: cards side by side, the marker in the middle. Everything is
/// laid out once; a frame only moves the cards.
class _ReelPainter extends CustomPainter {
  _ReelPainter(
    this.items,
    this.catalog,
    this.art,
    this.position,
    this.cardWidth, {
    this.dim = false,
  }) : super(repaint: position);
  final List<WardrobeItem> items;
  final WardrobeCatalog catalog;
  final RunnerArt? art;
  final ValueListenable<double> position;
  final double cardWidth;
  final bool dim;

  static const _gap = 8.0;
  final _names = <String, TextPainter>{};
  final _bars = <String, Paint>{};
  final _grounds = <String, Paint>{};
  static final _ink = Paint()..color = wardrobeInk;
  static final _antiqueInk = Paint()..color = const Color(0xFF2A2117);
  static final _marker = Paint()
    ..color = const Color(0xFFFFE7A3)
    ..strokeWidth = 3;
  static final _shade = Paint()..color = const Color(0xD0000000);

  TextPainter _name(WardrobeItem item) => _names[item.id] ??= TextPainter(
    text: TextSpan(
      text: item.name,
      style: TextStyle(
        // On the web the bundled font avoids loading fallback fonts.
        fontFamily: kIsWeb ? 'Roboto' : null,
        color: Colors.white,
        fontSize: cardWidth * .11,
        fontWeight: FontWeight.w700,
      ),
    ),
    maxLines: 1,
    ellipsis: '…',
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: cardWidth - 12);

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = cardWidth + _gap, h = cardWidth * 1.25;
    final top = (size.height - h) / 2, center = size.width / 2;
    final p = position.value;
    final first = max(0, (p - center / pitch - 1).floor());
    final last = min(items.length - 1, (p + center / pitch + 1).ceil());
    for (var i = first; i <= last; i++) {
      final item = items[i];
      final left = center + (i - p) * pitch - cardWidth / 2;
      final rect = Rect.fromLTWH(left, top, cardWidth, h);
      final colors = rarityColors(catalog, item);
      final antique = catalog.rarityOf(item).antique;
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));
      canvas.drawRRect(rrect, antique ? _antiqueInk : _ink);
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.translate(left, top);
      final key = colors.map((c) => c.toARGB32()).join(',');
      canvas.drawRect(
        Rect.fromLTWH(0, 0, cardWidth, h),
        _grounds[key] ??= Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, colors.first.withValues(alpha: .38)],
          ).createShader(Rect.fromLTWH(0, 0, cardWidth, h)),
      );
      paintItemArt(
        canvas,
        Rect.fromLTWH(8, 8, cardWidth - 16, h * .66),
        item,
        art,
        antique: antique,
      );
      final name = _name(item);
      name.paint(canvas, Offset(6, h * .72));
      canvas.drawRect(
        Rect.fromLTWH(0, h - 7, cardWidth, 7),
        _bars[key] ??= Paint()
          ..shader = rarityGradient(
            colors,
          ).createShader(Rect.fromLTWH(0, 0, cardWidth, 7)),
      );
      canvas.restore();
    }
    // Edges fade into the dark, so the eye stays on the marker.
    final fade = size.width * .18;
    for (final leftSide in [true, false]) {
      final r = leftSide
          ? Rect.fromLTWH(0, 0, fade, size.height)
          : Rect.fromLTWH(size.width - fade, 0, fade, size.height);
      canvas.drawRect(
        r,
        Paint()
          ..shader = LinearGradient(
            begin: leftSide ? Alignment.centerLeft : Alignment.centerRight,
            end: leftSide ? Alignment.centerRight : Alignment.centerLeft,
            colors: const [Color(0xF2101412), Color(0x00101412)],
          ).createShader(r),
      );
    }
    // Behind the won card the reel only sets the scene: dark enough for the
    // title and rarity in front, and without the marker running through them.
    if (dim) {
      canvas.drawRect(Offset.zero & size, _shade);
      return;
    }
    canvas.drawLine(
      Offset(center, top - 14),
      Offset(center, top + h + 14),
      _marker,
    );
    for (final (y, dir) in [(top - 14, 1.0), (top + h + 14, -1.0)]) {
      canvas.drawPath(
        Path()
          ..moveTo(center - 9, y)
          ..lineTo(center + 9, y)
          ..lineTo(center, y + 11 * dir)
          ..close(),
        _marker,
      );
    }
  }

  @override
  bool shouldRepaint(_ReelPainter old) =>
      old.items != items ||
      old.art != art ||
      old.cardWidth != cardWidth ||
      old.dim != dim;
}

/// The shine behind the won card: turning rays in the rarity colours; the
/// rarest rarity gets more of them and a burst of sparks.
class _GlowPainter extends CustomPainter {
  _GlowPainter(this.colors, this.turn, this.pop, {this.jackpot = false});
  final List<Color> colors;
  final double turn, pop;
  final bool jackpot;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * .42);
    final r =
        size.longestSide * (jackpot ? .75 : .5) * Curves.easeOut.transform(pop);
    if (r <= 0) return;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            colors.first.withValues(alpha: jackpot ? .55 : .4),
            colors.first.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    final rays = jackpot ? 18 : 10;
    for (var i = 0; i < rays; i++) {
      final a = turn * 2 * pi + i * 2 * pi / rays;
      final color = colors[i % colors.length];
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + cos(a - .06) * r, c.dy + sin(a - .06) * r)
        ..lineTo(c.dx + cos(a + .06) * r, c.dy + sin(a + .06) * r)
        ..close();
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: .16));
    }
    if (!jackpot) return;
    // Sparks fly out once and fall.
    final random = Random(7);
    final t = pop;
    for (var i = 0; i < 60; i++) {
      final a = random.nextDouble() * 2 * pi;
      final speed = .25 + random.nextDouble() * .55;
      final d = size.shortestSide * speed * t;
      final p = c + Offset(cos(a) * d, sin(a) * d + 120 * t * t);
      canvas.drawCircle(
        p,
        (2 + random.nextDouble() * 3) * (1 - t * .6),
        Paint()
          ..color = (i.isEven ? colors.first : Colors.white).withValues(
            alpha: 1 - t * .7,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.turn != turn || old.pop != pop || old.colors != colors;
}
