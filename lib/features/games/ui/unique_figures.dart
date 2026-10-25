import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../data/wardrobe_api.dart';
import 'ensemble_card.dart' show CurtainPainter;
import 'stage_runner_art.dart';
import 'stage_runner_look.dart' show paintGlint;
import 'wardrobe_cards.dart';

/// The cards of the unique figures (`runnerUniqueFigures`), one per play in
/// the server's order: an unlocked one as itself, the others as a hidden
/// stand-in ("???", silhouette, the play's progress). Empty without them.
List<WardrobeItem> uniqueCards(Wardrobe w) => [
  for (final p in w.uniqueFigures?.plays ?? const <UniqueFigureProgress>[])
    if (p.unlocked && p.itemId != null && w.catalog.item(p.itemId!) != null)
      w.catalog.item(p.itemId!)!
    else
      uniqueStandIn(w.catalog, p),
];

/// The celebration of newly unlocked unique figures, like the one of an
/// ensemble goal: glints, the curtain opens on the card. Pops `true` to wear
/// the (last) figure.
class UniqueCelebration extends StatefulWidget {
  const UniqueCelebration({
    super.key,
    required this.items,
    required this.wardrobe,
    required this.controller,
    this.art,
  });
  final List<WardrobeItem> items;
  final Wardrobe wardrobe;
  final AppController controller;
  final RunnerArt? art;

  @override
  State<UniqueCelebration> createState() => _UniqueCelebrationState();
}

class _UniqueCelebrationState extends State<UniqueCelebration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..forward();

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plays = widget.wardrobe.uniqueFigures?.plays ?? const [];
    UniqueFigureProgress? progressOf(WardrobeItem item) =>
        plays.where((p) => p.itemId == item.id).firstOrNull;
    return Dialog(
      key: const ValueKey('unique-celebration'),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _burst,
                builder: (context, _) =>
                    CustomPaint(painter: _HoloBurstPainter(_burst.value)),
              ),
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.auto_awesome,
                  size: 56,
                  color: Color(0xFFB388FF),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.items.length == 1
                      ? 'Unique-Figur freigeschaltet!'
                      : 'Unique-Figuren freigeschaltet!',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final item in widget.items)
                      SizedBox(
                        width: 200,
                        child: Column(
                          children: [
                            SizedBox(
                              width: 96,
                              height: 130,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    WardrobeCard(
                                      item: item,
                                      wardrobe: widget.wardrobe,
                                      controller: widget.controller,
                                      art: widget.art,
                                      animateShine: true,
                                    ),
                                    // The curtain opens on what was a
                                    // secret until now.
                                    IgnorePointer(
                                      child: AnimatedBuilder(
                                        animation: _burst,
                                        builder: (context, _) => CustomPaint(
                                          painter: CurtainPainter(
                                            open: Curves.easeInOut.transform(
                                              (_burst.value / .6).clamp(
                                                0.0,
                                                1.0,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              item.name,
                              key: ValueKey('unique-unlocked-${item.id}'),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              switch (progressOf(item)) {
                                final p? when p.allCharacters =>
                                  'Alle ${p.total} Figuren einschließlich Technik gesammelt',
                                final p? =>
                                  'Alle ${p.total} Rollen aus ${p.play} gesammelt',
                                null => 'Alle Rollen des Stücks gesammelt',
                              },
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Sie gehört jetzt dir: kein Glanz nötig, sie ist einzigartig.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('unique-wear'),
                      onPressed: () => Navigator.pop(context, true),
                      icon: const Icon(Icons.checkroom),
                      label: const Text('Anlegen'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Weiter'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Rainbow glints flying out of the middle once.
class _HoloBurstPainter extends CustomPainter {
  _HoloBurstPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final c = Offset(size.width / 2, size.height * .2);
    final random = Random(7);
    final paint = Paint();
    for (var i = 0; i < 44; i++) {
      final a = random.nextDouble() * 2 * pi;
      final d = size.shortestSide * (.2 + random.nextDouble() * .6) * t;
      paint.color = holoColors[i % holoColors.length].withValues(
        alpha: (1 - t) * .9,
      );
      paintGlint(
        canvas,
        c + Offset(cos(a) * d, sin(a) * d + 80 * t * t),
        3 + random.nextDouble() * 6,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HoloBurstPainter old) => old.t != t;
}
