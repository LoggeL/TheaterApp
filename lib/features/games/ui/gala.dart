import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../data/wardrobe_api.dart';
import 'crate_choice.dart';
import 'crate_opening.dart';
import 'ensemble_card.dart' show CurtainPainter;
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';
import 'stage_runner_sound.dart';

/// The Monatsgala (`runnerMonthlyGala`) in the app: the mask of a winner, the
/// "Vitrine" of the own trophies and the celebration when the game opens after
/// a gala. What was won is frozen on the server.

final _number = NumberFormat.decimalPattern('de');

/// "1 Gala-Kiste", "3 Gala-Kisten".
String galaCratesText(int crates) =>
    crates == 1 ? '1 Gala-Kiste' : '$crates Gala-Kisten';

/// "Oktober 2026" from `2026-10`; the plain value if it is none.
String galaMonthText(String month) {
  final parts = month.split('-');
  final year = parts.length == 2 ? int.tryParse(parts[0]) : null;
  final index = parts.length == 2 ? int.tryParse(parts[1]) : null;
  if (year == null || index == null) return month;
  return DateFormat('MMMM y', 'de').format(DateTime(year, index));
}

/// The line under the podium: what the gala brought the member.
String galaPrizeText(GalaOwnPrize? own) {
  if (own == null) {
    return 'Diesmal warst du nicht auf der Liste. Der neue Monat läuft schon.';
  }
  final points = _number.format(own.score);
  return switch (own.prize) {
    'climber' =>
      'Aufsteiger des Monats! Von ${_number.format(own.previous ?? 0)} auf $points Punkte: ${galaCratesText(own.crates)}.',
    'applause' =>
      'Applaus für Platz ${own.rank}! ${_number.format(own.gage)} Gage sind auf deinem Konto.',
    _ =>
      'Platz ${own.rank} mit $points Punkten: ${own.trophy?.title ?? 'Maske'} und ${galaCratesText(own.crates)}.',
  };
}

/// A mask of the Monatsgala: its picture once loaded, until then (or without
/// one) a theatre icon in its colour.
class GalaMask extends StatefulWidget {
  const GalaMask({
    super.key,
    required this.trophy,
    this.path,
    this.controller,
    this.size = 24,
  });
  final GalaTrophy trophy;

  /// The picture; null draws the icon.
  final String? path;
  final AppController? controller;
  final double size;

  @override
  State<GalaMask> createState() => _GalaMaskState();
}

