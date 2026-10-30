import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/navigation.dart';
import '../data/wardrobe_api.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';
import 'wardrobe_cards.dart';

/// Opens the page of the owned figure [item]; [onWear] wears it (the page
/// closes first, as the details did before).
Future<void> openFigureDetail(
  BuildContext context, {
  required Wardrobe wardrobe,
  required WardrobeItem item,
  required AppController controller,
  RunnerArt? art,
  bool busy = false,
  bool dupes = false,
  ValueChanged<WardrobeItem>? onWear,
}) => openPage<void>(
  context,
  FigureDetailPage(
    wardrobe: wardrobe,
    item: item,
    controller: controller,
    art: art,
    busy: busy,
    dupes: dupes,
    onWear: onWear,
  ),
);

/// One moment of the showcase loop: the pose, how high it hangs on the
/// wire (0 on the floor, 1 at the top) and its tilt.
@immutable
class ShowcasePose {
  const ShowcasePose(this.sprite, {this.lift = 0, this.angle = 0});
  final RunnerSprite sprite;
  final double lift, angle;
}

/// How long one loop of the showcase takes, in seconds.
const showcasePeriod = 6.4;

/// The showcase at [seconds]: a run on the floor in the game's strides,
/// up on the wire (fly), sinking back (dangle), a cheer, and again. The
/// poses and tilts are those of the game.
ShowcasePose showcasePose(double seconds) {
  final t = seconds % showcasePeriod;
  if (t < 2.4) return ShowcasePose(RunnerSprite.stride(t * .6));
  if (t < 3.4) {
    final u = t - 2.4;
    return ShowcasePose(
      RunnerSprite.fly,
      lift: Curves.easeOut.transform(u),
      angle: -.16 * (1 - u),
    );
  }
  if (t < 4.6) {
    final u = (t - 3.4) / 1.2;
    return ShowcasePose(
      RunnerSprite.dangle,
      lift: 1 - Curves.easeIn.transform(u),
      angle: .06 + .1 * u,
    );
  }
  return const ShowcasePose(RunnerSprite.cheer);
}

/// The game's art dressed in [look] alone: its atlas, tint and wire points,
/// and the shine of a [shiny] figure, as the game draws it. Null when the
/// figure has an atlas of its own that does not load (or does not fit):
/// then it shows its picture instead, never the default figure.
Future<RunnerArt?> dressFigure(
  RunnerArt base,
  WardrobeItem look,
  AppController controller, {
  bool shiny = false,
}) async {
  final image = await WardrobePictures.load(controller, look.image);
  final fits =
      image != null &&
      image.width == base.atlas.width &&
      image.height == base.atlas.height;
  if (look.image != null && !fits) return null;
  return base.dressed(
    runner: fits ? image : null,
    runnerFilter: tintFilter(look.tint),
    harness: {
      for (final sprite in RunnerSprite.values)
        if (look.harness[sprite.name] case (final x, final y))
          sprite: ui.Offset(x, y),
    },
    effect: shiny ? const RunnerEffectStyle('', [], shine: true) : null,
  );
}

/// A small stage with the figure of [art] on the flying wire, looping
/// through its run, flight and cheer ([showcasePose]). Still (cheering)
/// when [playing] is off or animations are turned off.
class FigureShowcase extends StatefulWidget {
  const FigureShowcase({
    super.key,
    required this.art,
    this.glow = const Color(0xFF5E98D9),
    this.playing = true,
  });
  final RunnerArt art;
  final Color glow;
  final bool playing;

  @override
  State<FigureShowcase> createState() => _FigureShowcaseState();
}

class _FigureShowcaseState extends State<FigureShowcase>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (showcasePeriod * 1000).round()),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _run();
  }

  @override
  void didUpdateWidget(FigureShowcase old) {
    super.didUpdateWidget(old);
    _run();
  }

  void _run() {
    final still = !widget.playing || MediaQuery.disableAnimationsOf(context);
    if (still) {
      _loop.stop();
      // A cheer: the pose the cards show.
      if (!widget.playing) return;
      _loop.value = 5 / showcasePeriod;
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.infinite,
      painter: _ShowcasePainter(widget.art, _loop, widget.glow),
    ),
  );
}

