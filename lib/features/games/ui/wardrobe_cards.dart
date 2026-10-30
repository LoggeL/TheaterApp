import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

/// Items not found yet: a silhouette a little lighter than the card, so the
/// missing ones stay recognisable as such.
final _silhouette = ColorFilter.mode(const Color(0xFF4A544D), BlendMode.srcIn);

/// Whether [item] brings pictures of its own (portrait, atlas or backdrop);
/// stand-ins and the default outfit show the game's art.
bool hasOwnPictures(WardrobeItem item) =>
    item.portrait != null ||
    (item.image != null && item.kind != WardrobeKind.fx);

final _placeholder = Paint()..color = const Color(0x14FFFFFF);

/// Draws the picture of [item] into [rect]: its [portrait] if loaded, else
/// the cheer pose (or crate and lamp) of its [own] atlas, else the default
/// art in the item's tint (stand-ins). Both default to what
/// [WardrobePictures] has; a given [own] is what the card chose to show,
/// a cached portrait does not replace it. An item with pictures of its own
/// that are not there (yet, or dropped from the cache) gets a neutral
/// placeholder, never the default figure. [hidden] shows only a silhouette,
/// for items not found yet.
void paintItemArt(
  Canvas canvas,
  Rect rect,
  WardrobeItem item,
  RunnerArt? base, {
  bool hidden = false,
  bool antique = false,
  ui.Image? portrait,
  ui.Image? own,
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

  final preview =
      portrait ??
      (own != null
          ? null
          : WardrobePictures.cached(item.portrait) ??
                WardrobePictures.cached(item.thumb));
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
  final mine = item.kind == WardrobeKind.fx
      ? null
      : own ?? WardrobePictures.cached(item.image);
  if (mine == null && hasOwnPictures(item)) {
    final r = rect.deflate(rect.shortestSide * .1);
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide * .12)),
      _placeholder,
    );
    return;
  }
  final atlas =
      mine != null &&
          base != null &&
          mine.width == base.atlas.width &&
          mine.height == base.atlas.height
      ? mine
      : base?.atlas;
  switch (item.kind) {
    case WardrobeKind.character when atlas != null:
      fit(
        atlas,
        RunnerSprite.cheer.rect,
        rect.deflate(rect.shortestSide * .06),
      );
    case WardrobeKind.backdrop when base != null:
      final image = mine ?? base.backdrop;
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

/// A large card of a stage shows the picture itself: its portrait is only as
/// large as a small card.
bool _largeShowsImage(WardrobeItem item) =>
    item.kind == WardrobeKind.backdrop && item.image != null;

/// Loads what a large card of [item] shows.
Future<ui.Image?> loadLargeArt(AppController controller, WardrobeItem item) =>
    _largeShowsImage(item)
    ? WardrobePictures.load(controller, item.image)
    : WardrobePictures.loadPortrait(controller, item.portrait);

/// The picture of an item, loading its preview on demand.
class WardrobeItemArt extends StatefulWidget {
  const WardrobeItemArt({
    super.key,
    required this.item,
    required this.controller,
    this.art,
    this.hidden = false,
    this.antique = false,
    this.small = false,
  });
  final WardrobeItem item;
  final AppController controller;
  final RunnerArt? art;
  final bool hidden, antique;

  /// A small card (the grid): the thumbnail is enough, if there is one. So
  /// is it for a silhouette.
  final bool small;

  @override
  State<WardrobeItemArt> createState() => _WardrobeItemArtState();
}

class _WardrobeItemArtState extends State<WardrobeItemArt> {
  // The pictures this card shows, held here: the shared cache may drop
  // them meanwhile without the card falling back to the default figure.
  ui.Image? _portrait, _own;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(WardrobeItemArt old) {
    super.didUpdateWidget(old);
    // Another role of the same figure keeps its id ([WardrobeItem.inRole])
    // but brings its own pictures: without them the card would show the
    // default art (Engel Logge) instead of the chosen role.
    if (old.item.id != widget.item.id ||
        old.item.portrait != widget.item.portrait ||
        old.item.thumb != widget.item.thumb ||
        old.item.image != widget.item.image) {
      _portrait = _own = null;
      _load();
    } else if (_portrait == null && _own == null && !_loading) {
      // Not there yet (offline before): try again.
      _load();
    }
  }

  /// The thumbnail on a small card, else the portrait; without one (or
  /// offline) the item's own atlas or backdrop, which the fallback picture
  /// is cut from. Dropped from the cache, they are fetched again.
  Future<void> _load() async {
    final item = widget.item;
    if (!hasOwnPictures(item)) return;
    final preview = widget.small || widget.hidden
        ? item.thumb ?? item.portrait
        : _largeShowsImage(item)
        ? null
        : item.portrait;
    _portrait = WardrobePictures.cached(preview);
    if (_portrait != null) return;
    _loading = true;
    try {
      bool shown() => mounted;
      final portrait = preview == item.thumb
          ? await WardrobePictures.load(
              widget.controller,
              preview,
              shown: shown,
            )
          : await WardrobePictures.loadPortrait(
              widget.controller,
              preview,
              shown: shown,
            );
      ui.Image? own;
      if (portrait == null &&
          item.image != null &&
          item.kind != WardrobeKind.fx) {
        own = await WardrobePictures.load(
          widget.controller,
          item.image,
          shown: shown,
        );
      }
      // Only for the item still shown: a late picture of the one before
      // must not land on this card.
      if (!mounted ||
          item.portrait != widget.item.portrait ||
          item.image != widget.item.image) {
        return;
      }
      setState(() {
        _portrait = portrait;
        _own = own;
      });
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.infinite,
    painter: _ArtPainter(
      widget.item,
      widget.art,
      widget.hidden,
      widget.antique,
      _portrait,
      _own,
    ),
  );
}

class _ArtPainter extends CustomPainter {
  _ArtPainter(
    this.item,
    this.art,
    this.hidden,
    this.antique,
    this.portrait,
    this.own,
  );
  final WardrobeItem item;
  final RunnerArt? art;
  final bool hidden, antique;
  final ui.Image? portrait, own;

  @override
  void paint(Canvas canvas, Size size) => paintItemArt(
    canvas,
    Offset.zero & size,
    item,
    art,
    hidden: hidden,
    antique: antique,
    portrait: portrait,
    own: own,
  );

  @override
  bool shouldRepaint(_ArtPainter old) =>
      old.item != item ||
      old.art != art ||
      old.hidden != hidden ||
      old.antique != antique ||
      old.portrait != portrait ||
      old.own != own;
}

/// A card of the wardrobe: picture, name, the role ("als Lucy · Creepshow
/// 2026"), the label and the rarity bar below. Items not found yet show as a
/// silhouette with "?" in their rarity colour.
class WardrobeCard extends StatelessWidget {
  const WardrobeCard({
    super.key,
    required this.item,
    required this.wardrobe,
    required this.controller,
    this.art,
    this.worn = false,
    this.onTap,
    this.animateShine = false,
    this.role,
    this.showRole = true,
    this.small = false,
  });
  final WardrobeItem item;
  final Wardrobe wardrobe;
  final AppController controller;
  final RunnerArt? art;
  final bool worn;
  final VoidCallback? onTap;

  /// Lets the shine of a shiny card sweep (in the reveal and the details);
  /// in the grid it stands still.
  final bool animateShine;

  /// Shows the card in this role (e.g. the one just won) instead of the
  /// worn one.
  final WardrobeVariant? role;

  /// The role line; off where it stands next to the card.
  final bool showRole;

  /// A card of the grid: see [WardrobeItemArt.small].
  final bool small;

  @override
  Widget build(BuildContext context) {
    final catalog = wardrobe.catalog;
    final rarity = catalog.rarityOf(item);
    final colors = rarityColors(catalog, item);
    final owned = wardrobe.owns(item);
    final shiny = owned && wardrobe.isShiny(item);
    // The worn role's pictures, if one is chosen.
    final variant = role ?? wardrobe.variantOf(item);
    final look = owned ? item.inRole(variant) : item;
    final playing = !owned
        ? null
        : role != null
        ? role!.role
        : wardrobe.roleOf(item);
    final hint =
        wardrobe.lockHint(item) ??
        rewardHint(wardrobe, item) ??
        uniqueHint(wardrobe, item);
    final label = catalog.labelOf(item);
    final department = item.departments.isEmpty
        ? null
        : catalog.department(item.departments.first);
    final antique = rarity.antique;
    // Unique figures shimmer like a hologram, unlocked or not.
    final holo = item.unique || rarity.holo;
    // A reward the wardrobe shows is no secret any more: only those of
    // reached milestones come (until then they are a surprise). A unique
    // figure not unlocked is "???".
    final name = owned || item.reward
        ? item.name
        : item.unique
        ? '???'
        : '?';
    final roleLine = playing == null
        ? null
        : item.unique
        ? uniqueRoleLine(playing, uniqueProgressOf(wardrobe, item))
        : playing.line;
    // A missing figure keeps its secret, but says where it belongs: the
    // play filter shows as much.
    final whereFrom = owned || item.unique || hint != null
        ? null
        : switch (item.role) {
            final r? when r.isFunction => 'Technik',
            final r? => r.production,
            null => null,
          };
    final gift = owned && wardrobe.isGift(item);
    return Semantics(
      button: onTap != null,
      selected: worn,
      label: owned
          ? '${item.name}${roleLine == null ? '' : ' $roleLine'}, ${rarity.name}${shiny ? ', Glanz' : ''}${gift ? ', Geschenk' : ''}${worn ? ', angelegt' : ''}'
          : item.unique
          ? 'Unique-Figur, noch verborgen${hint == null ? '' : ', $hint'}'
          : 'Noch nicht gefunden, ${rarity.name}${whereFrom == null ? '' : ', $whereFrom'}',
      child: Material(
        color: antique
            ? const Color(0xFF2A2117)
            : holo
            ? holoInk
            : wardrobeInk,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: worn
                ? const Color(0xFFFFE7A3)
                : shiny
                ? const Color(0xCCFFE7A3)
                : holo
                ? const Color(0xCCE6DAFF)
                : colors.first.withValues(alpha: .35),
            width: worn ? 2.5 : (shiny || holo ? 1.5 : 1),
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
                            item: look,
                            controller: controller,
                            art: art,
                            hidden: !owned && !item.reward,
                            antique: antique,
                            small: small,
                          ),
                        ),
                        if (shiny)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: ShineOverlay(animate: animateShine),
                            ),
                          ),
                        if (holo)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: HoloOverlay(
                                key: const ValueKey('holo-overlay'),
                                animate: animateShine,
                                strength: owned ? 1 : .55,
                              ),
                            ),
                          ),
                        if (!owned)
                          Center(
                            child: Text(
                              hint != null && !item.unique
                                  ? ''
                                  : item.unique
                                  ? '???'
                                  : '?',
                              style: TextStyle(
                                color: item.unique
                                    ? const Color(0xFFF1EAFF)
                                    : colors.first,
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        if (hint != null && !item.unique)
                          Center(
                            child: Icon(
                              item.reward
                                  ? Icons.groups_outlined
                                  : Icons.lock_outline,
                              color: const Color(0xFFD8C3A0),
                            ),
                          ),
                        if (shiny)
                          const Positioned(
                            right: 6,
                            bottom: 4,
                            child: Icon(
                              Icons.auto_awesome,
                              size: 16,
                              color: Color(0xFFFFE7A3),
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
                        if (gift)
                          const Positioned(
                            left: 6,
                            bottom: 4,
                            child: Icon(
                              Icons.card_giftcard,
                              key: ValueKey('card-gift'),
                              size: 16,
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
                      if (showRole && roleLine != null)
                        Text(
                          roleLine,
                          key: const ValueKey('card-role'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10.5,
                          ),
                        )
                      else if (showRole && whereFrom != null)
                        Text(
                          whereFrom,
                          key: const ValueKey('card-where'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10.5,
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
                  decoration: BoxDecoration(
                    gradient: holo ? holoGradient : rarityGradient(colors),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a reward not owned yet waits for: its milestone, or its picture
/// once the milestone is reached; null for other items.
String? rewardHint(Wardrobe wardrobe, WardrobeItem item) {
  if (!item.reward || wardrobe.owns(item)) return null;
  final m = wardrobe.ensemble?.rewardOf(item);
  if (m == null) return 'Ensemble-Belohnung';
  return m.reached
      ? 'Belohnung wird vorbereitet'
      : 'Ensemble-Ziel ${kmText(m.meters)}';
}

/// The way to the unique figure [item]: by its id once unlocked, by its play
/// for the hidden stand-in; null for other items.
UniqueFigureProgress? uniqueProgressOf(Wardrobe wardrobe, WardrobeItem item) {
  if (!item.unique) return null;
  final plays = wardrobe.uniqueFigures?.plays ?? const [];
  return plays.where((p) => p.itemId == item.id).firstOrNull ??
      plays.where((p) => !p.unlocked && p.play == item.role?.play).firstOrNull;
}

/// What a unique figure not unlocked yet waits for: "9/14 Rollen aus
/// Creepshow", "23/52 Rollen aus Creepshow und Nexus"; null for other items
/// and unlocked ones.
String? uniqueHint(Wardrobe wardrobe, WardrobeItem item) {
  if (!item.unique || wardrobe.owns(item)) return null;
  final p = uniqueProgressOf(wardrobe, item);
  return p != null && !p.unlocked ? p.line : 'Unique-Figur';
}

/// The line under a unique figure's name: "Unique · Creepshow 2026" (the
/// role is the character itself, so not "als Captain Kuschel"); across
/// plays ([progress]) "Unique · Creepshow und Nexus".
String uniqueRoleLine(WardrobeRole role, [UniqueFigureProgress? progress]) =>
    progress?.allTechnicians == true
    ? 'Unique · Technik'
    : progress != null && progress.several
    ? 'Unique · ${progress.play}'
    : ['Unique', ?role.production].join(' · ');

/// A stand-in card for the unique figure of [p] while it is a secret: no
/// id, name or picture of its own (the server sends none), only its play.
WardrobeItem uniqueStandIn(WardrobeCatalog catalog, UniqueFigureProgress p) =>
    WardrobeItem(
      id: 'unique-hidden:${p.production}',
      kind: WardrobeKind.character,
      name: '???',
      rarity: catalog.uniqueRarity?.id ?? 'unique',
      rarities: [catalog.uniqueRarity?.id ?? 'unique'],
      unique: true,
      role: WardrobeRole('???', play: p.play, year: p.year),
    );

/// The ground of a unique figure's card: deep violet, not the stage black.
const holoInk = Color(0xFF1A1630);

/// The holographic colours: a rainbow foil, deliberately unlike gold.
const holoColors = [
  Color(0xFFFF7AD9),
  Color(0xFFFFD36E),
  Color(0xFF8CFFC1),
  Color(0xFF7AD7FF),
  Color(0xFFB388FF),
  Color(0xFFFF7AD9),
];

/// The rarity bar of a unique figure: the whole rainbow.
const holoGradient = LinearGradient(colors: holoColors);

/// The shimmer of a unique figure's card: a rainbow foil across it with
/// fine diffraction lines and a light band; with [animate] the foil drifts.
/// [strength] dims it for a figure still hidden.
class HoloOverlay extends StatefulWidget {
  const HoloOverlay({super.key, this.animate = false, this.strength = 1});
  final bool animate;
  final double strength;

  @override
  State<HoloOverlay> createState() => _HoloOverlayState();
}

class _HoloOverlayState extends State<HoloOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
    value: .3,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _drift.repeat();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.infinite,
      painter: _HoloPainter(_drift, widget.strength),
    ),
  );
}

class _HoloPainter extends CustomPainter {
  _HoloPainter(this.t, this.strength) : super(repaint: t);
  final Animation<double> t;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size, u = t.value;
    final alpha = (.22 * strength).clamp(0.0, 1.0);
    // The rainbow foil, drifting diagonally.
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = LinearGradient(
          begin: Alignment(-1 + u * 2, -1),
          end: Alignment(1 + u * 2, 1),
          colors: [for (final c in holoColors) c.withValues(alpha: alpha)],
          tileMode: TileMode.mirror,
        ).createShader(rect),
    );
    // Fine diffraction lines.
    final lines = Paint()
      ..color = Colors.white.withValues(alpha: .05 * strength)
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 6) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        lines,
      );
    }
    // A light band crossing the other way.
    final at = 1.3 - u * 1.6;
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0x00FFFFFF),
            Colors.white.withValues(alpha: .28 * strength),
            const Color(0x00FFFFFF),
          ],
          stops: [
            (at - .15).clamp(0, 1),
            at.clamp(0, 1),
            (at + .15).clamp(0, 1),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_HoloPainter old) =>
      old.t != t || old.strength != strength;
}

final _km = NumberFormat('#,##0.#', 'de');

/// "1,2 km", "25 km".
String kmText(int meters) => '${_km.format(meters / 1000)} km';

/// The shine of a shiny card: a bright band across it and glints, in code;
/// with [animate] the band sweeps over the card again and again.
class ShineOverlay extends StatefulWidget {
  const ShineOverlay({super.key, this.animate = false});
  final bool animate;

  @override
  State<ShineOverlay> createState() => _ShineOverlayState();
}

class _ShineOverlayState extends State<ShineOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
    value: .35,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _sweep.repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(size: Size.infinite, painter: _ShinePainter(_sweep)),
  );
}

