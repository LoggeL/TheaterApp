import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../data/wardrobe_api.dart';
import '../domain/stage_runner.dart';
import 'crate_animation.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';
import 'wardrobe_cards.dart';

/// Asks which crate a crate of the own runs should be (`runnerCrateTargets`):
/// the Zufallskiste, a play or the Technik-Kiste. Null if dismissed.
Future<CrateTarget?> chooseCrateTarget(
  BuildContext context, {
  required AppController controller,
  required Wardrobe wardrobe,
  RunnerArt? art,
}) => showModalBottomSheet<CrateTarget>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) =>
      CrateChoiceSheet(controller: controller, wardrobe: wardrobe, art: art),
);

final _percentFormat = NumberFormat('0.#', 'de');

/// "3 %", "1,5 %".
String crateChanceText(double share) =>
    '${_percentFormat.format(share * 100)} %';

/// "15/28" with "komplett" or the locked ones: a target's pool.
String crateTargetProgress(CrateTarget t) => [
  '${t.owned}/${t.total}',
  if (t.complete) 'komplett' else if (t.locked > 0) '${t.locked} gesperrt',
].join(' · ');

/// What a target holds, under its name.
String crateTargetSubtitle(CrateTarget t) => switch (t.kind) {
  CrateTargetKind.random =>
    'Alles aus dem Fundus, auch Bühnenbilder und Effekte',
  CrateTargetKind.tech => 'Nur die Technik',
  CrateTargetKind.play => 'Nur Rollen aus ${t.title}',
};

