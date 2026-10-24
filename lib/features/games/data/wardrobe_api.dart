import 'dart:math';
import 'dart:ui' show Color;

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../domain/stage_runner.dart';

/// Whether the "Garderobe" (costume crates for the metres run) is offered:
/// the server must announce it. The demo has no server and no wardrobe: the
/// catalog and its pictures live on the server.
bool wardrobeAvailable(AppController controller) =>
    !controller.isDemo &&
    controller.supports('stageRunner') &&
    controller.supports('runnerUnlocks');

/// Duplicates, shine, gage, trades and purchases (`runnerDupes`).
bool dupesAvailable(AppController controller) =>
    wardrobeAvailable(controller) && controller.supports('runnerDupes');

/// The shared "Ensemble-Strecke" of all players (`runnerEnsemble`).
bool ensembleAvailable(AppController controller) =>
    wardrobeAvailable(controller) && controller.supports('runnerEnsemble');

/// What an item changes: exactly one of each kind is worn.
enum WardrobeKind {
  character('Figuren', 'Figur'),
  backdrop('Bühnenbilder', 'Bühnenbild'),
  obstacles('Hindernisse', 'Hindernis-Set'),
  fx('Effekte', 'Effekt');

  const WardrobeKind(this.plural, this.singular);
  final String plural, singular;

  static WardrobeKind? parse(Object? value) {
    for (final k in values) {
      if (k.name == value) return k;
    }
    return null;
  }
}

Color _color(Object? value, [Color fallback = const Color(0xFF9AA3AD)]) {
  final hex = textValue(value).replaceFirst('#', '');
  final parsed = hex.length == 6 ? int.tryParse(hex, radix: 16) : null;
  return parsed == null ? fallback : Color(0xFF000000 | parsed);
}

double _double(Object? value, [double fallback = 0]) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? fallback;

/// A rarity of the catalog, from common to rare in catalog order.
class WardrobeRarity {
  const WardrobeRarity({
    required this.id,
    required this.name,
    required this.color,
    this.weight = 1,
    this.rank = 0,
    this.style,
    this.hint,
    this.gage = 0,
    this.buyable = true,
  });
  final String id, name;
  final Color color;
  final double weight;

  /// What a duplicate of this rarity pays; whether one chosen item of it can
  /// be bought (gold cannot).
  final int gage;
  final bool buyable;

  /// 0 for the most common; higher is rarer.
  final int rank;

  /// A special look of the cards, e.g. `antique` (sepia with patina).
  final String? style;

  /// What unlocks the rarity while it is locked, e.g. "Sammle alle
  /// hellblauen Figuren".
  final String? hint;

  bool get antique => style == 'antique';

  static const unknown = WardrobeRarity(
    id: '',
    name: '',
    color: Color(0xFF9AA3AD),
  );
}

/// A department (Licht, Ton, …): only a label on the card, never a rarity.
class WardrobeDepartment {
  const WardrobeDepartment({required this.id, required this.name, this.icon});
  final String id, name;
  final String? icon;
}

/// Colour change of the default art, for stand-ins without a picture.
class WardrobeTint {
  const WardrobeTint({this.hue = 0, this.saturation = 1, this.brightness = 1});
  final double hue, saturation, brightness;

  factory WardrobeTint.fromJson(JsonMap json) => WardrobeTint(
    hue: _double(json['hue']),
    saturation: _double(json['saturation'], 1),
    brightness: _double(json['brightness'], 1),
  );
}

/// How an effect looks: a trail behind the flying runner.
class WardrobeEffect {
  const WardrobeEffect({required this.trail, required this.colors});
  final String trail;
  final List<Color> colors;

  factory WardrobeEffect.fromJson(JsonMap json) => WardrobeEffect(
    trail: textValue(json['trail'], 'sparkle'),
    colors: [for (final c in jsonList(json['colors'])) _color(c)],
  );
}

