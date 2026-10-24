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
  });
  final String id, name;
  final Color color;
  final double weight;

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
  });
  final String id, name;

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

  static WardrobeItem? fromJson(JsonMap json) {
    final kind = WardrobeKind.parse(json['kind']);
    if (kind == null) return null;
    String? path(Object? v) => v is String && v.isNotEmpty ? v : null;
    return WardrobeItem(
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
      harness: {
        for (final MapEntry(:key, :value) in jsonMap(json['harness']).entries)
          if (value is List &&
              value.length == 2 &&
              value.every((v) => v is num))
            key: ((value[0] as num).toDouble(), (value[1] as num).toDouble()),
      },
      tint: json['tint'] is Map
          ? WardrobeTint.fromJson(jsonMap(json['tint']))
          : null,
      effect: json['effect'] is Map
          ? WardrobeEffect.fromJson(jsonMap(json['effect']))
          : null,
    );
  }
}

class WardrobeCatalog {
  WardrobeCatalog({
    required this.rarities,
    required this.departments,
    required this.items,
  }) : _items = {for (final i in items) i.id: i},
       _rarities = {for (final r in rarities) r.id: r};

  final List<WardrobeRarity> rarities;
  final List<WardrobeDepartment> departments;
  final List<WardrobeItem> items;
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

  /// Items that can come from a crate (all but the default outfit).
  Iterable<WardrobeItem> get collectible => items.where((i) => !i.isDefault);

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
        ),
    ],
    departments: [
      for (final d in jsonList(json['departments']))
        WardrobeDepartment(
          id: textValue(jsonMap(d)['id']),
          name: textValue(jsonMap(d)['name']),
          icon: jsonMap(d)['icon'] as String?,
        ),
    ],
    items: [
      for (final i in jsonList(json['items']))
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
  });
  final int meters, earned, opened, crates, previousAt, nextAt, poolSize;

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
  );
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
  });
  final WardrobeCatalog catalog;
  final Set<String> owned;
  final Map<WardrobeKind, String> selected;

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
    return Wardrobe(
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
  });
  final WardrobeItem item;
  final List<WardrobeItem> reel;
  final int winnerIndex;
  final Wardrobe wardrobe;

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
    );
  }
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

Future<CrateOpening> openCrate(AppController controller, {String? key}) async =>
    CrateOpening.fromJson(
      await controller.remote(
        '/games/runner/crates',
        method: 'POST',
        body: const {},
        idempotencyKey: key ?? crateKey(),
      ),
    );

Future<Wardrobe> wearItem(AppController controller, WardrobeItem item) async =>
    Wardrobe.fromJson(
      await controller.remote(
        '/games/runner/outfit',
        method: 'PUT',
        body: {'kind': item.kind.name, 'itemId': item.id},
      ),
    );