class _ShinePainter extends CustomPainter {
  _ShinePainter(this.t) : super(repaint: t);
  final Animation<double> t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size, u = t.value;
    // The band runs from the lower left to the upper right corner.
    final at = -.4 + u * 1.8;
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: const [
            Color(0x00FFFFFF),
            Color(0x40FFF4C2),
            Color(0x30B8F1FF),
            Color(0x00FFFFFF),
          ],
          stops: [
            (at - .18).clamp(0, 1),
            at.clamp(0, 1),
            (at + .08).clamp(0, 1),
            (at + .22).clamp(0, 1),
          ],
        ).createShader(rect),
    );
    final random = Random(11);
    final paint = Paint();
    for (var i = 0; i < 9; i++) {
      final p = Offset(
        size.width * (.08 + random.nextDouble() * .84),
        size.height * (.06 + random.nextDouble() * .7),
      );
      final twinkle = (sin(u * 2 * pi * 2 + i * 1.3) + 1) / 2;
      paint.color = shineColors[i % shineColors.length].withValues(
        alpha: .35 + .65 * twinkle,
      );
      paintGlint(canvas, p, size.shortestSide * (.025 + .04 * twinkle), paint);
    }
  }

  @override
  bool shouldRepaint(_ShinePainter old) => old.t != t;
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
    final a = art;
    final sprite = RunnerSprite.ofObstacle(kind, ownPile: a?.ownPile ?? false);
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