class WardrobeItem {
  const WardrobeItem({
    required this.id,
    required this.kind,
    required this.name,
    required this.rarity,
    this.rarities = const [],
    this.label,
    this.departments = const [],
    this.rarityReason,
    this.isDefault = false,
    this.placeholder = false,
    this.personId,
    this.image,
    this.portrait,
    this.harness = const {},
    this.tint,
    this.effect,
    this.reward = false,
    this.variants = const [],
  });
  final String id, name;

  /// An ensemble reward: everybody's once its milestone is reached.
  final bool reward;

  /// Role variants with their pictures (only available ones).
  final List<WardrobeVariant> variants;

  /// The main (rarest) rarity, and all of them: a hybrid has several and
  /// shows all their colours.
  final String rarity;
  final List<String> rarities;

  /// A label instead of the department names, e.g. "Bühnentechnik · Ensemble".
  final String? label;
  final WardrobeKind kind;
  final List<String> departments;
  final String? rarityReason;
  final bool isDefault, placeholder;
  final int? personId;

  /// API paths of the full picture (atlas or backdrop) and of the square
  /// portrait for the cards.
  final String? image, portrait;

  /// Where the flying wire meets the harness, by pose name, in pixels of
  /// the pose; poses left out keep the default.
  final Map<String, (double, double)> harness;
  final WardrobeTint? tint;
  final WardrobeEffect? effect;

  /// This item in the look of [variant] (its pictures and wire points);
  /// itself without one. The card's portrait falls back to the variant's
  /// atlas, never to the plain look.
  WardrobeItem inRole(WardrobeVariant? variant) => variant == null
      ? this
      : WardrobeItem(
          id: id,
          kind: kind,
          name: name,
          rarity: rarity,
          rarities: rarities,
          label: label,
          departments: departments,
          rarityReason: rarityReason,
          isDefault: isDefault,
          placeholder: placeholder,
          personId: personId,
          image: variant.image,
          portrait: variant.portrait,
          harness: variant.harness.isEmpty ? harness : variant.harness,
          tint: tint,
          effect: effect,
          reward: reward,
          variants: variants,
        );

  static WardrobeItem? fromJson(JsonMap json) {
    final kind = WardrobeKind.parse(json['kind']);
    if (kind == null) return null;
    String? path(Object? v) => v is String && v.isNotEmpty ? v : null;
    return WardrobeItem(
      reward: json['reward'] == true,
      variants: [
        for (final v in jsonList(json['variants']))
          ?WardrobeVariant.fromJson(jsonMap(v)),
      ],
      id: textValue(json['id']),
      kind: kind,
      name: textValue(json['name']),
      rarity: textValue(json['rarity']),
      rarities: [
        for (final r in jsonList(json['rarities'])) '$r',
        if (jsonList(json['rarities']).isEmpty) textValue(json['rarity']),
      ],
      label: path(json['label']),
      departments: [for (final d in jsonList(json['departments'])) '$d'],
      rarityReason: path(json['rarityReason']),
      isDefault: json['default'] == true,
      placeholder: json['placeholder'] == true,
      personId: json['personId'] is num ? intValue(json['personId']) : null,
      image: path(json['image']),
      portrait: path(json['portrait']),
      harness: _harness(json['harness']),
      tint: json['tint'] is Map
          ? WardrobeTint.fromJson(jsonMap(json['tint']))
          : null,
      effect: json['effect'] is Map
          ? WardrobeEffect.fromJson(jsonMap(json['effect']))
          : null,
    );
  }
}

Map<String, (double, double)> _harness(Object? json) => {
  for (final MapEntry(:key, :value) in jsonMap(json).entries)
    if (value is List && value.length == 2 && value.every((v) => v is num))
      key: ((value[0] as num).toDouble(), (value[1] as num).toDouble()),
};

