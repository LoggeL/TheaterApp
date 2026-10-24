import 'dart:math';

import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../data/wardrobe_api.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart' show paintGlint, shineColors;
import 'wardrobe_cards.dart';

/// "Ensemble-Strecke": the metres of all players together, the way to the
/// next milestone and what it unlocks for everybody.
class EnsembleCard extends StatelessWidget {
  const EnsembleCard({
    super.key,
    required this.wardrobe,
    required this.controller,
    this.art,
    this.onOpen,
    this.onReward,
  });
  final Wardrobe wardrobe;
  final AppController controller;
  final RunnerArt? art;

  /// Opens an Ensemble-Kiste.
  final VoidCallback? onOpen;

  /// Shows a reward's card.
  final ValueChanged<WardrobeItem>? onReward;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = wardrobe.ensemble!;
    final next = e.next;
    final reward = next.rewardId == null
        ? null
        : wardrobe.catalog.item(next.rewardId!);
    return Card(
      key: const ValueKey('ensemble-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.groups, color: StageTheme.orange, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Ensemble-Strecke',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  kmText(e.meters),
                  key: const ValueKey('ensemble-total'),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Alle Läufe aller Spieler zählen zusammen.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: LinearProgressIndicator(
                value: e.fraction,
                minHeight: 18,
                color: StageTheme.orange,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  kmText((e.previousKm * 1000).round()),
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                Text(kmText(next.meters), style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'noch ${kmText(e.remaining)} bis ${next.name}',
              key: const ValueKey('ensemble-next'),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (reward != null)
                  SizedBox(
                    width: 72,
                    height: 92,
                    child: WardrobeCard(
                      item: reward,
                      wardrobe: wardrobe,
                      controller: controller,
                      art: art,
                      onTap: onReward == null ? null : () => onReward!(reward),
                    ),
                  )
                else
                  const SizedBox(
                    width: 72,
                    height: 72,
                    child: Icon(
                      Icons.inventory_2,
                      size: 48,
                      color: Color(0xFFB07A45),
                    ),
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bei ${kmText(next.meters)} für alle:',
                        style: theme.textTheme.labelLarge,
                      ),
                      Text(
                        reward == null
                            ? '1 Ensemble-Kiste für jede:n'
                            : '${reward.kind.singular} „${reward.name}“ + 1 Ensemble-Kiste für jede:n',
                      ),
                      if (next.note != null)
                        Text(
                          next.note!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: StageTheme.orange,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (reward != null && !next.ready)
                        Text(
                          'Belohnung wird vorbereitet',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              e.sectionOwn > 0
                  ? 'Dein Beitrag in diesem Abschnitt: ${kmText(e.sectionOwn)} · ${_players(e.sectionPlayers)}'
                  : e.sectionPlayers == 0
                  ? 'Neuer Abschnitt – lauf als Erste:r los!'
                  : 'In diesem Abschnitt: ${_players(e.sectionPlayers)} – lauf mit!',
              key: const ValueKey('ensemble-section'),
              style: theme.textTheme.bodySmall,
            ),
            if (e.crates > 0) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const ValueKey('ensemble-open'),
                onPressed: onOpen,
                icon: const Icon(Icons.auto_awesome),
                label: Text(
                  e.crates == 1
                      ? 'Ensemble-Kiste öffnen'
                      : 'Ensemble-Kiste öffnen (${e.crates})',
                ),
              ),
            ],
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                // Its own PageStorageKey: without one the tile stores its
                // open state (a bool) under the id of the wardrobe's
                // scroll view, which keeps its offset (a double) there; back
                // from the Statistik tab either read failed and the card
                // turned into an error box (a white block in release).
                key: const PageStorageKey('ensemble-goals'),
                tilePadding: EdgeInsets.zero,
                title: const Text('Alle Ziele'),
                children: [
                  for (final m in e.milestones)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        m.reached ? Icons.check_circle : Icons.flag_outlined,
                        color: m.reached ? StageTheme.green : null,
                      ),
                      title: Text('${kmText(m.meters)} · ${m.name}'),
                      subtitle: m.note != null
                          ? Text(m.note!)
                          : m.reached && m.rewardId != null && !m.ready
                          ? const Text('Belohnung wird vorbereitet')
                          : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _players(int n) =>
      n == 1 ? '1 Mitspieler:in' : '$n Mitspielende';
}

/// The celebration of reached milestones, shown once when the wardrobe opens
/// after them. Pops `true` to open an Ensemble-Kiste right away.
class EnsembleCelebration extends StatefulWidget {
  const EnsembleCelebration({
    super.key,
    required this.reached,
    required this.wardrobe,
    required this.controller,
    this.art,
  });
  final List<EnsembleMilestone> reached;
  final Wardrobe wardrobe;
  final AppController controller;
  final RunnerArt? art;

  @override
  State<EnsembleCelebration> createState() => _EnsembleCelebrationState();
}

class _EnsembleCelebrationState extends State<EnsembleCelebration>
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
    final last = widget.reached.isEmpty ? null : widget.reached.last;
    final crates = widget.wardrobe.ensemble?.crates ?? 0;
    final rewards = [
      for (final m in widget.reached)
        if (m.rewardId != null)
          if (widget.wardrobe.catalog.item(m.rewardId!) case final item?)
            (m, item),
    ];
    return Dialog(
      key: const ValueKey('ensemble-celebration'),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _burst,
                builder: (context, _) =>
                    CustomPaint(painter: _BurstPainter(_burst.value)),
              ),
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.celebration,
                  size: 56,
                  color: StageTheme.orange,
                ),
                const SizedBox(height: 8),
                Text(
                  'Ensemble-Ziel erreicht!',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (last != null)
                  Text(
                    'Gemeinsam ${kmText(last.meters)} gelaufen',
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 16),
                if (rewards.isNotEmpty)
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final (m, item) in rewards)
                        Column(
                          children: [
                            SizedBox(
                              width: 96,
                              height: 120,
                              child: WardrobeCard(
                                item: item,
                                wardrobe: widget.wardrobe,
                                controller: widget.controller,
                                art: widget.art,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              m.ready
                                  ? 'Für alle freigeschaltet'
                                  : 'Belohnung wird vorbereitet',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                Text(
                  crates == 1
                      ? 'Für dich wartet 1 Ensemble-Kiste.'
                      : 'Für dich warten $crates Ensemble-Kisten.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (crates > 0)
                      FilledButton.icon(
                        key: const ValueKey('celebration-open'),
                        onPressed: () => Navigator.pop(context, true),
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Kiste öffnen'),
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

/// Glints flying out of the middle once.
class _BurstPainter extends CustomPainter {
  _BurstPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final c = Offset(size.width / 2, size.height * .2);
    final random = Random(5);
    final paint = Paint();
    for (var i = 0; i < 40; i++) {
      final a = random.nextDouble() * 2 * pi;
      final d = size.shortestSide * (.2 + random.nextDouble() * .6) * t;
      paint.color = shineColors[i % shineColors.length].withValues(
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
  bool shouldRepaint(_BurstPainter old) => old.t != t;
}
