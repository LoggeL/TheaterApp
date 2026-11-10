import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../data/wardrobe_api.dart';

final _number = NumberFormat.decimalPattern('de');

/// [owned] of [total].
class Tally {
  const Tally(this.owned, this.total);
  final int owned, total;
  int get missing => total - owned;
  bool get complete => total > 0 && owned >= total;
  double get fraction => total <= 0 ? 0 : (owned / total).clamp(0, 1);

  /// "7 von 11".
  String get text => '${_number.format(owned)} von ${_number.format(total)}';

  static Tally of(Iterable<WardrobeItem> items, Wardrobe w) {
    var owned = 0, total = 0;
    for (final i in items) {
      total++;
      if (w.owns(i)) owned++;
    }
    return Tally(owned, total);
  }
}

/// How far a rarity of the draw is collected.
class RarityTally {
  const RarityTally(this.rarity, this.tally, {this.locked = false});
  final WardrobeRarity rarity;
  final Tally tally;

  /// Not in the draw yet ([Wardrobe.lockedRarities]).
  final bool locked;
}

/// How far the figures of a play (or the technicians) are collected, and
/// what is still missing by rarity, rarest first; never by name.
class PlayTally {
  const PlayTally({
    required this.title,
    required this.tally,
    this.play,
    this.year,
    this.technicians = false,
    this.missing = const [],
    this.unique,
  });

  /// "Creepshow 2026", or "Technik".
  final String title;
  final String? play;
  final int? year;
  final bool technicians;
  final Tally tally;
  final List<(WardrobeRarity, int)> missing;

  /// The way to the play's unique figure, if it has one.
  final UniqueFigureProgress? unique;

  /// The production as the figure filter knows it; null for technicians.
  String? get production => technicians ? null : title;

  /// "noch offen: 2 × Gold, 1 × Pink"; null when complete.
  String? get missingText => missing.isEmpty
      ? null
      : 'noch offen: ${missing.map((m) => '${m.$2} × ${m.$1.name}').join(', ')}';

  /// The way to the unique figure without its secret: "Unique: noch 4
  /// Rollen", "Unique freigeschaltet"; null without one.
  String? get uniqueText {
    final u = unique;
    if (u == null) return null;
    if (u.unlocked) return 'Unique freigeschaltet';
    final left = (u.total - u.have).clamp(0, u.total);
    final what = u.allAdventCalendar
        ? left == 1
              ? 'Adventskalender-Skin'
              : 'Adventskalender-Skins'
        : u.allTechnicians
        ? 'Techniker'
        : left == 1
        ? 'Rolle'
        : 'Rollen';
    return 'Unique: noch $left $what';
  }
}

/// What a wardrobe holds at a glance: everything, per kind, per rarity, per
/// play, the unique figures and the shine.
class WardrobeOverview {
  const WardrobeOverview({
    required this.all,
    required this.kinds,
    required this.rarities,
    required this.plays,
    this.uniques,
    this.shiny = 0,
    this.gift,
  });

  /// The whole collection: the server's numbers ([Wardrobe.collection]),
  /// as in the Sammel-Rangliste; for older servers everything a crate can
  /// bring.
  ///
  /// With the server's numbers it also holds the unique figures, the secret
  /// ones the app does not know as well, so [kinds] and [rarities] (crate
  /// items only, by the same rules otherwise) cannot add up to it exactly;
  /// [uniques] counts the unlocked unique figures apart.
  final Tally all;
  final Map<WardrobeKind, Tally> kinds;

  /// Rarest first; only those with collectible items.
  final List<RarityTally> rarities;

  /// The plays, newest first, the technicians last.
  final List<PlayTally> plays;

  /// The unique figures unlocked of all there are; null without any.
  final Tally? uniques;

  /// Owned items in their shiny version.
  final int shiny;

  /// The present figure, if the server names one.
  final WardrobeItem? gift;