/// A role of the person on a character card, e.g. "Julia (Romeo und Julia,
/// 2026)": its own atlas, portrait and wire points.
class WardrobeVariant {
  const WardrobeVariant({
    required this.id,
    required this.name,
    required this.image,
    this.portrait,
    this.harness = const {},
  });
  final String id, name, image;
  final String? portrait;
  final Map<String, (double, double)> harness;

  static WardrobeVariant? fromJson(JsonMap json) {
    final id = textValue(json['id']), image = textValue(json['image']);
    if (id.isEmpty || image.isEmpty) return null;
    final portrait = textValue(json['portrait']);
    return WardrobeVariant(
      id: id,
      name: textValue(json['name']),
      image: image,
      portrait: portrait.isEmpty ? null : portrait,
      harness: _harness(json['harness']),
    );
  }
}

/// How duplicates are paid and spent (`catalog.dupes`).
class DupeRules {
  const DupeRules({
    this.shinyChance = .03,
    this.tradeDupes = 5,
    this.buyDupes = 10,
  });
  final double shinyChance;
  final int tradeDupes, buyDupes;

  factory DupeRules.fromJson(JsonMap json) => DupeRules(
    shinyChance: _double(json['shinyChance'], .03),
    tradeDupes: json['tradeDupes'] is num ? intValue(json['tradeDupes']) : 5,
    buyDupes: json['buyDupes'] is num ? intValue(json['buyDupes']) : 10,
  );
}

class WardrobeCatalog {
  WardrobeCatalog({
    required this.rarities,
    required this.departments,
    required this.items,
    this.dupes = const DupeRules(),
    this.ensembleRarity,
  }) : _items = {for (final i in items) i.id: i},
       _rarities = {
         for (final r in rarities) r.id: r,
         ?ensembleRarity?.id: ?ensembleRarity,
       };

  /// The rarities of the draw, common to rare; the ensemble's look of its
  /// rewards is not one of them ([ensembleRarity]).
  final List<WardrobeRarity> rarities;
  final List<WardrobeDepartment> departments;

  /// All items, ensemble rewards included.
  final List<WardrobeItem> items;
  final DupeRules dupes;
  final WardrobeRarity? ensembleRarity;
  final Map<String, WardrobeItem> _items;
  final Map<String, WardrobeRarity> _rarities;

  WardrobeItem? item(String id) => _items[id];
  WardrobeRarity rarityOf(WardrobeItem item) =>
      _rarities[item.rarity] ?? WardrobeRarity.unknown;

  /// All rarities of [item], rarest first.
  List<WardrobeRarity> raritiesOf(WardrobeItem item) => [
    for (final id in item.rarities) _rarities[id] ?? WardrobeRarity.unknown,
  ];

  /// The label under the name: the free label or the department names.
  String? labelOf(WardrobeItem item) =>
      item.label ??
      (item.departments.isEmpty
          ? null
          : item.departments.map((d) => department(d)?.name ?? d).join(' · '));
  WardrobeDepartment? department(String id) =>
      departments.where((d) => d.id == id).firstOrNull;

  /// Items that can come from a crate (all but the default outfit and the
  /// ensemble rewards).
  Iterable<WardrobeItem> get collectible =>
      items.where((i) => !i.isDefault && !i.reward);

  /// The rarity right above [rarity], or null for the rarest.
  WardrobeRarity? above(WardrobeRarity rarity) =>
      rarity.rank + 1 < rarities.length ? rarities[rarity.rank + 1] : null;

  /// Chance of a rarity when every item can still be won, without the
  /// [locked] ones (the server passes the chance of used-up and locked
  /// rarities on to the others).
  double chance(WardrobeRarity rarity, [Set<String> locked = const {}]) {
    final present = rarities.where(
      (r) =>
          !locked.contains(r.id) &&
          collectible.any((i) => i.rarities.contains(r.id)),
    );
    final total = present.fold<double>(0, (n, r) => n + r.weight);
    return total <= 0 || !present.contains(rarity) ? 0 : rarity.weight / total;
  }

