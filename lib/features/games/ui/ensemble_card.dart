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
              next.hidden
                  ? 'noch ${kmText(e.remaining)} bis zur nächsten Überraschung'
                  : 'noch ${kmText(e.remaining)} bis ${next.name}',
              key: const ValueKey('ensemble-next'),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (next.hidden)
                  const EnsembleSurprise(width: 72, height: 92)
                else if (reward != null)
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
                        next.hidden
                            ? 'Eine Überraschung + 1 Ensemble-Kiste für jede:n'
                            : reward == null
                            ? '1 Ensemble-Kiste für jede:n'
                            : '${reward.kind.singular} „${reward.name}“ + 1 Ensemble-Kiste für jede:n',
                        key: const ValueKey('ensemble-next-reward'),
                      ),
                      if (next.hidden)
                        Text(
                          'Was es ist, zeigt sich erst, wenn ihr dort seid.',
                          style: theme.textTheme.bodySmall,
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
                      key: ValueKey('ensemble-goal-${m.km}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        m.reached
                            ? Icons.check_circle
                            : m.hidden
                            ? Icons.help_outline
                            : Icons.flag_outlined,
                        color: m.reached ? StageTheme.green : null,
                      ),
                      title: Text('${kmText(m.meters)} · ${m.name}'),
                      subtitle: _goalNote(m) == null
                          ? null
                          : Text(_goalNote(m)!),
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

  /// The line under a goal: a surprise, what it unlocked, or its note.
  String? _goalNote(EnsembleMilestone m) {
    if (m.hidden) {
      return m.reached
          ? 'Ziel erreicht · Überraschung wird später freigeschaltet'
          : 'Überraschung + Ensemble-Kiste';
    }
    final unlocked = m.rewardId == null
        ? null
        : wardrobe.catalog.item(m.rewardId!);
    final kind = unlocked?.kind ?? m.rewardKind;
    return [
      ?m.note,
      if (m.reached && m.rewardId != null)
        m.ready
            ? kind == null
                  ? 'Für alle freigeschaltet'
                  : '${kind.singular} · für alle freigeschaltet'
            : 'Belohnung wird vorbereitet',
    ].join(' · ').nullIfEmpty;
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// The Ensemble-Strecke in a few lines for the Bühnenlauf menu: all metres
/// together, the bar to the next goal and what it brings. A run's reply
/// ([run]) is newer than the wardrobe's [ensemble] and wins. The full card
/// with every goal lives in the wardrobe ([onOpen]).
class EnsembleStrip extends StatelessWidget {
  const EnsembleStrip({
    super.key,
    required this.ensemble,
    this.run,
    this.onOpen,
  });
  final EnsembleProgress ensemble;
  final EnsembleRun? run;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = ensemble;
    final meters = run?.meters ?? e.meters;
    final next = run?.next ?? e.next;
    // The goal before the next one: where the bar starts.
    final from = next.km == e.next.km
        ? (e.previousKm * 1000).round()
        : e.milestones
              .where((m) => m.km < next.km)
              .map((m) => m.meters)
              .fold(0, max);
    final to = next.meters;
    final fraction = to <= from
        ? 1.0
        : ((meters - from) / (to - from)).clamp(0, 1).toDouble();
    final remaining = max(0, to - meters);
    final crates = e.crates;
    return Card(
      key: const ValueKey('ensemble-strip'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.groups, color: StageTheme.orange),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Ensemble-Strecke',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    kmText(meters),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (onOpen != null) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right, color: theme.hintColor),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 10,
                  color: StageTheme.orange,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                next.hidden
                    ? 'Nächstes Ziel: noch ${kmText(remaining)} bis zur nächsten Überraschung'
                    : 'Nächstes Ziel: noch ${kmText(remaining)} bis ${next.name}',
                key: const ValueKey('ensemble-strip-next'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                crates > 0
                    ? crates == 1
                          ? '1 Ensemble-Kiste wartet in der Garderobe.'
                          : '$crates Ensemble-Kisten warten in der Garderobe.'
                    : 'Bei ${kmText(to)} gibt es eine Ensemble-Kiste für alle.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: crates > 0 ? StageTheme.orange : null,
                  fontWeight: crates > 0 ? FontWeight.w700 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A reward that is still a surprise: a closed curtain with a question
/// mark, never its name or picture.
class EnsembleSurprise extends StatelessWidget {
  const EnsembleSurprise({super.key, this.width = 72, this.height = 92});
  final double width, height;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Überraschung, noch verborgen',
    child: SizedBox(
      key: const ValueKey('ensemble-surprise'),
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CustomPaint(
          painter: const CurtainPainter(),
          child: Center(
            child: Text(
              '?',
              style: TextStyle(
                color: const Color(0xFFFFE7A3),
                fontSize: height * .38,
                fontWeight: FontWeight.w900,
                shadows: const [Shadow(blurRadius: 6, color: Colors.black54)],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A stage curtain in folds; [open] from 0 (closed) to 1 pulls both halves
/// aside, for the reveal.
class CurtainPainter extends CustomPainter {
  const CurtainPainter({this.open = 0});
  final double open;

  static const _deep = Color(0xFF5A0F18), _light = Color(0xFFB3263A);

  @override
  void paint(Canvas canvas, Size size) {
    if (open >= 1) return;
    final half = size.width / 2, shift = half * open;
    for (final (left, from) in [(true, -shift), (false, half + shift)]) {
      final rect = Rect.fromLTWH(from, 0, half, size.height);
      canvas.save();
      canvas.clipRect(rect);
      // Folds: light and dark stripes across each half.
      const folds = 3;
      final fold = half / folds;
      for (var i = 0; i < folds; i++) {
        final r = Rect.fromLTWH(from + i * fold, 0, fold, size.height);
        canvas.drawRect(
          r,
          Paint()
            ..shader = const LinearGradient(
              colors: [_deep, _light, _deep],
            ).createShader(r),
        );
      }
      // Darker towards the middle, where the halves meet.
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: left ? Alignment.centerLeft : Alignment.centerRight,
            end: left ? Alignment.centerRight : Alignment.centerLeft,
            colors: const [Color(0x00000000), Color(0x55000000)],
          ).createShader(rect),
      );
      canvas.restore();
    }
    // The gold fringe on top.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * .07),
      Paint()..color = const Color(0xFFE4AE39),
    );
  }

  @override
  bool shouldRepaint(CurtainPainter old) => old.open != open;
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
                        SizedBox(
                          width: 200,
                          child: Column(
                            children: [
                              SizedBox(
                                width: 96,
                                height: 120,
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
                                      ),
                                      // The curtain opens on what was a
                                      // surprise until now.
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
                                'Freigeschaltet: ${item.kind.singular} „${item.name}“',
                                key: ValueKey('ensemble-unlocked-${m.km}'),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                m.ready
                                    ? 'Für alle in der Garderobe'
                                    : 'Belohnung wird vorbereitet',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
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