  factory WardrobeOverview.of(Wardrobe w, {bool unique = true}) {
    final catalog = w.catalog;
    // Only what the server counts too: no items without a picture, none a
    // release gives everybody ([Wardrobe.counts]).
    final collectible = catalog.collectible.where(w.counts).toList();
    final kinds = {
      for (final kind in WardrobeKind.values)
        if (collectible.any((i) => i.kind == kind))
          kind: Tally.of(collectible.where((i) => i.kind == kind), w),
    };
    final rarities = [
      for (final r in catalog.rarities.reversed)
        if (collectible.where((i) => i.rarity == r.id) case final items
            when items.isNotEmpty)
          RarityTally(
            r,
            Tally.of(items, w),
            locked: w.lockedRarities.contains(r.id),
          ),
    ];
    final progress = unique
        ? w.uniqueFigures?.plays ?? const <UniqueFigureProgress>[]
        : const <UniqueFigureProgress>[];
    List<(WardrobeRarity, int)> missing(List<WardrobeItem> items) => [
      for (final r in catalog.rarities.reversed)
        if (items.where((i) => i.rarity == r.id && !w.owns(i)).length
            case final n when n > 0)
          (r, n),
    ];
    final figures = [
      for (final i in collectible)
        if (i.kind == WardrobeKind.character && i.role != null) i,
    ];
    final byPlay = <String, List<WardrobeItem>>{};
    final technicians = <WardrobeItem>[];
    for (final i in figures) {
      final production = i.role!.production;
      if (production == null) {
        technicians.add(i);
      } else {
        (byPlay[production] ??= []).add(i);
      }
    }
    final plays =
        [
          for (final MapEntry(key: title, value: items) in byPlay.entries)
            PlayTally(
              title: title,
              play: items.first.role?.play,
              year: items.first.role?.year,
              tally: Tally.of(items, w),
              missing: missing(items),
              unique: progress
                  .where(
                    (p) =>
                        !p.several &&
                        !p.allTechnicians &&
                        p.play == items.first.role?.play &&
                        (p.year == null || p.year == items.first.role?.year),
                  )
                  .firstOrNull,
            ),
        ]..sort((a, b) {
          final year = (b.year ?? 0).compareTo(a.year ?? 0);
          return year != 0 ? year : a.title.compareTo(b.title);
        });
    if (technicians.isNotEmpty) {
      plays.add(
        PlayTally(
          title: 'Technik',
          technicians: true,
          tally: Tally.of(technicians, w),
          missing: missing(technicians),
          unique: progress.where((p) => p.allTechnicians).firstOrNull,
        ),
      );
    }
    final uniqueCount = progress.length;
    return WardrobeOverview(
      all: switch (w.collection) {
        final c? => Tally(c.owned, c.total),
        null => Tally.of(collectible, w),
      },
      kinds: kinds,
      rarities: rarities,
      plays: plays,
      uniques: uniqueCount == 0
          ? null
          : Tally(progress.where((p) => p.unlocked).length, uniqueCount),
      shiny: w.shiny.where((id) => catalog.item(id) != null).length,
      gift: catalog.item(w.gift ?? ''),
    );
  }
}

/// A slim bar in [color].
class TallyBar extends StatelessWidget {
  const TallyBar(this.fraction, {super.key, this.color, this.height = 6});
  final double fraction;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(height),
    child: LinearProgressIndicator(
      value: fraction,
      minHeight: height,
      color: color,
      backgroundColor: (color ?? Theme.of(context).colorScheme.primary)
          .withValues(alpha: .16),
    ),
  );
}

/// The text scale of the wardrobe's grids: 1 to 2.
double wardrobeScale(BuildContext context) =>
    (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0);

/// The inner padding of the wardrobe's cards: 16 on phones, else 20.
double wardrobeInset(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 600 ? 16 : 20;

/// How [n] cells of at least [minCell] share [width]: as few rows as fit,
/// the cells spread evenly over them (the front rows take the rest, so 7 on
/// 3 rows are 3, 2, 2) and one cell width for every row.
({List<int> rows, double cell}) balancedRows(
  int n,
  double width,
  double minCell, {
  double gap = 8,
}) {
  if (n <= 0) return (rows: const <int>[], cell: width);
  final maxCols = ((width + gap) / (minCell + gap)).floor().clamp(1, n);
  final count = (n / maxCols).ceil();
  final perRow = (n / count).ceil();
  return (
    rows: [
      for (var r = 0; r < count; r++) n ~/ count + (r < n % count ? 1 : 0),
    ],
    cell: (width - (perRow - 1) * gap) / perRow,
  );
}

/// [children] in [balancedRows], left-aligned.
class BalancedGrid extends StatelessWidget {
  const BalancedGrid({
    super.key,
    required this.minCell,
    required this.children,
    this.gap = 8,
    this.runGap = 10,
  });
  final double minCell, gap, runGap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final layout = balancedRows(
        children.length,
        constraints.maxWidth,
        minCell,
        gap: gap,
      );
      var next = 0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: runGap,
        children: [
          for (final n in layout.rows)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: gap,
              children: [
                for (var i = 0; i < n; i++)
                  SizedBox(width: layout.cell, child: children[next++]),
              ],
            ),
        ],
      );
    },
  );
}

/// The top of the collection: "87 von 251" with a bar, each rarity's
/// progress, the shine, the unique figures and the crates waiting. What
/// costs or brings gage is in the crates' tab.
class CollectionSummaryCard extends StatelessWidget {
  const CollectionSummaryCard({
    super.key,
    required this.overview,
    required this.waitingCrates,
    this.onCrates,
  });
  final WardrobeOverview overview;
  final int waitingCrates;