  factory WardrobeCatalog.fromJson(JsonMap json) => WardrobeCatalog(
    rarities: [
      for (final (i, r) in jsonList(json['rarities']).indexed)
        WardrobeRarity(
          id: textValue(jsonMap(r)['id']),
          name: textValue(jsonMap(r)['name']),
          color: _color(jsonMap(r)['color']),
          weight: _double(jsonMap(r)['weight'], 1),
          rank: i,
          style: jsonMap(r)['style'] as String?,
          hint: jsonMap(r)['hint'] as String?,
          gage: intValue(jsonMap(r)['gage']),
          buyable: jsonMap(r)['buyable'] != false,
        ),
    ],
    dupes: DupeRules.fromJson(jsonMap(json['dupes'])),
    ensembleRarity: json['ensembleRarity'] is Map
        ? WardrobeRarity(
            id: textValue(jsonMap(json['ensembleRarity'])['id'], 'ensemble'),
            name: textValue(
              jsonMap(json['ensembleRarity'])['name'],
              'Ensemble',
            ),
            color: _color(jsonMap(json['ensembleRarity'])['color']),
            rank: -1,
          )
        : null,
    departments: [
      for (final d in jsonList(json['departments']))
        WardrobeDepartment(
          id: textValue(jsonMap(d)['id']),
          name: textValue(jsonMap(d)['name']),
          icon: jsonMap(d)['icon'] as String?,
        ),
    ],
    // Rewards come apart from the items, so older apps leave them out.
    items: [
      for (final i in [
        ...jsonList(json['items']),
        ...jsonList(json['rewards']),
      ])
        ?WardrobeItem.fromJson(jsonMap(i)),
    ],
  );
}

/// Metres run and crates earned.
class RunnerProgress {
  const RunnerProgress({
    this.meters = 0,
    this.earned = 0,
    this.opened = 0,
    this.crates = 0,
    this.previousAt = 0,
    this.nextAt = 0,
    this.poolSize = 0,
    this.complete = false,
    this.gained = 0,
    this.newCrates = 0,
    this.ensembleCrates = 0,
    this.dupes = false,
    this.ensemble,
  });
  final int meters, earned, opened, crates, previousAt, nextAt, poolSize;

  /// Ensemble-Kisten waiting (`runnerEnsemble`).
  final int ensembleCrates;

  /// Crates open even when [complete]: they bring duplicates.
  final bool dupes;

  /// Only in the reply to a run: what it added to the ensemble.
  final EnsembleRun? ensemble;

  /// All crates waiting, the own and the ensemble's.
  int get waiting => crates + ensembleCrates;

  /// Whether a crate of the own metres can be opened now.
  bool get canOpen => crates > 0 && (dupes || !complete);

  /// Nothing left to win until new items arrive.
  final bool complete;

  /// Only in the reply to a run: its metres and the crates it brought.
  final int gained, newCrates;

  int get remaining => max(0, nextAt - meters);

  /// Share of the way from the last crate to the next one.
  double get fraction => nextAt <= previousAt
      ? 1
      : ((meters - previousAt) / (nextAt - previousAt)).clamp(0, 1).toDouble();

  factory RunnerProgress.fromJson(JsonMap json) => RunnerProgress(
    meters: intValue(json['meters']),
    earned: intValue(json['earned']),
    opened: intValue(json['opened']),
    crates: intValue(json['crates']),
    previousAt: intValue(json['previousAt']),
    nextAt: intValue(json['nextAt']),
    poolSize: intValue(json['poolSize']),
    complete: json['complete'] == true,
    gained: intValue(json['gained']),
    newCrates: intValue(json['newCrates']),
    ensembleCrates: intValue(json['ensembleCrates']),
    dupes: json['dupes'] == true,
    ensemble: json['ensemble'] is Map
        ? EnsembleRun.fromJson(jsonMap(json['ensemble']))
        : null,
  );
}

