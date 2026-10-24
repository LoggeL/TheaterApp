import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../data/wardrobe_api.dart';
import '../domain/stage_runner.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';

/// Dark card ground, like the stage.
const wardrobeInk = Color(0xFF151A17);

/// The rarity colours of [item], rarest first; a hybrid has several.
List<Color> rarityColors(WardrobeCatalog catalog, WardrobeItem item) {
  final colors = [for (final r in catalog.raritiesOf(item)) r.color];
  return colors.isEmpty ? [catalog.rarityOf(item).color] : colors;
}

/// A bar in the rarity colours; a hybrid's colours side by side with a short
/// blend in between.
Gradient rarityGradient(List<Color> colors) {
  if (colors.length == 1) {
    return LinearGradient(colors: [colors.first, colors.first]);
  }
  final stops = <double>[], all = <Color>[];
  for (final (i, c) in colors.indexed) {
    final from = i / colors.length, to = (i + 1) / colors.length;
    all
      ..add(c)
      ..add(c);
    stops
      ..add(i == 0 ? 0 : from + .04)
      ..add(i == colors.length - 1 ? 1 : to - .04);
  }
  return LinearGradient(colors: all, stops: stops);
}

IconData departmentIcon(String? icon) => switch (icon) {
  'light' => Icons.lightbulb_outline,
  'sound' => Icons.graphic_eq,
  'stage' => Icons.handyman_outlined,
  'video' => Icons.videocam_outlined,
  'costume' => Icons.checkroom_outlined,
  'photo' => Icons.photo_camera_outlined,
  'web' => Icons.language,
  'makeup' => Icons.face_retouching_natural,
  'props' => Icons.category_outlined,
  'direction' => Icons.movie_creation_outlined,
  _ => Icons.build_outlined,
};

IconData kindIcon(WardrobeKind kind) => switch (kind) {
  WardrobeKind.character => Icons.person_outline,
  WardrobeKind.backdrop => Icons.landscape_outlined,
  WardrobeKind.obstacles => Icons.inventory_2_outlined,
  WardrobeKind.fx => Icons.auto_awesome_outlined,
};

final _silhouette = ColorFilter.mode(const Color(0xFF39413B), BlendMode.srcIn);