const _wall = Color(0xFF1D2420), _stageDark = Color(0xFF151A17);
const _velvet = Color(0xFF8E2420), _velvetDark = Color(0xFF5E1714);
const _gold = Color(0xFFD9A441), _rope = Color(0xFFBDB29C);
const _floorColor = Color(0xFF3B2A1E), _plank = Color(0xFF2C1F16);
const _floorEdge = Color(0xFF6B4A30);

class _ShowcasePainter extends CustomPainter {
  _ShowcasePainter(this.art, this.loop, this.glow) : super(repaint: loop);
  final RunnerArt art;
  final Animation<double> loop;
  final Color glow;

  static final _ropePaint = Paint()
    ..color = _rope
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  final _glint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final time = loop.value * showcasePeriod;
    final floor = size.height * .86;
    final rect = Offset.zero & size;
    // The back wall, a spot on the floor and the rarity's glow.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_stageDark, _wall],
        ).createShader(rect),
    );
    final cx = size.width / 2;
    canvas.drawCircle(
      Offset(cx, floor - size.height * .3),
      size.height * .55,
      Paint()
        ..shader =
            RadialGradient(
              colors: [glow.withValues(alpha: .3), glow.withValues(alpha: 0)],
            ).createShader(
              Rect.fromCircle(
                center: Offset(cx, floor - size.height * .3),
                radius: size.height * .55,
              ),
            ),
    );
    // The floor, its planks passing by as on the moving stage.
    final floorRect = Rect.fromLTRB(0, floor, size.width, size.height);
    canvas.drawRect(floorRect, Paint()..color = _floorColor);
    final spacing = size.height * .22;
    final shift = (time * size.height * .55) % spacing;
    final plank = Paint()
      ..color = _plank
      ..strokeWidth = 2;
    for (var x = -shift; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, floor), Offset(x, size.height), plank);
    }
    canvas.drawRect(
      Rect.fromLTWH(0, floor - 1, size.width, 3),
      Paint()..color = _floorEdge,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, floor + size.height * .03),
        width: size.height * .7,
        height: size.height * .08,
      ),
      Paint()..color = const Color(0x33FFE7A3),
    );
    _figure(canvas, size, floor, time);
    _curtains(canvas, size);
  }

  void _figure(Canvas canvas, Size size, double floor, double time) {
    final pose = showcasePose(time);
    final sprite = pose.sprite;
    // The cheer, the tallest pose, takes half the stage's height.
    final scale = size.height * .5 / RunnerSprite.cheer.height;
    final width = sprite.width * scale, height = sprite.height * scale;
    final range = size.height * .3;
    final cx = size.width / 2;
    final Rect dst;
    if (sprite == RunnerSprite.fly) {
      // Flying flat, the body lies around the middle of a standing figure.
      final middle =
          floor - pose.lift * range - RunnerSprite.runA.height * scale / 2;
      dst = Rect.fromCenter(
        center: Offset(cx, middle),
        width: width,
        height: height,
      );
    } else {
      final bottom = floor - pose.lift * range + size.height * .01;
      dst = Rect.fromLTWH(cx - width / 2, bottom - height, width, height);
    }
    final harness = dst.topLeft + art.harnessOf(sprite) * scale;
    canvas.drawLine(Offset(harness.dx, 0), harness, _ropePaint);
    final shine = art.effect?.shine ?? false;
    final image = art.imageOf(sprite);
    canvas.save();
    if (pose.angle != 0) {
      final pivot = dst.center;
      canvas
        ..translate(pivot.dx, pivot.dy)
        ..rotate(pose.angle)
        ..translate(-pivot.dx, -pivot.dy);
    }
    if (shine) paintRim(canvas, image, sprite.rect, dst, time);
    canvas.drawImageRect(image, sprite.rect, dst, art.paintOf(sprite));
    if (shine) paintSheen(canvas, image, sprite.rect, dst, time);
    canvas.restore();
    if (shine) {
      // Glints around the figure, twinkling one after the other.
      for (var i = 0; i < 7; i++) {
        final a = i * 2 * pi / 7 + .4;
        final flash = (sin(time * 3 + i * 1.7) + 1) / 2;
        _glint.color = shineColor(i, flash);
        paintGlint(
          canvas,
          dst.center +
              Offset(cos(a) * dst.width * .55, sin(a) * dst.height * .5),
          size.height * (.012 + .018 * flash),
          _glint,
        );
      }
    }
  }

  /// Velvet at both sides and a valance with a golden fringe.
  void _curtains(Canvas canvas, Size size) {
    final side = size.width * .08;
    final fold = Paint()..color = _velvetDark;
    for (final left in [true, false]) {
      final r = left
          ? Rect.fromLTWH(0, 0, side, size.height)
          : Rect.fromLTWH(size.width - side, 0, side, size.height);
      canvas.drawRect(r, Paint()..color = _velvet);
      for (var i = 1; i < 3; i++) {
        final x = r.left + r.width * i / 3;
        canvas.drawRect(Rect.fromLTWH(x - 1.5, 0, 3, size.height), fold);
      }
    }
    final valance = size.height * .07;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, valance),
      Paint()..color = _velvet,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, valance - 3, size.width, 3),
      Paint()..color = _gold,
    );
  }

  @override
  bool shouldRepaint(_ShowcasePainter old) =>
      old.art != art || old.loop != loop || old.glow != glow;
}