  /// To the crates; the way there shows only while [waitingCrates] wait.
  final VoidCallback? onCrates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surface = scheme.surface;
    final all = overview.all;
    final percent = (all.fraction * 100).floor();
    final scale = wardrobeScale(context);
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    Widget note(Key key, IconData icon, Color color, String text) => Row(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: quiet)),
      ],
    );
    final notes = [
      if (overview.shiny > 0)
        note(
          const ValueKey('wardrobe-summary-shiny'),
          Icons.auto_awesome,
          const Color(0xFFE4AE39),
          '${overview.shiny} in Glanz',
        ),
      if (overview.uniques case final u?)
        Semantics(
          key: const ValueKey('wardrobe-summary-unique'),
          container: true,
          label: 'Unique-Figuren: ${u.text} freigeschaltet',
          excludeSemantics: true,
          child: note(
            const ValueKey('wardrobe-summary-unique-note'),
            Icons.diamond_outlined,
            const Color(0xFFB388FF),
            'Unique ${u.owned}/${u.total}',
          ),
        ),
    ];
    final waiting = waitingCrates == 1
        ? '1 Kiste wartet'
        : '$waitingCrates Kisten warten';
    final crates = waitingCrates <= 0
        ? null
        // The button's own node keeps its tap; only the text says more.
        : TextButton(
            key: const ValueKey('wardrobe-summary-crates'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onCrates,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 18,
                  color: StageTheme.accentText(
                    StageTheme.orange,
                    theme.brightness,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    waiting,
                    semanticsLabel: '$waiting, zu den Kisten',
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          );
    final wide = MediaQuery.sizeOf(context).width >= 600 && !largeText;
    final inset = wardrobeInset(context);
    return Card(
      key: const ValueKey('wardrobe-summary'),
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, inset - 2, inset, inset - 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              container: true,
              label:
                  'Sammlung: ${all.text} gesammelt, $percent Prozent${all.complete ? ', komplett' : ''}',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Deine Sammlung',
                              style: theme.textTheme.labelLarge,
                            ),
                            Text(
                              all.text,
                              key: const ValueKey('wardrobe-count'),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (all.complete) ...[
                        const Icon(
                          Icons.check_circle,
                          size: 18,
                          color: StageTheme.green,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        all.complete ? 'komplett' : '$percent %',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: StageTheme.accentText(
                            StageTheme.orange,
                            theme.brightness,
                          ),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TallyBar(all.fraction, color: StageTheme.orange, height: 8),
                ],
              ),
            ),
            if (overview.rarities.isNotEmpty) ...[
              const SizedBox(height: 16),
              // Even rows instead of one lone rarity on a line of its own.
              BalancedGrid(
                minCell: 64 * scale,
                children: [
                  for (final r in overview.rarities)
                    Semantics(
                      key: ValueKey('wardrobe-rarity-${r.rarity.id}'),
                      container: true,
                      label:
                          '${r.rarity.name}: ${r.tally.text}${r.locked ? ', noch gesperrt' : ''}',
                      excludeSemantics: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (r.locked)
                                Icon(
                                  Icons.lock_outline,
                                  size: 12,
                                  color: scheme.onSurfaceVariant,
                                )
                              else
                                CircleAvatar(
                                  radius: 4,
                                  backgroundColor: r.rarity.color,
                                ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  r.rarity.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelMedium,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          TallyBar(
                            r.tally.fraction,
                            color: StageTheme.legible(
                              r.rarity.color,
                              surface,
                              minimum: 3,
                            ),
                            height: 4,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            r.tally.complete
                                ? '${r.tally.owned} ✓'
                                : '${r.tally.owned}/${r.tally.total}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            if (notes.isNotEmpty || crates != null) ...[
              const SizedBox(height: 8),
              if (wide)
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: notes,
                      ),
                    ),
                    ?crates,
                  ],
                )
              else
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [...notes, ?crates],
                ),
            ] else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// The plays (and the technicians) side by side: how many roles of each are
/// collected, what is still missing by rarity, the way to the unique
/// figure. A tap shows only that play's figures. Where all tiles fit they
/// share the width; else they scroll, and the chosen one scrolls into view.
class PlayProgressStrip extends StatefulWidget {
  const PlayProgressStrip({
    super.key,
    required this.plays,
    this.selected,
    this.onSelect,
  });
  final List<PlayTally> plays;

  /// The [PlayTally.title] shown alone, if any.
  final String? selected;
  final ValueChanged<PlayTally>? onSelect;

  @override
  State<PlayProgressStrip> createState() => _PlayProgressStripState();
}

class _PlayProgressStripState extends State<PlayProgressStrip> {
  static const _gap = 10.0;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(PlayProgressStrip old) {
    super.didUpdateWidget(old);
    if (widget.selected != old.selected && widget.selected != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  /// Scrolls the chosen tile to the middle. Computed from its place: the
  /// list builds lazily, so a tile far off has no context to ask.
  void _reveal() {
    if (!mounted || !_scroll.hasClients) return;
    final i = widget.plays.indexWhere((p) => p.title == widget.selected);
    if (i < 0) return;
    final tile = 184 * wardrobeScale(context);
    final position = _scroll.position;
    final target = (i * (tile + _gap) - (position.viewportDimension - tile) / 2)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plays = widget.plays;
    final scale = wardrobeScale(context);
    final complete = plays.where((p) => p.tally.complete).length;
    Widget tile(PlayTally p) => _PlayTile(
      p,
      selected: p.title == widget.selected,
      onTap: widget.onSelect == null ? null : () => widget.onSelect!(p),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          // The count at the right; with large text below the title
          // instead of pushing out of the line.
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text('Stücke & Technik', style: theme.textTheme.titleSmall),
              Text(
                '$complete von ${plays.length} komplett',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 146 * scale,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fits =
                  plays.length * 168 * scale + (plays.length - 1) * _gap <=
                  constraints.maxWidth;
              if (fits) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: _gap,
                  children: [for (final p in plays) Expanded(child: tile(p))],
                );
              }
              return ListView.separated(
                key: const PageStorageKey('wardrobe-play-strip'),
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                itemCount: plays.length,
                separatorBuilder: (_, _) => const SizedBox(width: _gap),
                itemBuilder: (context, i) =>
                    SizedBox(width: 184 * scale, child: tile(plays[i])),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlayTile extends StatelessWidget {
  const _PlayTile(this.play, {this.selected = false, this.onTap});
  final PlayTally play;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = play.tally;
    final what = play.technicians ? 'Techniker' : 'Rollen';
    final unique = play.uniqueText;
    return Semantics(
      key: ValueKey('wardrobe-play-${play.title}'),
      button: onTap != null,
      selected: selected,
      label: [
        '${play.title}: ${t.text} $what',
        if (t.complete) 'komplett' else ?play.missingText,
        ?unique,
      ].join(', '),
      excludeSemantics: true,
      child: Material(
        color: selected
            ? StageTheme.selectedTint(theme.brightness)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected
                ? StageTheme.orange
                : t.complete
                ? StageTheme.green
                : Colors.transparent,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      play.technicians
                          ? Icons.handyman_outlined
                          : Icons.theater_comedy_outlined,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        play.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    if (t.complete)
                      const Icon(
                        Icons.check_circle,
                        size: 16,
                        color: StageTheme.green,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${t.text} $what',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                TallyBar(
                  t.fraction,
                  color: t.complete ? StageTheme.green : StageTheme.orange,
                  height: 5,
                ),
                const SizedBox(height: 6),
                if (t.complete)
                  Text(
                    'Alle gefunden',
                    maxLines: 1,
                    style: theme.textTheme.bodySmall,
                  )
                else
                  // The missing ones by rarity: a dot and a count each,
                  // on two lines at most.
                  Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: 'offen: '),
                        for (final (rarity, n) in play.missing) ...[
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: CircleAvatar(
                                radius: 4,
                                backgroundColor: rarity.color,
                              ),
                            ),
                          ),
                          TextSpan(text: '$n ${rarity.name}   '),
                        ],
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                const SizedBox(height: 4),
                if (unique != null)
                  Row(
                    children: [
                      Icon(
                        play.unique!.unlocked
                            ? Icons.diamond
                            : Icons.diamond_outlined,
                        size: 13,
                        color: const Color(0xFF9C7BEA),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          unique,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The crates in numbers: what was opened, the shine and the gage the
/// duplicates brought.
class CrateBalanceCard extends StatelessWidget {
  const CrateBalanceCard({
    super.key,
    required this.opened,
    required this.earned,
    required this.shiny,
    this.gageEarned,
    this.duplicates,
  });

  final int opened, earned, shiny;
  final int? gageEarned, duplicates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget figure(String key, String value, String label) => Semantics(
      key: ValueKey('crate-balance-$key'),
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
    final inset = wardrobeInset(context);
    return Card(
      key: const ValueKey('crate-balance'),
      child: Padding(
        padding: EdgeInsets.all(inset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.query_stats, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Kistenbilanz',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            BalancedGrid(
              minCell: 88 * wardrobeScale(context),
              children: [
                figure('opened', _number.format(opened), 'geöffnet'),
                figure('earned', _number.format(earned), 'erspielt'),
                figure('shiny', _number.format(shiny), 'in Glanz'),
                if (duplicates != null)
                  figure('dupes', _number.format(duplicates), 'Duplikate'),
                if (gageEarned != null)
                  figure('gage', _number.format(gageEarned), 'Gage verdient'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Kostümkisten aus deinen Läufen; Glanz und Gage aus allen Kisten.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