/// A milestone of the Ensemble-Strecke and what it unlocks.
class EnsembleMilestone {
  const EnsembleMilestone({
    required this.km,
    required this.name,
    this.note,
    this.rewardId,
    this.ready = false,
    this.reached = false,
  });
  final num km;
  final String name;
  final String? note;

  /// The reward item, if the milestone has one (else only the crate).
  final String? rewardId;

  /// Whether the reward has its picture already.
  final bool ready;
  final bool reached;

  int get meters => (km * 1000).round();

  factory EnsembleMilestone.fromJson(JsonMap json) => EnsembleMilestone(
    km: json['km'] is num ? json['km'] as num : 0,
    name: textValue(json['name']),
    note: json['note'] is String ? json['note'] as String : null,
    rewardId: json['reward'] is Map
        ? textValue(jsonMap(json['reward'])['itemId'])
        : null,
    ready: json['reward'] is Map && jsonMap(json['reward'])['ready'] == true,
    reached: json['reached'] == true,
  );
}

/// The shared distance of all players and the way to the next milestone.
class EnsembleProgress {
  const EnsembleProgress({
    required this.meters,
    required this.next,
    this.previousKm = 0,
    this.milestones = const [],
    this.crates = 0,
    this.unseen = const [],
    this.sectionOwn = 0,
    this.sectionPlayers = 0,
  });
  final int meters;
  final num previousKm;
  final EnsembleMilestone next;
  final List<EnsembleMilestone> milestones;

  /// Ensemble-Kisten waiting.
  final int crates;

  /// Reached milestones (km) not celebrated yet.
  final List<num> unseen;

  /// Own metres in the current section and how many took part in it.
  final int sectionOwn, sectionPlayers;

  int get remaining => max(0, next.meters - meters);

  double get fraction {
    final from = (previousKm * 1000).round(), to = next.meters;
    return to <= from
        ? 1
        : ((meters - from) / (to - from)).clamp(0, 1).toDouble();
  }

  EnsembleMilestone? milestone(num km) =>
      milestones.where((m) => m.km == km).firstOrNull;

  /// The milestone that unlocks [item], if it is a reward.
  EnsembleMilestone? rewardOf(WardrobeItem item) =>
      milestones.where((m) => m.rewardId == item.id).firstOrNull;

  factory EnsembleProgress.fromJson(JsonMap json) {
    final section = jsonMap(json['section']);
    return EnsembleProgress(
      meters: intValue(json['meters']),
      previousKm: json['previousKm'] is num ? json['previousKm'] as num : 0,
      next: EnsembleMilestone.fromJson(jsonMap(json['next'])),
      milestones: [
        for (final m in jsonList(json['milestones']))
          EnsembleMilestone.fromJson(jsonMap(m)),
      ],
      crates: intValue(json['crates']),
      unseen: [
        for (final km in jsonList(json['unseen']))
          if (km is num) km,
      ],
      sectionOwn: intValue(section['own']),
      sectionPlayers: intValue(section['players']),
    );
  }
}

/// What a run added to the ensemble, from the run's reply.
class EnsembleRun {
  const EnsembleRun({
    required this.gained,
    required this.meters,
    required this.next,
    this.reached = const [],
  });
  final int gained, meters;
  final EnsembleMilestone next;

  /// Milestones this very run reached.
  final List<EnsembleMilestone> reached;

  int get remaining => max(0, next.meters - meters);

  factory EnsembleRun.fromJson(JsonMap json) => EnsembleRun(
    gained: intValue(json['gained']),
    meters: intValue(json['meters']),
    next: EnsembleMilestone.fromJson(jsonMap(json['next'])),
    reached: [
      for (final m in jsonList(json['reached']))
        EnsembleMilestone.fromJson(jsonMap(m)),
    ],
  );
}

/// A Tauschvertrag on offer: gage for a random missing item of [to].
class TradeOption {
  const TradeOption({required this.from, required this.to, required this.cost});
  final String from, to;
  final int cost;
}

