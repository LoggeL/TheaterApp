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
    final what = u.allTechnicians
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

/// The top of the collection: "87 von 251" with a bar, each rarity's
/// progress, the crates waiting, the shine, the unique figures and the gage.
class CollectionSummaryCard extends StatelessWidget {
  const CollectionSummaryCard({
    super.key,
    required this.overview,
    required this.waitingCrates,
    this.onCrates,
    this.gage,
    this.onTrade,
  });
  final WardrobeOverview overview;
  final int waitingCrates;
  final VoidCallback? onCrates;

  /// Shown with duplicates (`runnerDupes`) only.
  final String? gage;
  final VoidCallback? onTrade;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    final all = overview.all;
    final percent = (all.fraction * 100).floor();
    Widget pill({
      required Key key,
      required IconData icon,
      required String label,
      Color? color,
      VoidCallback? onTap,
      String? semantics,
    }) => Semantics(
      key: key,
      button: onTap != null,
      label: semantics,
      excludeSemantics: semantics != null,
      child: onTap == null
          ? Chip(
              avatar: Icon(icon, size: 18, color: color),
              label: Text(label),
              visualDensity: VisualDensity.compact,
            )
          : ActionChip(
              avatar: Icon(icon, size: 18, color: color),
              label: Text(label),
              visualDensity: VisualDensity.compact,
              onPressed: onTap,
            ),
    );
    return Card(
      key: const ValueKey('wardrobe-summary'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
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
                      Text(
                        all.complete ? 'komplett' : '$percent %',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: StageTheme.orange,
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
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  for (final r in overview.rarities)
                    Semantics(
                      key: ValueKey('wardrobe-rarity-${r.rarity.id}'),
                      container: true,
                      label:
                          '${r.rarity.name}: ${r.tally.text}${r.locked ? ', noch gesperrt' : ''}',
                      excludeSemantics: true,
                      child: SizedBox(
                        width: 90,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (r.locked)
                                  Icon(
                                    Icons.lock_outline,
                                    size: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  )
                                else
                                  CircleAvatar(
                                    radius: 5,
                                    backgroundColor: r.rarity.color,
                                  ),
                                const SizedBox(width: 6),
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
                            const SizedBox(height: 3),
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
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                pill(
                  key: const ValueKey('wardrobe-summary-crates'),
                  icon: Icons.inventory_2_outlined,
                  color: waitingCrates > 0 ? StageTheme.orange : null,
                  label: waitingCrates == 0
                      ? 'Keine Kiste wartet'
                      : waitingCrates == 1
                      ? '1 Kiste wartet'
                      : '$waitingCrates Kisten warten',
                  onTap: onCrates,
                ),
                if (overview.shiny > 0)
                  pill(
                    key: const ValueKey('wardrobe-summary-shiny'),
                    icon: Icons.auto_awesome,
                    color: const Color(0xFFE4AE39),
                    label: '${overview.shiny} in Glanz',
                  ),
                if (overview.uniques case final u?)
                  pill(
                    key: const ValueKey('wardrobe-summary-unique'),
                    icon: Icons.diamond_outlined,
                    color: const Color(0xFFB388FF),
                    label: 'Unique ${u.owned}/${u.total}',
                    semantics: 'Unique-Figuren: ${u.text} freigeschaltet',
                  ),
                if (gage case final gage?)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.payments_outlined, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        gage,
                        key: const ValueKey('wardrobe-gage'),
                        style: theme.textTheme.labelLarge,
                      ),
                    ],
                  ),
                if (gage != null)
                  TextButton.icon(
                    key: const ValueKey('wardrobe-trade'),
                    onPressed: onTrade,
                    icon: const Icon(Icons.handshake_outlined, size: 18),
                    label: const Text('Tauschen'),
                  ),
              ],
            ),
            if (overview.gift case final gift?) ...[
              const SizedBox(height: 6),
              Row(
                key: const ValueKey('wardrobe-summary-gift'),
                children: [
                  const Icon(
                    Icons.card_giftcard,
                    size: 16,
                    color: StageTheme.orange,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Geschenkt: ${giftName(gift)}. Weitere eigene Rollen kommen aus Kisten.',
                      style: theme.textTheme.bodySmall,
                    ),
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

/// "Elena als Lucy", for the present figure.
String giftName(WardrobeItem item) =>
    item.unique ? item.name : nameInRole(item.name, item.role);

/// The plays (and the technicians) side by side: how many roles of each are
/// collected, what is still missing by rarity, the way to the unique
/// figure. A tap shows only that play's figures.
class PlayProgressStrip extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
      1.0,
      2.0,
    );
    final complete = plays.where((p) => p.tally.complete).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Stücke & Technik',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(
                '$complete von ${plays.length} komplett',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 146 * scale,
          child: ListView.separated(
            key: const PageStorageKey('wardrobe-play-strip'),
            scrollDirection: Axis.horizontal,
            itemCount: plays.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) => SizedBox(
              width: 184 * scale,
              child: _PlayTile(
                plays[i],
                selected: plays[i].title == selected,
                onTap: onSelect == null ? null : () => onSelect!(plays[i]),
              ),
            ),
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

/// The crates in numbers: what waits by kind, what was opened, the shine
/// and the gage the duplicates brought.
class CrateBalanceCard extends StatelessWidget {
  const CrateBalanceCard({
    super.key,
    required this.waiting,
    required this.opened,
    required this.earned,
    required this.shiny,
    this.gageEarned,
    this.duplicates,
  });

  /// Waiting crates by kind ("Kostümkiste", count), only those with any.
  final List<(String, String, int)> waiting;
  final int opened, earned, shiny;
  final int? gageEarned, duplicates;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = waiting.fold(0, (n, w) => n + w.$3);
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
    final figures = [
      figure('opened', _number.format(opened), 'geöffnet'),
      figure('earned', _number.format(earned), 'erspielt'),
      figure('shiny', _number.format(shiny), 'in Glanz'),
      if (duplicates != null)
        figure('dupes', _number.format(duplicates), 'Duplikate'),
      if (gageEarned != null)
        figure('gage', _number.format(gageEarned), 'Gage verdient'),
    ];
    return Card(
      key: const ValueKey('crate-balance'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
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
                Text(
                  total == 0
                      ? 'nichts wartet'
                      : total == 1
                      ? '1 wartet'
                      : '$total warten',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            if (waiting.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final (singular, plural, n) in waiting)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(
                        Icons.inventory_2,
                        size: 16,
                        color: StageTheme.orange,
                      ),
                      label: Text('$n ${n == 1 ? singular : plural}'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final f in figures) Expanded(child: f)],
            ),
            const SizedBox(height: 8),
            Text(
              'Kostümkisten aus deinen Läufen; Glanz und Gage aus allen Kisten.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