/// The choice: one card per target, the Zufallskiste first, with picture,
/// progress, the chances of the rarities within it and its shine chance.
class CrateChoiceSheet extends StatelessWidget {
  const CrateChoiceSheet({
    super.key,
    required this.controller,
    required this.wardrobe,
    this.art,
  });
  final AppController controller;
  final Wardrobe wardrobe;
  final RunnerArt? art;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targets = wardrobe.crateTargets;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Welche Kiste?', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Gezielt kommen nur Figuren aus einem Stück oder der Technik – so wird ein Set schneller voll. Die Zufallskiste hat alles aus dem Fundus und glänzt öfter.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, box) {
                  const gap = 10.0;
                  final columns = max(2, (box.maxWidth / 190).floor());
                  final width = (box.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final t in targets)
                        SizedBox(
                          width: width,
                          child: CrateTargetCard(
                            key: ValueKey('crate-target-${t.id}'),
                            target: t,
                            wardrobe: wardrobe,
                            controller: controller,
                            art: art,
                            onTap: t.available
                                ? () => Navigator.pop(context, t)
                                : null,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One target: its crate, name, what it holds and how far its set is.
class CrateTargetCard extends StatelessWidget {
  const CrateTargetCard({
    super.key,
    required this.target,
    required this.wardrobe,
    required this.controller,
    this.art,
    this.onTap,
  });
  final CrateTarget target;
  final Wardrobe wardrobe;
  final AppController controller;
  final RunnerArt? art;
  final VoidCallback? onTap;

  /// What keeps a locked target closed, e.g. "Sammle 10 hellblaue Figuren".
  String _lockHint() =>
      wardrobe.catalog.rarities
          .where((r) => wardrobe.lockedRarities.contains(r.id))
          .map((r) => r.hint)
          .nonNulls
          .firstOrNull ??
      'Noch gesperrt';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = target;
    final accent = CrateMotion.of(t.animation).accent;
    final rarities = {for (final r in wardrobe.catalog.rarities) r.id: r};
    return Opacity(
      opacity: t.available ? 1 : .55,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: t.isRandom ? accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CratePicture(
                          target: t,
                          controller: controller,
                          art: art,
                          crop: true,
                        ),
                      ),
                      if (t.isRandom)
                        Positioned(
                          left: 4,
                          top: 4,
                          child: _Badge(
                            icon: Icons.auto_awesome,
                            text: 'mehr Glanz',
                            color: accent,
                          ),
                        )
                      else if (t.complete)
                        Positioned(
                          left: 4,
                          top: 4,
                          child: _Badge(
                            key: ValueKey('crate-target-complete-${t.id}'),
                            icon: Icons.check_circle,
                            text: 'komplett',
                            color: const Color(0xFF2FBF71),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  crateTargetSubtitle(t),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                if (t.odds.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 5,
                      // Stretched: a ColoredBox without a child is
                      // only as high as it must be, i.e. not at all.
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (id, chance) in t.odds)
                            Expanded(
                              flex: max(1, (chance * 1000).round()),
                              child: ColoredBox(
                                color:
                                    rarities[id]?.color ??
                                    WardrobeRarity.unknown.color,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  t.available
                      ? '${crateTargetProgress(t)} · Glanz ${crateChanceText(t.shinyChance)}'
                      : _lockHint(),
                  key: ValueKey('crate-target-progress-${t.id}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (t.complete && t.available)
                  Text(
                    'Bringt jetzt Glanz oder Gage.',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
  });
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .65),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: .8)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

/// The closed crate of [target]: its own picture (`crate-<x>.webp`) once
/// loaded, until then (or without one) the stage's props crate with the
/// target's mark.
class CratePicture extends StatefulWidget {
  const CratePicture({
    super.key,
    required this.target,
    required this.controller,
    this.art,
    this.open = false,
    this.crop = false,
  });
  final CrateTarget target;
  final AppController controller;
  final RunnerArt? art;

  /// The open crate (`crate-<x>-open.webp`) instead.
  final bool open;

  /// Just the crate ([CrateTarget.imageBox]), without the room above it
  /// that the canvas keeps for the open lid: for the choice's cards.
  final bool crop;

  @override
  State<CratePicture> createState() => _CratePictureState();
}

class _CratePictureState extends State<CratePicture> {
  ui.Image? _image;

  String? get _path =>
      widget.open ? widget.target.openImage : widget.target.image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CratePicture old) {
    super.didUpdateWidget(old);
    if (old.target.image != widget.target.image ||
        old.target.openImage != widget.target.openImage ||
        old.open != widget.open) {
      _load();
    }
  }

  void _load() {
    final path = _path;
    _image = WardrobePictures.cached(path);
    if (path == null || _image != null) return;
    WardrobePictures.loadPortrait(widget.controller, path).then((image) {
      if (mounted && image != null && path == _path) {
        setState(() => _image = image);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return CrateFallback(target: widget.target, art: widget.art);
    }
    final box = widget.crop && !widget.open ? widget.target.imageBox : null;
    if (box == null) {
      return RawImage(
        image: image,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    }
    return CustomPaint(
      key: ValueKey('crate-picture-crop-${widget.target.id}'),
      painter: _CropPainter(image, box),
      size: Size.infinite,
    );
  }
}

/// [box] of a picture whose canvas is 512² (the server's pictures; a picture
/// decoded smaller scales the box along), centred and contained, with a
/// little margin.
class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.box);
  final ui.Image image;
  final Rect box;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = image.width / 512;
    final margin = box.width * .04;
    final src = Rect.fromLTRB(
      max(0, box.left - margin) * scale,
      max(0, box.top - margin) * scale,
      min(512, box.right + margin) * scale,
      min(512, box.bottom + margin) * scale,
    );
    final fitted = applyBoxFit(BoxFit.contain, src.size, size);
    final dst = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.image != image || old.box != box;
}

/// Until a crate has its own picture: the props crate of the stage with a
/// mark in the target's colour (a die, a spanner, a mask).
class CrateFallback extends StatelessWidget {
  const CrateFallback({super.key, required this.target, this.art});
  final CrateTarget target;
  final RunnerArt? art;

  @override
  Widget build(BuildContext context) {
    final accent = CrateMotion.of(target.animation).accent;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: RadialGradient(
                colors: [accent.withValues(alpha: .35), wardrobeInk],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: ObstacleIcon(ObstacleKind.crate, art: art),
          ),
        ),
        Positioned(
          right: 6,
          bottom: 6,
          child: CircleAvatar(
            radius: 13,
            backgroundColor: accent,
            child: Icon(
              switch (target.kind) {
                CrateTargetKind.random => Icons.casino_outlined,
                CrateTargetKind.tech => Icons.build_outlined,
                CrateTargetKind.play => Icons.theater_comedy_outlined,
              },
              size: 16,
              color: Colors.black87,
            ),
          ),
        ),
      ],
    );
  }
}