/// How the person's runs went.
class RunnerStats {
  const RunnerStats({
    this.rounds = 0,
    this.best = 0,
    this.meters = 0,
    this.creditedMeters = 0,
    this.deaths = const [],
    this.unknown = 0,
    this.untracked = 0,
  });
  final int rounds, best, meters;

  /// Part of [meters] credited once for runs before metres were counted.
  final int creditedMeters;

  /// Runs that ended at each obstacle, most often first.
  final List<(ObstacleKind, int)> deaths;

  /// Runs since the breakdown whose obstacle is unknown (older app).
  final int unknown;

  /// Runs from before the breakdown existed.
  final int untracked;

  factory RunnerStats.fromJson(JsonMap json) => RunnerStats(
    rounds: intValue(json['rounds']),
    best: intValue(json['best']),
    meters: intValue(json['meters']),
    creditedMeters: intValue(json['creditedMeters']),
    deaths: [
      for (final d in jsonList(json['deaths']))
        if (ObstacleKind.values
                .where((k) => k.name == jsonMap(d)['kind'])
                .firstOrNull
            case final kind?)
          (kind, intValue(jsonMap(d)['count'])),
    ]..sort((a, b) => b.$2.compareTo(a.$2)),
    unknown: intValue(json['unknown']),
    untracked: intValue(json['untracked']),
  );
}

/// The person's wardrobe: catalog, what they own and wear, progress and
/// statistics.
class Wardrobe {
  const Wardrobe({
    required this.catalog,
    required this.owned,
    required this.selected,
    this.lockedRarities = const {},
    this.progress = const RunnerProgress(),
    this.stats = const RunnerStats(),
    this.shiny = const {},
    this.variants = const {},
    this.selectedVariants = const {},
    this.gage = 0,
    this.gageEarned = 0,
    this.trades = const [],
    this.ensemble,
  });
  final WardrobeCatalog catalog;
  final Set<String> owned;
  final Map<WardrobeKind, String> selected;

  /// Items owned in their shiny version.
  final Set<String> shiny;

  /// Owned role variants, and the one worn per item.
  final Set<String> variants;
  final Map<String, String> selectedVariants;

  /// Gage to spend, and all ever earned.
  final int gage, gageEarned;
  final List<TradeOption> trades;
  final EnsembleProgress? ensemble;

  bool isShiny(WardrobeItem item) => shiny.contains(item.id);

  /// The worn role of [item], if one is chosen.
  WardrobeVariant? variantOf(WardrobeItem item) =>
      item.variants.where((v) => v.id == selectedVariants[item.id]).firstOrNull;

  /// What one chosen missing [item] costs; null if it cannot be bought
  /// (owned, a reward, gold).
  int? buyCost(WardrobeItem item) {
    if (owns(item) || item.reward || item.isDefault) return null;
    final rarity = catalog.rarityOf(item);
    if (!rarity.buyable || rarity.gage <= 0) return null;
    return catalog.dupes.buyDupes * rarity.gage;
  }

  /// Rarities not in the draw yet (see [WardrobeRarity.hint]).
  final Set<String> lockedRarities;
  final RunnerProgress progress;
  final RunnerStats stats;

  bool owns(WardrobeItem item) => item.isDefault || owned.contains(item.id);

  /// What unlocks [item] while it cannot come from a crate yet; null if it
  /// can.
  String? lockHint(WardrobeItem item) {
    if (owns(item) ||
        item.rarities.isEmpty ||
        !item.rarities.every(lockedRarities.contains)) {
      return null;
    }
    return catalog.rarityOf(item).hint ?? 'Noch gesperrt';
  }

  /// The worn item of [kind]; the default if the server named none.
  WardrobeItem? worn(WardrobeKind kind) =>
      catalog.item(selected[kind] ?? '') ??
      catalog.items.where((i) => i.kind == kind && i.isDefault).firstOrNull;

  int get collected => catalog.collectible.where(owns).length;
  int get collectible => catalog.collectible.length;