/// Draws the picture of [item] into [rect]: its portrait if loaded, else
/// the cheer pose (or crate and lamp) of its own atlas, else the default art
/// in the item's tint (stand-ins). [hidden] shows only a
/// silhouette, for items not found yet.
void paintItemArt(
  Canvas canvas,
  Rect rect,
  WardrobeItem item,
  RunnerArt? base, {
  bool hidden = false,
  bool antique = false,
}) {
  final paint = Paint()
    ..filterQuality = FilterQuality.medium
    ..colorFilter = hidden
        ? _silhouette
        : antique
        ? antiqueFilter
        : tintFilter(item.tint);
  void fit(ui.Image image, Rect src, Rect into, {bool cover = false}) {
    final scale = cover
        ? max(into.width / src.width, into.height / src.height)
        : min(into.width / src.width, into.height / src.height);
    final dst = Rect.fromCenter(
      center: into.center,
      width: src.width * scale,
      height: src.height * scale,
    );
    canvas.drawImageRect(image, src, dst, paint);
  }

  final preview = WardrobePictures.cached(item.portrait);
  if (preview != null) {
    canvas.save();
    canvas.clipRect(rect);
    fit(
      preview,
      Rect.fromLTWH(0, 0, preview.width.toDouble(), preview.height.toDouble()),
      rect,
      cover: item.kind == WardrobeKind.backdrop,
    );
    canvas.restore();
    return;
  }
  final own = WardrobePictures.cached(item.image);
  final atlas =
      own != null &&
          base != null &&
          own.width == base.atlas.width &&
          own.height == base.atlas.height
      ? own
      : base?.atlas;
  switch (item.kind) {
    case WardrobeKind.character when atlas != null:
      fit(
        atlas,
        RunnerSprite.cheer.rect,
        rect.deflate(rect.shortestSide * .06),
      );
    case WardrobeKind.backdrop when base != null:
      final image = own ?? base.backdrop;
      canvas.save();
      canvas.clipRect(rect);
      fit(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        rect,
        cover: true,
      );
      canvas.restore();
    case WardrobeKind.obstacles when atlas != null:
      final r = rect.deflate(rect.shortestSide * .08);
      fit(
        atlas,
        RunnerSprite.lamp.rect,
        Rect.fromLTWH(
          r.left + r.width * .5,
          r.top,
          r.width * .5,
          r.height * .55,
        ),
      );
      fit(
        atlas,
        RunnerSprite.crate.rect,
        Rect.fromLTWH(
          r.left,
          r.top + r.height * .4,
          r.width * .6,
          r.height * .6,
        ),
      );
    case WardrobeKind.fx:
      final colors = hidden
          ? const [Color(0xFF39413B)]
          : item.effect?.colors ?? const <Color>[];
      if (colors.isEmpty) {
        // "Ohne Effekt": a plain dash.
        canvas.drawLine(
          rect.center - Offset(rect.width * .18, 0),
          rect.center + Offset(rect.width * .18, 0),
          Paint()
            ..color = const Color(0x66FFFFFF)
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
        return;
      }
      // A trail across the card, thinning out to the left.
      final random = Random(item.id.hashCode);
      for (var i = 0; i < 26; i++) {
        final u = i / 25;
        final p = Offset(
          rect.left + rect.width * (.12 + .76 * u),
          rect.center.dy +
              sin(u * pi * 1.4) * rect.height * .18 +
              (random.nextDouble() - .5) * rect.height * .16,
        );
        canvas.drawCircle(
          p,
          rect.shortestSide * (.015 + .05 * u * random.nextDouble()),
          Paint()..color = colors[i % colors.length],
        );
      }
    default:
      canvas.drawCircle(
        rect.center,
        rect.shortestSide * .25,
        Paint()..color = const Color(0xFF39413B),
      );
  }
}

/// The picture of an item, loading its preview on demand.
class WardrobeItemArt extends StatefulWidget {
  const WardrobeItemArt({
    super.key,
    required this.item,
    required this.controller,
    this.art,
    this.hidden = false,
    this.antique = false,
  });
  final WardrobeItem item;
  final AppController controller;
  final RunnerArt? art;
  final bool hidden, antique;

  @override
  State<WardrobeItemArt> createState() => _WardrobeItemArtState();
}

class _WardrobeItemArtState extends State<WardrobeItemArt> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WardrobeItemArt old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) _load();
  }

  /// The portrait; without one (or offline) the item's own atlas or
  /// backdrop, which the fallback picture is cut from.
  Future<void> _load() async {
    final item = widget.item;
    if (WardrobePictures.cached(item.portrait) != null) return;
    final portrait = await WardrobePictures.load(
      widget.controller,
      item.portrait,
    );
    if (portrait == null &&
        item.image != null &&
        item.kind != WardrobeKind.fx &&
        WardrobePictures.cached(item.image) == null) {
      await WardrobePictures.load(widget.controller, item.image);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.infinite,
    painter: _ArtPainter(
      widget.item,
      widget.art,
      widget.hidden,
      widget.antique,
      WardrobePictures.cached(widget.item.portrait) ??
          WardrobePictures.cached(widget.item.image),
    ),
  );
}

class _ArtPainter extends CustomPainter {
  _ArtPainter(this.item, this.art, this.hidden, this.antique, this.preview);
  final WardrobeItem item;
  final RunnerArt? art;
  final bool hidden, antique;
  final ui.Image? preview;

  @override
  void paint(Canvas canvas, Size size) => paintItemArt(
    canvas,
    Offset.zero & size,
    item,
    art,
    hidden: hidden,
    antique: antique,
  );

  @override
  bool shouldRepaint(_ArtPainter old) =>
      old.item != item ||
      old.art != art ||
      old.hidden != hidden ||
      old.antique != antique ||
      old.preview != preview;
}