class _GalaMaskState extends State<GalaMask> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(GalaMask old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  void _load() {
    final path = widget.path, controller = widget.controller;
    _image = WardrobePictures.cached(path);
    if (path == null || controller == null || _image != null) return;
    WardrobePictures.loadPortrait(controller, path).then((image) {
      if (mounted && image != null && path == widget.path) {
        setState(() => _image = image);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trophy;
    final image = _image;
    return Tooltip(
      message: t.title,
      child: Semantics(
        label: t.title,
        excludeSemantics: true,
        child: image == null
            ? Icon(
                Icons.theater_comedy,
                key: ValueKey('gala-mask-${t.name}'),
                size: widget.size,
                color: t.color,
              )
            : RawImage(
                key: ValueKey('gala-mask-${t.name}'),
                image: image,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
      ),
    );
  }
}

/// The own trophies ("Vitrine") and the Gala-Kisten waiting, in the wardrobe.
class GalaVitrineCard extends StatelessWidget {
  const GalaVitrineCard({
    super.key,
    required this.gala,
    required this.controller,
    this.art,
    this.onOpen,
    this.showCrates = true,
  });
  final GalaState gala;
  final AppController controller;
  final RunnerArt? art;

  /// Opens a Gala-Kiste; null while something else runs.
  final VoidCallback? onOpen;

  /// Whether the waiting Gala-Kisten show here; the wardrobe opens them
  /// with all other crates instead.
  final bool showCrates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crate = gala.crate;
    return Card(
      key: const ValueKey('runner-gala-vitrine'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Vitrine', style: theme.textTheme.titleMedium),
            Text(
              gala.trophies.isEmpty
                  ? 'Hier stehen deine Masken der Monatsgala.'
                  : 'Deine Masken der Monatsgala.',
              style: theme.textTheme.bodySmall,
            ),
            if (gala.trophies.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  for (final won in gala.trophies)
                    SizedBox(
                      width: 92,
                      child: Column(
                        key: ValueKey('gala-trophy-${won.month}'),
                        children: [
                          GalaMask(
                            trophy: won.trophy,
                            path: gala.masks[won.trophy],
                            controller: controller,
                            size: 52,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            galaMonthText(won.month),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            if (showCrates && gala.crates > 0 && crate != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  SizedBox(
                    width: 64,
                    height: 48,
                    child: CratePicture(
                      target: crate,
                      controller: controller,
                      art: art,
                      crop: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${galaCratesText(gala.crates)} bereit',
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          '${crateTargetSubtitle(crate)} · Glanz ${crateChanceText(crate.shinyChance)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    key: const ValueKey('gala-open'),
                    onPressed: onOpen,
                    child: const Text('Öffnen'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The celebration of a Monatsgala, shown once when the game opens after it:
/// the curtain opens on the podium, below it what the member won. Pops `true`
/// to open a Gala-Kiste right away.
class GalaCelebration extends StatefulWidget {
  const GalaCelebration({
    super.key,
    required this.gala,
    required this.state,
    required this.controller,
  });
  final MonthlyGala gala;
  final GalaState state;
  final AppController controller;

  @override
  State<GalaCelebration> createState() => _GalaCelebrationState();
}

class _GalaCelebrationState extends State<GalaCelebration>
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

  /// The classic order: silver left, gold in the middle, bronze right. A
  /// place nobody holds (two share gold) stays out.
  List<Widget> _pedestals(BuildContext context) => [
    for (final (trophy, height) in const [
      (GalaTrophy.silver, 54.0),
      (GalaTrophy.gold, 76.0),
      (GalaTrophy.bronze, 36.0),
    ])
      if (widget.gala.podium.where((e) => e.trophy == trophy).toList()
          case final entries when entries.isNotEmpty)
        Expanded(
          child: _Pedestal(
            key: ValueKey('gala-podium-${trophy.name}'),
            trophy: trophy,
            entries: entries,
            height: height,
            state: widget.state,
            controller: widget.controller,
          ),
        ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gala = widget.gala;
    final crates = widget.state.crates;
    return Dialog(
      key: const ValueKey('gala-celebration'),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _burst,
                builder: (context, _) =>
                    CustomPaint(painter: _GoldBurstPainter(_burst.value)),
              ),
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Der Vorhang hebt sich',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: StageTheme.orange,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Gala des Monats ${gala.monthName}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: _pedestals(context),
                        ),
                      ),
                      // The curtain opens on the podium.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _burst,
                            builder: (context, _) => CustomPaint(
                              painter: CurtainPainter(
                                open: Curves.easeInOut.transform(
                                  (_burst.value / .6).clamp(0.0, 1.0),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  galaPrizeText(gala.own),
                  key: const ValueKey('gala-own-prize'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (crates > 0)
                      FilledButton.icon(
                        key: const ValueKey('gala-celebration-open'),
                        onPressed: () => Navigator.pop(context, true),
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Kiste öffnen'),
                      ),
                    TextButton(
                      key: const ValueKey('gala-celebration-close'),
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

/// One step of the podium: the mask, who stands on it (all of a shared rank)
/// and the step itself.
class _Pedestal extends StatelessWidget {
  const _Pedestal({
    super.key,
    required this.trophy,
    required this.entries,
    required this.height,
    required this.state,
    required this.controller,
  });
  final GalaTrophy trophy;
  final List<GalaPodiumEntry> entries;
  final double height;
  final GalaState state;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GalaMask(
            trophy: trophy,
            path: state.masks[trophy],
            controller: controller,
            size: 44,
          ),
          const SizedBox(height: 4),
          for (final e in entries)
            Text(
              e.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: e.me ? theme.colorScheme.primary : null,
              ),
            ),
          Text(
            _number.format(entries.first.score),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Container(
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: trophy.color.withValues(alpha: .85),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Text(
              '${entries.first.rank}',
              style: theme.textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Golden glints flying out of the middle once.
class _GoldBurstPainter extends CustomPainter {
  _GoldBurstPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final c = Offset(size.width / 2, size.height * .2);
    final random = Random(9);
    final paint = Paint();
    const colors = [Color(0xFFFFD86B), Color(0xFFE4AE39), Color(0xFFFFFFFF)];
    for (var i = 0; i < 40; i++) {
      final a = random.nextDouble() * 2 * pi;
      final d = size.shortestSide * (.2 + random.nextDouble() * .6) * t;
      paint.color = colors[i % colors.length].withValues(alpha: (1 - t) * .9);
      paintGlint(
        canvas,
        c + Offset(cos(a) * d, sin(a) * d + 80 * t * t),
        3 + random.nextDouble() * 6,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_GoldBurstPainter old) => old.t != t;
}

/// The celebration, if the gala's month was not shown yet; once, as the
/// server remembers. A failed request leaves it for the next time the game
/// opens. [onChanged] gets the wardrobe after it.
Future<void> celebrateGala(
  BuildContext context, {
  required AppController controller,
  required Wardrobe wardrobe,
  required RunnerSound sound,
  required ValueChanged<Wardrobe> onChanged,
}) async {
  final month = wardrobe.gala.unseen;
  if (month == null || !monthlyGalaAvailable(controller)) return;
  final gala = await loadGala(controller);
  if (gala == null || gala.month != month || !context.mounted) return;
  sound.play(RunnerSfx.jackpot);
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => GalaCelebration(
      gala: gala,
      state: wardrobe.gala,
      controller: controller,
    ),
  );
  final seen = await markGalaSeen(controller, month);
  onChanged(seen);
  if (open != true || !context.mounted) return;
  final next = await showCrateOpening(
    context,
    controller: controller,
    wardrobe: seen,
    sound: sound,
    art: RunnerArt.loaded,
    gala: true,
  );
  if (next != null) onChanged(next);
}