/// The page of an owned figure: the figure on the flying wire, who plays
/// whom in which play and year, its rarity and why, shine and duplicates,
/// and the person's other roles. "Anlegen" wears it.
class FigureDetailPage extends StatefulWidget {
  const FigureDetailPage({
    super.key,
    required this.wardrobe,
    required this.item,
    required this.controller,
    this.art,
    this.busy = false,
    this.dupes = false,
    this.onWear,
  });
  final Wardrobe wardrobe;
  final WardrobeItem item;
  final AppController controller;
  final RunnerArt? art;
  final bool busy, dupes;
  final ValueChanged<WardrobeItem>? onWear;

  @override
  State<FigureDetailPage> createState() => _FigureDetailPageState();
}

class _FigureDetailPageState extends State<FigureDetailPage> {
  late WardrobeItem _item = widget.item;
  late RunnerArt? _base = widget.art;
  RunnerArt? _dressed;
  bool _dressing = true, _playing = true;

  Wardrobe get w => widget.wardrobe;

  @override
  void initState() {
    super.initState();
    if (_base == null) {
      RunnerArt.load().then((art) {
        if (!mounted) return;
        setState(() => _base = art);
        _dress();
      });
    } else {
      _dress();
    }
  }

  /// The figure in its worn role, as the game would show it.
  Future<void> _dress() async {
    final base = _base, item = _item;
    if (base == null) {
      if (mounted) setState(() => _dressing = false);
      return;
    }
    final dressed = await dressFigure(
      base,
      item.inRole(w.variantOf(item)),
      widget.controller,
      shiny: w.isShiny(item),
    );
    if (!mounted || !identical(item, _item)) return;
    setState(() {
      _dressed = dressed;
      _dressing = false;
    });
  }