/// A card of the wardrobe: picture, name, label and the rarity bar below.
/// Items not found yet show as a silhouette with "?" in their rarity colour.
class WardrobeCard extends StatelessWidget {
  const WardrobeCard({
    super.key,
    required this.item,
    required this.wardrobe,
    required this.controller,
    this.art,
    this.worn = false,
    this.onTap,
  });
  final WardrobeItem item;
  final Wardrobe wardrobe;
  final AppController controller;
  final RunnerArt? art;
  final bool worn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final catalog = wardrobe.catalog;
    final rarity = catalog.rarityOf(item);
    final colors = rarityColors(catalog, item);
    final owned = wardrobe.owns(item);
    final hint = wardrobe.lockHint(item);
    final label = catalog.labelOf(item);
    final department = item.departments.isEmpty
        ? null
        : catalog.department(item.departments.first);
    final antique = rarity.antique;
    final name = owned ? item.name : '?';
    return Semantics(
      button: onTap != null,
      selected: worn,
      label: owned
          ? '${item.name}, ${rarity.name}${worn ? ', angelegt' : ''}'
          : 'Noch nicht gefunden, ${rarity.name}',
      child: Material(
        color: antique ? const Color(0xFF2A2117) : wardrobeInk,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: worn
                ? const Color(0xFFFFE7A3)
                : colors.first.withValues(alpha: .35),
            width: worn ? 2.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: [
                          colors.first.withValues(alpha: owned ? .32 : .14),
                          Colors.transparent,
                        ],
                        radius: .9,
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: WardrobeItemArt(
                            item: item,
                            controller: controller,
                            art: art,
                            hidden: !owned,
                            antique: antique,
                          ),
                        ),
                        if (!owned)
                          Center(
                            child: Text(
                              hint != null ? '' : '?',
                              style: TextStyle(
                                color: colors.first,
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        if (hint != null)
                          const Center(
                            child: Icon(
                              Icons.lock_outline,
                              color: Color(0xFFD8C3A0),
                            ),
                          ),
                        if (department != null)
                          Positioned(
                            left: 6,
                            top: 6,
                            child: Icon(
                              departmentIcon(department.icon),
                              size: 16,
                              color: Colors.white70,
                            ),
                          ),
                        if (worn)
                          const Positioned(
                            right: 6,
                            top: 6,
                            child: Icon(
                              Icons.check_circle,
                              size: 18,
                              color: Color(0xFFFFE7A3),
                            ),
                          ),
                        if (item.placeholder && owned)
                          const Positioned(
                            right: 6,
                            bottom: 4,
                            child: Text(
                              'Platzhalter',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 9,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        hint ?? (owned ? label ?? rarity.name : rarity.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 5,
                  decoration: BoxDecoration(gradient: rarityGradient(colors)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The picture of an obstacle in the worn obstacle set, e.g. for the
/// statistics; the velvet border is drawn.
class ObstacleIcon extends StatelessWidget {
  const ObstacleIcon(this.kind, {super.key, this.art});
  final ObstacleKind kind;
  final RunnerArt? art;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.infinite, painter: _ObstaclePainter(kind, art));
}

class _ObstaclePainter extends CustomPainter {
  _ObstaclePainter(this.kind, this.art);
  final ObstacleKind kind;
  final RunnerArt? art;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(size.width * .2)),
      Paint()..color = wardrobeInk,
    );
    final inner = rect.deflate(size.width * .14);
    final sprite = RunnerSprite.ofObstacle(kind), a = art;
    if (sprite == null || a == null) {
      // The velvet border with its gold fringe (or no pictures at all).
      final cloth = Rect.fromLTWH(
        inner.left + inner.width * .2,
        inner.top,
        inner.width * .6,
        inner.height * .8,
      );
      canvas.drawRect(cloth, Paint()..color = const Color(0xFF8E2420));
      canvas.drawRect(
        Rect.fromLTWH(cloth.left, cloth.bottom - 3, cloth.width, 3),
        Paint()..color = const Color(0xFFD9A441),
      );
      return;
    }
    final scale = min(inner.width / sprite.width, inner.height / sprite.height);
    canvas.drawImageRect(
      a.imageOf(sprite),
      sprite.rect,
      Rect.fromCenter(
        center: inner.center,
        width: sprite.width * scale,
        height: sprite.height * scale,
      ),
      a.paintOf(sprite),
    );
  }

  @override
  bool shouldRepaint(_ObstaclePainter old) =>
      old.kind != kind || old.art != art;
}