  factory Wardrobe.fromJson(JsonMap json) {
    final selected = jsonMap(json['selected']);
    final gage = jsonMap(json['gage']);
    return Wardrobe(
      shiny: {for (final id in jsonList(json['shiny'])) '$id'},
      variants: {for (final id in jsonList(json['variants'])) '$id'},
      selectedVariants: {
        for (final MapEntry(:key, :value) in jsonMap(
          json['selectedVariants'],
        ).entries)
          if (value is String) key: value,
      },
      gage: intValue(gage['balance']),
      gageEarned: intValue(gage['earned']),
      trades: [
        for (final t in jsonList(json['trades']))
          TradeOption(
            from: textValue(jsonMap(t)['from']),
            to: textValue(jsonMap(t)['to']),
            cost: intValue(jsonMap(t)['cost']),
          ),
      ],
      ensemble: json['ensemble'] is Map
          ? EnsembleProgress.fromJson(jsonMap(json['ensemble']))
          : null,
      catalog: WardrobeCatalog.fromJson(jsonMap(json['catalog'])),
      owned: {for (final id in jsonList(json['owned'])) '$id'},
      lockedRarities: {
        for (final id in jsonList(json['lockedRarities'])) '$id',
      },
      selected: {
        for (final k in WardrobeKind.values)
          if (selected[k.name] is String) k: selected[k.name] as String,
      },
      progress: RunnerProgress.fromJson(jsonMap(json['progress'])),
      stats: RunnerStats.fromJson(jsonMap(json['stats'])),
    );
  }
}

/// An opened crate: the won item and the cards of the reel, with the won one
/// at [winnerIndex].
class CrateOpening {
  const CrateOpening({
    required this.item,
    required this.reel,
    required this.winnerIndex,
    required this.wardrobe,
    this.outcome = const CrateOutcome(),
  });
  final WardrobeItem item;
  final List<WardrobeItem> reel;
  final int winnerIndex;
  final Wardrobe wardrobe;
  final CrateOutcome outcome;

  factory CrateOpening.fromJson(JsonMap json) {
    final wardrobe = Wardrobe.fromJson(jsonMap(json['wardrobe']));
    final item =
        WardrobeItem.fromJson(jsonMap(json['item'])) ??
        (throw const FormatException('Unbekanntes Teil'));
    final reel = [
      for (final id in jsonList(json['reel']))
        wardrobe.catalog.item('$id') ?? item,
    ];
    final winner = intValue(json['winnerIndex']);
    if (winner < 0 || winner >= reel.length) {
      throw const FormatException('Ungültige Walze');
    }
    return CrateOpening(
      item: item,
      reel: reel,
      winnerIndex: winner,
      wardrobe: wardrobe,
      outcome: CrateOutcome.fromJson(jsonMap(json['outcome'])),
    );
  }
}

/// What a crate, a trade or a purchase brought.
class CrateOutcome {
  const CrateOutcome({
    this.type = 'new',
    this.duplicate = false,
    this.shiny = false,
    this.ensemble = false,
    this.gage = 0,
    this.cost = 0,
    this.variantName,
    this.variantId,
  });

  /// `new`, `shine` (a duplicate made it shiny), `variant`, `gage`, `trade`
  /// or `buy`.
  final String type;
  final bool duplicate, shiny;

  /// From an Ensemble-Kiste.
  final bool ensemble;

  /// Gage won by a duplicate; gage spent on a trade or purchase.
  final int gage, cost;

  /// The new role, for `variant`.
  final String? variantName, variantId;

  /// Whether the shine is new: a shiny new item or a plain one made shiny.
  bool get shineNew => shiny && (type == 'new' || type == 'shine');

  /// The line under the won card for a duplicate; null for a new item.
  String? get line => switch (type) {
    'gage' => 'Duplikat → +$gage Gage',
    'variant' => 'Neue Rolle: ${variantName ?? ''}',
    'shine' => 'Duplikat → jetzt in Glanz!',
    'trade' => 'Aus dem Tauschvertrag (−$cost Gage)',
    'buy' => 'Gekauft für $cost Gage',
    _ => null,
  };