  void _show(WardrobeItem other) {
    setState(() {
      _item = other;
      _dressed = null;
      _dressing = true;
    });
    _dress();
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final theme = Theme.of(context);
    final catalog = w.catalog;
    final rarities = catalog.raritiesOf(item);
    final colors = rarityColors(catalog, item);
    final worn = w.worn(item.kind)?.id == item.id;
    final shiny = w.isShiny(item);
    final gift = w.isGift(item);
    final dupes = w.dupesOf(item);
    final label = catalog.labelOf(item);
    final playing = w.roleOf(item);
    final unique = uniqueProgressOf(w, item);
    final milestone = item.reward ? w.ensemble?.rewardOf(item) : null;
    final surface = theme.colorScheme.surface;
    final rarityColor = StageTheme.legible(colors.first, surface, minimum: 3);
    final stage = _stage(context, item, colors.first);
    final facts = <(String, String)>[
      if (playing case final r? when !item.unique) ...[
        (r.isFunction ? 'Aufgabe' : 'Spielt', r.role),
        if (r.play case final play?) ('Stück', play),
        if (r.year case final year?) ('Jahr', '$year'),
      ],
      if (item.unique && unique != null)
        ('Aus', unique.allTechnicians ? 'Technik' : unique.play),
      if (label != null) ('Abteilung', label),
    ];
    final details = <Widget>[
      Text(
        item.name,
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
      if (playing != null)
        Text(
          item.unique ? uniqueRoleLine(playing, unique) : playing.line,
          key: const ValueKey('wardrobe-role'),
          style: theme.textTheme.titleSmall,
        ),
      const SizedBox(height: 6),
      Text(
        [item.kind.singular, ...rarities.map((r) => r.name)].join(' · '),
        style: TextStyle(color: rarityColor, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          if (shiny)
            const Chip(
              key: ValueKey('figure-shiny'),
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                Icons.auto_awesome,
                size: 16,
                color: Color(0xFFE4AE39),
              ),
              label: Text('Glanz-Version'),
            ),
          if (gift)
            const Chip(
              key: ValueKey('figure-gift'),
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                Icons.card_giftcard,
                size: 16,
                color: StageTheme.orange,
              ),
              label: Text('Geschenk'),
            ),
          if (worn)
            const Chip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(Icons.check_circle, size: 16),
              label: Text('Angelegt'),
            ),
          if (dupes != null)
            Chip(
              key: const ValueKey('figure-dupes'),
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.copy_all_outlined, size: 16),
              label: Text(
                dupes == 1 ? '1 Duplikat gezogen' : '$dupes Duplikate gezogen',
              ),
            ),
        ],
      ),
      if (facts.isNotEmpty) ...[
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              children: [
                for (final (name, value) in facts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: MergeSemantics(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 92,
                            child: Text(
                              name,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              value,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      if (item.rarityReason case final reason?) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: rarityColor, width: 3)),
            color: colors.first.withValues(alpha: .08),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Warum ${catalog.rarityOf(item).name}?',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 2),
              Text(reason, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
      if (gift)
        _note(
          context,
          'Dein Geschenk zum Start: deine eigene Figur in ihrer niedrigsten Stufe. Weitere eigene Rollen kommen aus Kisten.',
        ),
      if (!shiny && widget.dupes && !item.unique && !item.reward)
        _note(
          context,
          'Noch ohne Glanz: ein Duplikat aus einer Kiste kann sie glänzen lassen.',
        ),
      if (item.placeholder)
        _note(context, 'Platzhalter: die eigene Grafik kommt noch.'),
      if (milestone != null)
        _note(
          context,
          'Ensemble-Belohnung für ${kmText(milestone.meters)} gemeinsam.',
        ),
      if (item.unique)
        _note(
          context,
          unique?.allTechnicians == true
              ? 'Freigeschaltet: alle Techniker gesammelt.'
              : 'Freigeschaltet: alle Rollen aus ${unique?.play ?? item.role?.play ?? 'dem Stück'} gesammelt.',
        ),
      const SizedBox(height: 20),
      if (worn)
        FilledButton.tonalIcon(
          onPressed: null,
          icon: const Icon(Icons.check),
          label: const Text('Angelegt'),
        )
      else
        FilledButton.icon(
          key: const ValueKey('figure-wear'),
          onPressed: widget.busy || widget.onWear == null
              ? null
              : () {
                  Navigator.pop(context);
                  widget.onWear!(item);
                },
          icon: const Icon(Icons.checkroom),
          label: const Text('Anlegen'),
        ),
      ..._otherRoles(context, item),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(item.name)),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 640 &&
                constraints.maxWidth > constraints.maxHeight;
            final side = max(16.0, (constraints.maxWidth - 1040) / 2);
            if (wide) {
              return Padding(
                padding: EdgeInsets.fromLTRB(side, 12, side, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: stage,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 6,
                      child: ListView(
                        key: const PageStorageKey('figure-details'),
                        padding: const EdgeInsets.only(bottom: 24),
                        children: details,
                      ),
                    ),
                  ],
                ),
              );
            }
            final height = min(
              constraints.maxWidth * .82,
              max(220.0, constraints.maxHeight * .45),
            );
            return ListView(
              key: const PageStorageKey('figure-details'),
              padding: EdgeInsets.fromLTRB(side, 12, side, 24),
              children: [
                SizedBox(height: height, child: stage),
                const SizedBox(height: 16),
                ...details,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _note(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  /// The figure on the wire; while its atlas loads (or without one that
  /// fits) its picture.
  Widget _stage(BuildContext context, WardrobeItem item, Color glow) {
    final dressed = _dressed;
    final holo = item.unique;
    final shiny = w.isShiny(item);
    final animated = dressed != null;
    final playing = w.roleOf(item);
    final who = item.unique ? item.name : nameInRole(item.name, playing);
    return Semantics(
      container: true,
      image: true,
      label: animated
          ? '$who am Flugseil: läuft, fliegt und jubelt${shiny ? ', mit Glanz' : ''}'
          : who,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: holo ? holoInk : wardrobeInk,
            border: Border.all(
              color: shiny
                  ? const Color(0xCCFFE7A3)
                  : holo
                  ? const Color(0xCCE6DAFF)
                  : glow.withValues(alpha: .5),
              width: shiny || holo ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeSemantics(
                child: animated
                    ? FigureShowcase(
                        key: ValueKey('figure-showcase-${item.id}'),
                        art: dressed,
                        glow: glow,
                        playing: _playing,
                      )
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: WardrobeItemArt(
                          item: item.inRole(w.variantOf(item)),
                          controller: widget.controller,
                          art: _base,
                          antique: w.catalog.rarityOf(item).antique,
                        ),
                      ),
              ),
              if (holo)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: HoloOverlay(animate: true, strength: .35),
                  ),
                ),
              if (_dressing)
                const Positioned(
                  right: 12,
                  top: 12,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (animated)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: IconButton.filledTonal(
                    key: const ValueKey('figure-play'),
                    tooltip: _playing
                        ? 'Animation anhalten'
                        : 'Animation abspielen',
                    onPressed: () => setState(() => _playing = !_playing),
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The person's other roles, owned and missing; an owned one shows here
  /// at a tap.
  List<Widget> _otherRoles(BuildContext context, WardrobeItem item) {
    final person = item.personId;
    if (person == null || item.unique) return const [];
    final roles =
        [
          for (final i in w.catalog.items)
            if (i.kind == WardrobeKind.character &&
                i.personId == person &&
                !i.isDefault &&
                !i.unique)
              i,
        ]..sort((a, b) {
          if (w.owns(a) != w.owns(b)) return w.owns(a) ? -1 : 1;
          return (b.role?.year ?? 0).compareTo(a.role?.year ?? 0);
        });
    final others = [
      for (final i in roles)
        if (i.id != item.id) i,
    ];
    if (others.isEmpty) return const [];
    final theme = Theme.of(context);
    final owned = roles.where(w.owns).length;
    final scale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
      1.0,
      2.0,
    );
    return [
      const SizedBox(height: 24),
      Row(
        children: [
          Expanded(
            child: Text(
              'Weitere Rollen von ${item.name}',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Text(
            '$owned von ${roles.length} gefunden',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 150 * scale,
        child: ListView.separated(
          key: const PageStorageKey('figure-other-roles'),
          scrollDirection: Axis.horizontal,
          itemCount: others.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final other = others[i];
            return SizedBox(
              width: 104 * scale,
              child: WardrobeCard(
                key: ValueKey('figure-role-${other.id}'),
                item: other,
                wardrobe: w,
                controller: widget.controller,
                art: _base,
                worn: w.worn(other.kind)?.id == other.id,
                small: true,
                onTap: w.owns(other) ? () => _show(other) : null,
              ),
            );
          },
        ),
      ),
    ];
  }
}