  factory CrateOutcome.fromJson(JsonMap json) => CrateOutcome(
    type: textValue(json['type'], 'new'),
    duplicate: json['duplicate'] == true,
    shiny: json['shiny'] == true,
    ensemble: json['crate'] == 'ensemble',
    gage: intValue(json['gage']),
    cost: intValue(json['cost']),
    variantName: json['variant'] is Map
        ? textValue(jsonMap(json['variant'])['name'])
        : null,
    variantId: json['variant'] is Map
        ? textValue(jsonMap(json['variant'])['id'])
        : null,
  );
}

/// The result of a trade or purchase: the item and the wardrobe after it.
class GageDeal {
  const GageDeal({
    required this.item,
    required this.wardrobe,
    required this.outcome,
  });
  final WardrobeItem item;
  final Wardrobe wardrobe;
  final CrateOutcome outcome;

  factory GageDeal.fromJson(JsonMap json) => GageDeal(
    item:
        WardrobeItem.fromJson(jsonMap(json['item'])) ??
        (throw const FormatException('Unbekanntes Teil')),
    wardrobe: Wardrobe.fromJson(jsonMap(json['wardrobe'])),
    outcome: CrateOutcome.fromJson(jsonMap(json['outcome'])),
  );
}

Future<Wardrobe> loadWardrobe(AppController controller) async =>
    Wardrobe.fromJson(await controller.remote('/games/runner/wardrobe'));

/// A fresh key per opening: a repeated request (after a lost reply) returns
/// the same crate instead of opening another one.
String crateKey([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Opens a crate of the own metres, or an Ensemble-Kiste with [ensemble].
/// With [dupes] (`runnerDupes`) the server may answer with a duplicate.
Future<CrateOpening> openCrate(
  AppController controller, {
  String? key,
  bool dupes = false,
  bool ensemble = false,
}) async => CrateOpening.fromJson(
  await controller.remote(
    '/games/runner/crates',
    method: 'POST',
    body: {if (dupes) 'dupes': true, if (ensemble) 'crate': 'ensemble'},
    idempotencyKey: key ?? crateKey(),
  ),
);

/// Wears [item]; [variant] picks one of its roles, [plainLook] goes back to
/// its own look. Without either the worn role stays.
Future<Wardrobe> wearItem(
  AppController controller,
  WardrobeItem item, {
  WardrobeVariant? variant,
  bool plainLook = false,
}) async => Wardrobe.fromJson(
  await controller.remote(
    '/games/runner/outfit',
    method: 'PUT',
    body: {
      'kind': item.kind.name,
      'itemId': item.id,
      if (variant != null)
        'variant': variant.id
      else if (plainLook)
        'variant': null,
    },
  ),
);

/// A Tauschvertrag from the rarity [from].
Future<GageDeal> tradeGage(
  AppController controller,
  String from, {
  String? key,
}) async => GageDeal.fromJson(
  await controller.remote(
    '/games/runner/trade',
    method: 'POST',
    body: {'rarity': from},
    idempotencyKey: key ?? crateKey(),
  ),
);

/// Buys one chosen missing [item] for gage.
Future<GageDeal> buyItem(
  AppController controller,
  WardrobeItem item, {
  String? key,
}) async => GageDeal.fromJson(
  await controller.remote(
    '/games/runner/buy',
    method: 'POST',
    body: {'itemId': item.id},
    idempotencyKey: key ?? crateKey(),
  ),
);

/// The celebration of the milestones up to [km] was shown.
Future<Wardrobe> markEnsembleSeen(AppController controller, num km) async =>
    Wardrobe.fromJson(
      await controller.remote(
        '/games/runner/ensemble/seen',
        method: 'PUT',
        body: {'km': km},
      ),
    );
