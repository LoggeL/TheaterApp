import 'dart:math';
import 'dart:ui' show Color, Rect;

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../domain/stage_runner.dart';
import 'missions_api.dart';

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

/// The Tagesbonus (`runnerDailyBonus`): the first run of a Berlin calendar
/// day counts twice for the crates. The server always credits it; the app
/// only shows it when the server announces the feature.
bool dailyBonusAvailable(AppController controller) =>
    wardrobeAvailable(controller) && controller.supports('runnerDailyBonus');

/// The private "Termin-Kiste" for an own commitment to an event
/// (`runnerEventCrates`); it opens with duplicates, like the Missionskiste.
bool eventCratesAvailable(AppController controller) =>
    dupesAvailable(controller) && controller.supports('runnerEventCrates');

/// Set-specific crates earned by contributing to a released skin pack.
bool packGoalsAvailable(AppController controller) =>
    dupesAvailable(controller) && controller.supports('runnerPackGoals');

/// Role figures (`runnerRoleFigures`): every stage role is a figure of its
/// own with its own rarity, no role variants. The app asks for them with
/// `roles`; older servers keep sending a figure per person with variants.
bool roleFiguresAvailable(AppController controller) =>
    wardrobeAvailable(controller) && controller.supports('runnerRoleFigures');

/// Unique figures (`runnerUniqueFigures`): one non-human character per play,
/// unlocked by owning all of its role figures. The app asks for them with
/// `unique`; without it the server leaves them out entirely.
bool uniqueFiguresAvailable(AppController controller) =>
    roleFiguresAvailable(controller) &&
    controller.supports('runnerUniqueFigures');

/// Crate points (`runnerCratePoints`): the own crates count the runs'
/// points, not their metres. The app reads the unit from each progress
/// (`unit: points`), so this only says whether the server announced it.
bool cratePointsAvailable(AppController controller) =>
    wardrobeAvailable(controller) && controller.supports('runnerCratePoints');

/// Crate targets (`runnerCrateTargets`): a crate of the own runs opens as
/// the Zufallskiste or aimed at a play or the Technik-Kiste.
bool crateTargetsAvailable(AppController controller) =>
    dupesAvailable(controller) && controller.supports('runnerCrateTargets');

/// What the app tells the server it knows, for every wardrobe request.
Map<String, Object> _wardrobeFlags(AppController controller) => {
  if (roleFiguresAvailable(controller)) 'roles': true,
  if (uniqueFiguresAvailable(controller)) 'unique': true,
};

/// A Termin-Kiste waiting in the wardrobe: the event it came from, as it was
/// when the crate came (it stays when the event changes later).
class EventCrate {
  const EventCrate({required this.eventId, this.title = '', this.startsAt});
  final String eventId, title;
  final DateTime? startsAt;

  factory EventCrate.fromJson(JsonMap json) => EventCrate(
    eventId: textValue(json['eventId']),
    title: textValue(json['title']),
    startsAt: DateTime.tryParse(textValue(json['startsAt']))?.toLocal(),
  );
}

/// An active skin pack's shared goal. Dates and eligibility come from the
/// server; a device clock never reveals or awards a scheduled release.
class PackGoal {
  const PackGoal({
    required this.releaseId,
    required this.name,
    this.startsAt,
    this.goalMeters = 0,
    this.meters = 0,
    this.contributionMeters = 0,
    this.contributors = 0,
    this.reached = false,
    this.reachedAt,
    this.crateCount = 3,
    this.crates = 0,
    this.eligible = false,
  });

  final String releaseId, name;
  final DateTime? startsAt, reachedAt;
  final int goalMeters, meters, contributionMeters, contributors;
  final int crateCount, crates;
  final bool reached, eligible;

  int get remaining => max(0, goalMeters - meters);
  double get fraction =>
      goalMeters <= 0 ? 0 : (meters / goalMeters).clamp(0, 1).toDouble();

  factory PackGoal.fromJson(JsonMap json) => PackGoal(
    releaseId: textValue(json['releaseId']),
    name: textValue(json['name']),
    startsAt: DateTime.tryParse(textValue(json['startsAt']))?.toLocal(),
    goalMeters: max(0, intValue(json['goalMeters'])),
    meters: max(0, intValue(json['meters'])),
    contributionMeters: max(0, intValue(json['contributionMeters'])),
    contributors: max(0, intValue(json['contributors'])),
    reached: json['reached'] == true,
    reachedAt: DateTime.tryParse(textValue(json['reachedAt']))?.toLocal(),
    crateCount: max(0, intValue(json['crateCount'], 3)),
    crates: max(0, intValue(json['crates'])),
    eligible: json['eligible'] == true,
  );
}

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

/// `#RRGGBB` as an opaque colour; null for anything else.
Color? _colorOrNull(Object? value) {
  final hex = value is String ? value.replaceFirst('#', '') : '';
  final parsed = hex.length == 6 ? int.tryParse(hex, radix: 16) : null;
  return parsed == null ? null : Color(0xFF000000 | parsed);
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

  /// The unique figures' look: a holographic shimmer (`holo`).
  bool get holo => style == 'holo';

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
    this.unique = false,
    this.variants = const [],
    this.role,
    this.obstacles,
    this.obstacleCrashLines = const {},
    this.collectibles,
    this.collectibleNames = const {},
    this.borderColor,
    this.music,
    this.importance,
  });

  /// How much the role carries its play (0–100), from which its rarity was
  /// chosen; null for other items and older servers.
  final int? importance;

  /// [name] is the person's name for a character ("Elena").
  final String id, name;

  /// The role the person plays on this figure ("Lucy" in Creepshow 2026);
  /// null for older servers and for items without one. In [inRole] it is
  /// the variant's role.
  final WardrobeRole? role;

  /// An ensemble reward: everybody's once its milestone is reached.
  final bool reward;

  /// A unique figure: the non-human character of a play, unlocked by all
  /// of the play's role figures; never from a crate (`runnerUniqueFigures`).
  final bool unique;

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

  /// A backdrop's own obstacle set (API path of an atlas in the layout of
  /// the game's one) and the colour of its border, the short curtain the
  /// game draws; null for the default stage, other kinds and older servers.
  final String? obstacles;
  final Color? borderColor;

  /// Closing lines for this backdrop's own obstacles, by obstacle kind.
  final Map<String, String> obstacleCrashLines;

  /// A backdrop's own music (API path of AAC in M4A or MP3), looped during
  /// a run while it is worn; null for older servers and other kinds (the
  /// game's own tune plays).
  final String? music;

  /// A backdrop's own collectibles (API path of an atlas in the layout of
  /// the game's one, only the pickups used); null keeps the game's own.
  final String? collectibles;

  /// What the backdrop's collectibles are called, by [PickupKind] name
  /// (`rose`, `mask`, `star`); empty for the game's own.
  final Map<String, String> collectibleNames;

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
          unique: unique,
          variants: variants,
          role: variant.role,
          obstacles: obstacles,
          obstacleCrashLines: obstacleCrashLines,
          collectibles: collectibles,
          collectibleNames: collectibleNames,
          borderColor: borderColor,
          music: music,
          importance: importance,
        );

  static WardrobeItem? fromJson(JsonMap json) {
    final kind = WardrobeKind.parse(json['kind']);
    if (kind == null) return null;
    String? path(Object? v) => v is String && v.isNotEmpty ? v : null;
    return WardrobeItem(
      role: WardrobeRole.fromJson(json),
      reward: json['reward'] == true,
      unique: json['unique'] == true,
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
      obstacles: path(json['obstacles']),
      obstacleCrashLines: {
        for (final MapEntry(:key, :value) in jsonMap(
          json['obstacleCrashLines'],
        ).entries)
          if (value is String && value.trim().isNotEmpty) key: value,
      },
      collectibles: path(json['collectibles']),
      collectibleNames: {
        for (final MapEntry(:key, :value) in jsonMap(
          json['collectibleNames'],
        ).entries)
          if (value is String && value.isNotEmpty) key: value,
      },
      borderColor: _colorOrNull(json['borderColor']),
      music: path(json['music']),
      importance: json['importance'] is num
          ? (json['importance'] as num).round()
          : null,
    );
  }
}

Map<String, (double, double)> _harness(Object? json) => {
  for (final MapEntry(:key, :value) in jsonMap(json).entries)
    if (value is List && value.length == 2 && value.every((v) => v is num))
      key: ((value[0] as num).toDouble(), (value[1] as num).toDouble()),
};

/// The role a person plays on a figure: [role] "Lucy" in [play]
/// "Creepshow" ([year] 2026). Technicians work across plays: their function
/// ("Lichttechnik") without play and year ([isFunction]).
class WardrobeRole {
  const WardrobeRole(this.role, {this.play, this.year});
  final String role;
  final String? play;
  final int? year;

  /// "Creepshow 2026"; null without play and year.
  String? get production {
    final text = [?play, ?year?.toString()].join(' ');
    return text.isEmpty ? null : text;
  }

  /// A function such as "Lichttechnik": no play, no year.
  bool get isFunction => production == null;

  /// The line under the name: "als Lucy · Creepshow 2026"; a function
  /// alone ("Lichttechnik").
  String get line => isFunction ? role : 'als $role · $production';

  /// From `role`, `play` and `year` of an item or variant; null without a
  /// role (older servers).
  static WardrobeRole? fromJson(JsonMap json) {
    final role = textValue(json['role']).trim();
    if (role.isEmpty) return null;
    final play = textValue(json['play']).trim();
    return WardrobeRole(
      role,
      play: play.isEmpty ? null : play,
      year: json['year'] is num ? intValue(json['year']) : null,
    );
  }

  static final _name = RegExp(r'^(.+) \((.+), (\d{4})\)$');

  /// From a variant's name "Johanna (Anno 1146, 2025)", as servers without
  /// the structured fields send it; a name without play and year is the
  /// role alone.
  static WardrobeRole? parse(String name) {
    final text = name.trim();
    if (text.isEmpty) return null;
    final m = _name.firstMatch(text);
    return m == null
        ? WardrobeRole(text)
        : WardrobeRole(m[1]!, play: m[2], year: int.parse(m[3]!));
  }

  @override
  bool operator ==(Object other) =>
      other is WardrobeRole &&
      other.role == role &&
      other.play == play &&
      other.year == year;

  @override
  int get hashCode => Object.hash(role, play, year);

  @override
  String toString() => line;
}

/// A role of the person on a character card, e.g. Julia in Romeo und Julia
/// (2026): its own atlas, portrait and wire points. [name] is "Julia (Romeo
/// und Julia, 2026)" as older servers send it.
class WardrobeVariant {
  const WardrobeVariant({
    required this.id,
    required this.name,
    required this.image,
    this.portrait,
    this.harness = const {},
    this.role,
  });
  final String id, name, image;
  final String? portrait;
  final Map<String, (double, double)> harness;
  final WardrobeRole? role;

  /// The role's name for a chip ("Julia"); the full name without a role.
  String get roleName => role?.role ?? name;

  static WardrobeVariant? fromJson(JsonMap json) {
    final id = textValue(json['id']), image = textValue(json['image']);
    if (id.isEmpty || image.isEmpty) return null;
    final portrait = textValue(json['portrait']);
    final name = textValue(json['name']);
    return WardrobeVariant(
      id: id,
      name: name,
      image: image,
      portrait: portrait.isEmpty ? null : portrait,
      harness: _harness(json['harness']),
      role: WardrobeRole.fromJson(json) ?? WardrobeRole.parse(name),
    );
  }
}

/// "Elena als Lucy", the person and the role of a character; with a
/// function "Florian (Lichttechnik)"; the name alone without a role (Engel
/// Logge, older servers).
String nameInRole(String name, WardrobeRole? role) => switch (role) {
  null => name,
  final r when r.isFunction => '$name (${r.role})',
  final r => '$name als ${r.role}',
};

/// How duplicates are paid and spent (`catalog.dupes`).
class DupeRules {
  const DupeRules({
    this.shinyChances = const {'costume': .03, 'ensemble': .03},
    this.tradeDupes = 5,
    this.buyDupes = 10,
  });

  /// The chance of a shine per crate kind (`costume`, `ensemble`, …).
  final Map<String, double> shinyChances;
  final int tradeDupes, buyDupes;

  /// The chance of a shine in a crate of [kind]; a kind not listed has
  /// the chance of the own costume crate, like on the server.
  double shinyChanceOf(String kind) =>
      shinyChances[kind] ?? shinyChances['costume'] ?? .03;

  /// The chance of a shine in the own costume crate.
  double get shinyChance => shinyChanceOf('costume');

  factory DupeRules.fromJson(JsonMap json) => DupeRules(
    shinyChances: _shinyChances(json['shinyChance']),
    tradeDupes: json['tradeDupes'] is num ? intValue(json['tradeDupes']) : 5,
    buyDupes: json['buyDupes'] is num ? intValue(json['buyDupes']) : 10,
  );

  // One number for all kinds (older servers) or one per kind.
  static Map<String, double> _shinyChances(Object? value) {
    if (value is num) {
      return {'costume': value.toDouble(), 'ensemble': value.toDouble()};
    }
    return {
      'costume': .03,
      'ensemble': .03,
      if (value is Map)
        for (final e in value.entries)
          if (e.value is num) '${e.key}': (e.value as num).toDouble(),
    };
  }
}

class WardrobeCatalog {
  WardrobeCatalog({
    required this.rarities,
    required this.departments,
    required this.items,
    this.dupes = const DupeRules(),
    this.ensembleRarity,
    this.uniqueRarity,
  }) : _items = {for (final i in items) i.id: i},
       _rarities = {
         for (final r in rarities) r.id: r,
         ?ensembleRarity?.id: ?ensembleRarity,
         ?uniqueRarity?.id: ?uniqueRarity,
       };

  /// The rarities of the draw, common to rare; the ensemble's look of its
  /// rewards is not one of them ([ensembleRarity]).
  final List<WardrobeRarity> rarities;
  final List<WardrobeDepartment> departments;

  /// All items, ensemble rewards included.
  final List<WardrobeItem> items;
  final DupeRules dupes;
  final WardrobeRarity? ensembleRarity;

  /// The look of the unique figures (holographic), apart from the draw.
  final WardrobeRarity? uniqueRarity;
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

  /// The catalog with only the items [keep] lets through.
  WardrobeCatalog where(bool Function(WardrobeItem item) keep) =>
      WardrobeCatalog(
        rarities: rarities,
        departments: departments,
        items: [...items.where(keep)],
        dupes: dupes,
        ensembleRarity: ensembleRarity,
        uniqueRarity: uniqueRarity,
      );

  /// Items that can come from a crate (all but the default outfit, the
  /// ensemble rewards and the unique figures).
  Iterable<WardrobeItem> get collectible =>
      items.where((i) => !i.isDefault && !i.reward && !i.unique);

  /// The unique figures the person has unlocked (the server sends no other).
  Iterable<WardrobeItem> get uniques => items.where((i) => i.unique);

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
    uniqueRarity: json['uniqueRarity'] is Map
        ? WardrobeRarity(
            id: textValue(jsonMap(json['uniqueRarity'])['id'], 'unique'),
            name: textValue(jsonMap(json['uniqueRarity'])['name'], 'Unique'),
            color: _color(
              jsonMap(json['uniqueRarity'])['color'],
              const Color(0xFFB388FF),
            ),
            style: textValue(jsonMap(json['uniqueRarity'])['style'], 'holo'),
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
    // Rewards and unique figures come apart from the items, so older apps
    // leave them out.
    items: [
      for (final i in [
        ...jsonList(json['items']),
        ...jsonList(json['rewards']),
        ...jsonList(json['uniques']),
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
    int? runMeters,
    this.bonusMeters = 0,
    this.bonusOpen = false,
    this.bonus = 0,
    this.missionMeters = 0,
    this.missionCrates = 0,
    this.missionBonus = 0,
    this.missions,
    this.eventCrates = 0,
    this.packCrates = 0,
    this.points,
    this.gainedPoints,
  }) : runMeters = runMeters ?? meters;

  /// The crate points and where they come from (`runnerCratePoints`); null
  /// for older servers, whose [meters], [previousAt] and [nextAt] are metres.
  /// With them those three are points.
  final CratePoints? points;

  /// Only in the reply to a run: the crate points it brought.
  final GainedPoints? gainedPoints;

  /// Whether the crates count points ([points]) rather than metres.
  bool get inPoints => points != null;

  /// Termin-Kisten waiting (`runnerEventCrates`).
  final int eventCrates;

  /// Set-Kisten earned through skin-pack goals (`runnerPackGoals`).
  final int packCrates;

  /// Crate metres from Tagesmissionen in total (part of [meters]) and
  /// Missionskisten waiting (`runnerMissions`).
  final int missionMeters, missionCrates;

  /// Only in the reply to a run: the crate metres its missions brought, and
  /// the day's missions after it.
  final int missionBonus;
  final DailyMissions? missions;

  /// [meters] is the "Kistenstrecke": the metres run plus all Tagesbonus
  /// metres; [previousAt] and [nextAt] are measured on it.
  final int meters, earned, opened, crates, previousAt, nextAt, poolSize;

  /// The metres really run, and the Tagesbonus metres on top
  /// (`runnerDailyBonus`; older servers send neither).
  final int runMeters, bonusMeters;

  /// Whether today's Tagesbonus is still open.
  final bool bonusOpen;

  /// Only in the reply to a run: the Tagesbonus it brought (0 or [gained]).
  final int bonus;

  /// Ensemble-Kisten waiting (`runnerEnsemble`).
  final int ensembleCrates;

  /// Crates open even when [complete]: they bring duplicates.
  final bool dupes;

  /// Only in the reply to a run: what it added to the ensemble.
  final EnsembleRun? ensemble;

  /// All crates waiting: the own, the ensemble's, the missions' and the
  /// events'.
  int get waiting =>
      crates + ensembleCrates + missionCrates + eventCrates + packCrates;

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
    runMeters: json['runMeters'] is num ? intValue(json['runMeters']) : null,
    bonusMeters: intValue(json['bonusMeters']),
    bonusOpen: json['bonusOpen'] == true,
    bonus: intValue(json['bonus']),
    missionMeters: intValue(json['missionMeters']),
    missionCrates: intValue(json['missionCrates']),
    missionBonus: intValue(json['missionBonus']),
    missions: json['missions'] is Map
        ? DailyMissions.fromJson(jsonMap(json['missions']))
        : null,
    eventCrates: intValue(json['eventCrates']),
    packCrates: intValue(json['packCrates']),
    points: json['unit'] == 'points' && json['points'] is Map
        ? CratePoints.fromJson(jsonMap(json['points']))
        : null,
    gainedPoints: json['gainedPoints'] is Map
        ? GainedPoints.fromJson(jsonMap(json['gainedPoints']))
        : null,
  );
}

/// The crate points of the own runs: [total] = [base] (moved over from the
/// crate metres of before) + [runs] + [bonus] (Tagesbonus) + [missions].
class CratePoints {
  const CratePoints({
    this.total = 0,
    this.base = 0,
    this.runs = 0,
    this.bonus = 0,
    this.missions = 0,
  });
  final int total, base, runs, bonus, missions;

  factory CratePoints.fromJson(JsonMap json) => CratePoints(
    total: intValue(json['total']),
    base: intValue(json['base']),
    runs: intValue(json['runs']),
    bonus: intValue(json['bonus']),
    missions: intValue(json['missions']),
  );
}

/// What one run brought in crate points: its own, the Tagesbonus and its
/// missions.
class GainedPoints {
  const GainedPoints({this.run = 0, this.bonus = 0, this.missions = 0});
  final int run, bonus, missions;

  factory GainedPoints.fromJson(JsonMap json) => GainedPoints(
    run: intValue(json['run']),
    bonus: intValue(json['bonus']),
    missions: intValue(json['missions']),
  );
}

/// What a crate of the own runs can be opened as (`runnerCrateTargets`).
enum CrateTargetKind { random, tech, play }

/// A crate of the own runs as the Zufallskiste, the Technik-Kiste or aimed at
/// one play: its pool's progress ([owned] of [total], [locked] of them not to
/// be drawn yet), the chances within it and its pictures and animation.
class CrateTarget {
  const CrateTarget({
    required this.id,
    required this.kind,
    required this.name,
    this.play,
    this.year,
    this.animation = 'generic',
    this.image,
    this.imageBox,
    this.openImage,
    this.fxImage,
    this.owned = 0,
    this.total = 0,
    this.locked = 0,
    this.complete = false,
    this.available = true,
    this.shinyChance = .03,
    this.odds = const [],
  });

  /// The Zufallskiste as older servers have it: all items, nothing aimed.
  static const random = CrateTarget(
    id: 'random',
    kind: CrateTargetKind.random,
    name: 'Zufallskiste',
  );

  final String id, name;
  final CrateTargetKind kind;
  final String? play;
  final int? year;

  /// How it opens: `burst`, `flightcase`, `maw`, `glitch`, `heavy`,
  /// `threads`, or `generic` (also for any the app does not know).
  final String animation;

  /// Closed, open (the same frame) and its particles; null until there.
  final String? image, openImage, fxImage;

  /// Where the crate stands in [image] (pixels): the canvas leaves room
  /// above it for the open lid, the choice's cards show just this part.
  final Rect? imageBox;
  final int owned, total, locked;

  /// All of its items owned: it still opens, with duplicates (shine, gage).
  final bool complete;

  /// Whether something can be drawn from it now (not all locked).
  final bool available;
  final double shinyChance;

  /// The chance of each rarity within it.
  final List<(String, double)> odds;

  bool get isRandom => kind == CrateTargetKind.random;

  /// "Creepshow 2026", "Technik-Kiste", "Zufallskiste"; a play with a
  /// number in its name keeps it alone ("Anno 1146", not "Anno 1146 2025").
  String get title =>
      kind == CrateTargetKind.play && !RegExp(r'\d{4}').hasMatch(name)
      ? [name, ?year].join(' ')
      : name;

  factory CrateTarget.fromJson(JsonMap json) => CrateTarget(
    id: textValue(json['id'], 'random'),
    kind:
        CrateTargetKind.values
            .where((k) => k.name == json['kind'])
            .firstOrNull ??
        CrateTargetKind.play,
    name: textValue(json['name']),
    play: json['play'] is String ? json['play'] as String : null,
    year: json['year'] is num ? intValue(json['year']) : null,
    animation: textValue(json['animation'], 'generic'),
    image: json['image'] is String ? json['image'] as String : null,
    imageBox: _box(json['imageBox']),
    openImage: json['openImage'] is String ? json['openImage'] as String : null,
    fxImage: json['fxImage'] is String ? json['fxImage'] as String : null,
    owned: intValue(json['owned']),
    total: intValue(json['total']),
    locked: intValue(json['locked']),
    complete: json['complete'] == true,
    available: json['available'] != false,
    shinyChance: _double(json['shinyChance'], .03),
    odds: [
      for (final o in jsonList(json['odds']))
        (textValue(jsonMap(o)['rarity']), _double(jsonMap(o)['chance'], 0)),
    ],
  );
}

/// `[x0, y0, x1, y1]` as a rect; null unless that is what it is.
Rect? _box(Object? value) {
  final v = value is List ? value : const [];
  if (v.length != 4 || !v.every((x) => x is num)) return null;
  final box = Rect.fromLTRB(
    (v[0] as num).toDouble(),
    (v[1] as num).toDouble(),
    (v[2] as num).toDouble(),
    (v[3] as num).toDouble(),
  );
  return box.isEmpty ? null : box;
}

/// What a milestone not reached yet is called while its reward is a surprise.
const ensembleSurpriseName = '???';

/// A milestone of the Ensemble-Strecke and what it unlocks.
class EnsembleMilestone {
  const EnsembleMilestone({
    required this.km,
    required this.name,
    this.note,
    this.rewardId,
    this.rewardKind,
    this.ready = false,
    this.reached = false,
    this.hidden = false,
  });
  final num km;

  /// [ensembleSurpriseName] while [hidden].
  final String name;
  final String? note;

  /// The reward item, if the milestone has one (else only the crate); null
  /// while [hidden].
  final String? rewardId;

  /// What kind of item it unlocks ("Bühnenbild"); null while [hidden] and
  /// from older servers.
  final WardrobeKind? rewardKind;

  /// Whether the reward has its picture already.
  final bool ready;
  final bool reached;

  /// Its reward is still a surprise, either until the distance is reached
  /// or until its scheduled release. No name, picture or kind is revealed.
  final bool hidden;

  int get meters => (km * 1000).round();

  factory EnsembleMilestone.fromJson(JsonMap json) {
    final reached = json['reached'] == true;
    final reward = json['reward'] is Map ? jsonMap(json['reward']) : null;
    // An explicit gate still applies after the distance is reached. Older
    // servers that name unreached rewards are also kept private here.
    final hidden = json['hidden'] == true || (!reached && reward != null);
    return EnsembleMilestone(
      km: json['km'] is num ? json['km'] as num : 0,
      name: hidden ? ensembleSurpriseName : textValue(json['name']),
      note: !hidden && json['note'] is String ? json['note'] as String : null,
      rewardId: hidden || reward == null ? null : textValue(reward['itemId']),
      rewardKind: hidden ? null : WardrobeKind.parse(reward?['kind']),
      ready: !hidden && reward?['ready'] == true,
      reached: reached,
      hidden: hidden,
    );
  }
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
    this.bonusMeters = 0,
    this.missionMeters = 0,
    this.deaths = const [],
    this.unknown = 0,
    this.untracked = 0,
    this.points = 0,
    this.bonusPoints = 0,
    this.missionPoints = 0,
    this.basePoints = 0,
    this.crateMeters = 0,
  });
  final int rounds, best, meters;

  /// Crate points (`runnerCratePoints`): of all runs since, Tagesbonus,
  /// missions, and the base moved over from the [crateMeters] of before.
  final int points, bonusPoints, missionPoints, basePoints, crateMeters;

  /// Part of [meters] credited once for runs before metres were counted.
  final int creditedMeters;

  /// Tagesbonus metres in total; not part of [meters], they count only for
  /// the crates.
  final int bonusMeters;

  /// Crate metres from Tagesmissionen in total; like [bonusMeters] not part
  /// of [meters].
  final int missionMeters;

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
    bonusMeters: intValue(json['bonusMeters']),
    missionMeters: intValue(json['missionMeters']),
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
    points: intValue(json['points']),
    bonusPoints: intValue(json['bonusPoints']),
    missionPoints: intValue(json['missionPoints']),
    basePoints: intValue(json['basePoints']),
    crateMeters: intValue(json['crateMeters']),
  );
}

/// One play on the way to a unique figure across plays: [have] of its
/// [total] active role figures owned.
class UniqueFigurePart {
  const UniqueFigurePart({
    required this.play,
    this.year,
    this.have = 0,
    this.total = 0,
  });
  final String play;
  final int? year;
  final int have, total;

  /// "Creepshow 2026: 15/28".
  String get line => '${[play, ?year?.toString()].join(' ')}: $have/$total';

  static UniqueFigurePart? fromJson(JsonMap json) {
    final play = textValue(json['play']).trim();
    if (play.isEmpty) return null;
    return UniqueFigurePart(
      play: play,
      year: json['year'] is num ? intValue(json['year']) : null,
      have: intValue(json['have']),
      total: intValue(json['total']),
    );
  }
}

/// A play's way to its unique figure: [have] of its [total] active role
/// figures owned. Until it is [unlocked] the server sends neither its id nor
/// its name ([name] is "???"). A figure across plays (Captain Kuschel, from
/// 0.11.5) is one entry: [play] names them all ("Creepshow und Nexus"),
/// without [year], [have]/[total] summed up and [parts] per play.
class UniqueFigureProgress {
  const UniqueFigureProgress({
    required this.play,
    this.year,
    this.have = 0,
    this.total = 0,
    this.unlocked = false,
    this.itemId,
    this.name = '???',
    this.parts = const [],
    this.allTechnicians = false,
  });
  final String play, name;
  final int? year;
  final int have, total;
  final bool unlocked;

  /// All active collectible technicians, independent of the actors' roles.
  final bool allTechnicians;
  final String? itemId;

  /// Per play of a figure across plays; empty for a single play.
  final List<UniqueFigurePart> parts;

  /// Whether it needs the role figures of several plays.
  bool get several => parts.length > 1;

  /// "Creepshow 2026", or "Creepshow und Nexus" across plays.
  String get production =>
      allTechnicians ? 'Technik' : [play, ?year?.toString()].join(' ');

  /// "9/14 Rollen aus Creepshow", "23/52 Rollen aus Creepshow und Nexus".
  String get line => allTechnicians
      ? '$have/$total Techniker gesammelt'
      : '$have/$total Rollen aus $play';

  static UniqueFigureProgress? fromJson(JsonMap json) {
    final play = textValue(json['play']).trim();
    if (play.isEmpty) return null;
    final unlocked = json['unlocked'] == true;
    final id = textValue(json['itemId']);
    return UniqueFigureProgress(
      play: play,
      year: json['year'] is num ? intValue(json['year']) : null,
      have: intValue(json['have']),
      total: intValue(json['total']),
      unlocked: unlocked && id.isNotEmpty,
      itemId: unlocked && id.isNotEmpty ? id : null,
      name: unlocked ? textValue(json['name'], '???') : '???',
      allTechnicians: json['allTechnicians'] == true,
      parts: [
        for (final p in jsonList(json['plays']))
          if (p is Map) ?UniqueFigurePart.fromJson(jsonMap(p)),
      ],
    );
  }
}

/// The unique figures of all plays (`runnerUniqueFigures`): the progress per
/// play and the unlocked ones not celebrated yet.
class UniqueFigures {
  const UniqueFigures({this.plays = const [], this.unseen = const []});
  final List<UniqueFigureProgress> plays;
  final List<String> unseen;

  factory UniqueFigures.fromJson(JsonMap json) => UniqueFigures(
    plays: [
      for (final p in jsonList(json['plays']))
        if (p is Map) ?UniqueFigureProgress.fromJson(jsonMap(p)),
    ],
    unseen: [for (final id in jsonList(json['unseen'])) '$id'],
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
    this.eventCrates = const [],
    this.packGoals = const [],
    this.uniqueFigures,
    this.crateTargets = const [],
  });
  final WardrobeCatalog catalog;

  /// What a crate of the own runs can be opened as (`runnerCrateTargets`):
  /// the Zufallskiste first; empty for older servers.
  final List<CrateTarget> crateTargets;

  /// The target [id], if the server offers it.
  CrateTarget? crateTarget(String? id) =>
      crateTargets.where((t) => t.id == id).firstOrNull;

  /// The way to each play's unique figure; null for older servers.
  final UniqueFigures? uniqueFigures;

  /// Termin-Kisten waiting, the earliest event first (`runnerEventCrates`).
  final List<EventCrate> eventCrates;

  /// Only released packs, including completed goals and their waiting crates.
  final List<PackGoal> packGoals;

  PackGoal? packGoal(String releaseId) =>
      packGoals.where((goal) => goal.releaseId == releaseId).firstOrNull;

  int get packCrates => packGoals.fold(0, (sum, goal) => sum + goal.crates);
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

  /// The role [item] is worn in: the chosen variant's, else the figure's own.
  WardrobeRole? roleOf(WardrobeItem item) {
    final variant = variantOf(item);
    return variant == null ? item.role : variant.role;
  }

  /// The worn character as "Elena als Lucy" (its chosen role), e.g. for the
  /// game's intro; [fallback] without a wardrobe.
  String wornCharacterName([String fallback = 'Engel Logge']) {
    final item = worn(WardrobeKind.character);
    if (item == null) return fallback;
    // A unique figure is the character itself ("Captain Kuschel").
    return item.unique ? item.name : nameInRole(item.name, roleOf(item));
  }

  /// What one chosen missing [item] costs; null if it cannot be bought
  /// (owned, a reward, gold).
  int? buyCost(WardrobeItem item) {
    if (owns(item) || item.reward || item.unique || item.isDefault) return null;
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
    final owned = {for (final id in jsonList(json['owned'])) '$id'};
    final ensemble = json['ensemble'] is Map
        ? EnsembleProgress.fromJson(jsonMap(json['ensemble']))
        : null;
    // A reward is shown once its milestone is reached; the server leaves
    // the others out, the app does too if one from before sends them.
    final catalog = WardrobeCatalog.fromJson(jsonMap(json['catalog'])).where(
      (i) =>
          !i.reward ||
          owned.contains(i.id) ||
          ensemble?.rewardOf(i)?.reached == true,
    );
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
      ensemble: ensemble,
      uniqueFigures: json['uniqueFigures'] is Map
          ? UniqueFigures.fromJson(jsonMap(json['uniqueFigures']))
          : null,
      eventCrates: [
        for (final e in jsonList(json['eventCrates']))
          if (e is Map) EventCrate.fromJson(jsonMap(e)),
      ],
      packGoals: [
        for (final goal in jsonList(json['packGoals']))
          if (goal is Map) PackGoal.fromJson(jsonMap(goal)),
      ],
      crateTargets: [
        for (final t in jsonList(json['crateTargets']))
          if (t is Map) CrateTarget.fromJson(jsonMap(t)),
      ],
      catalog: catalog,
      owned: owned,
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
    this.variantRole,
    this.event,
    this.target,
    this.packId,
    this.packName,
  });

  /// A crate of the own runs: what it was opened as (`random`, `tech`,
  /// `play:<slug>`); null from older servers and for other crates.
  final String? target;

  /// The immutable set this contributor reward came from.
  final String? packId, packName;

  /// From a Termin-Kiste: the event it came from.
  final EventCrate? event;

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
  final WardrobeRole? variantRole;

  /// Whether the shine is new: a shiny new item or a plain one made shiny.
  bool get shineNew => shiny && (type == 'new' || type == 'shine');

  /// The line under the won card for a duplicate; null for a new item.
  String? get line => switch (type) {
    'gage' => 'Duplikat → +$gage Gage',
    'variant' => switch (variantRole) {
      final r? => 'Neue Rolle: ${[r.role, ?r.production].join(' · ')}',
      null => 'Neue Rolle: ${variantName ?? ''}',
    },
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
    variantRole: json['variant'] is Map
        ? WardrobeRole.fromJson(jsonMap(json['variant'])) ??
              WardrobeRole.parse(textValue(jsonMap(json['variant'])['name']))
        : null,
    event: json['crate'] == 'event' && json['event'] is Map
        ? EventCrate.fromJson(jsonMap(json['event']))
        : null,
    target: json['target'] is String ? json['target'] as String : null,
    packId: json['crate'] == 'pack' ? textValue(json['packId']) : null,
    packName: json['crate'] == 'pack' ? textValue(json['name']) : null,
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
    Wardrobe.fromJson(
      await controller.remote(
        uniqueFiguresAvailable(controller)
            ? '/games/runner/wardrobe?roles=1&unique=1'
            : roleFiguresAvailable(controller)
            ? '/games/runner/wardrobe?roles=1'
            : '/games/runner/wardrobe',
      ),
    );

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
/// [event] opens a Termin-Kiste: the one of [eventId], else the earliest.
/// [target] aims a crate of the own runs (`runnerCrateTargets`); without it
/// (or `random`) it is the Zufallskiste, as for older apps.
Future<CrateOpening> openCrate(
  AppController controller, {
  String? key,
  bool dupes = false,
  bool ensemble = false,
  bool mission = false,
  bool event = false,
  String? eventId,
  String? target,
  String? packId,
}) async => CrateOpening.fromJson(
  await controller.remote(
    '/games/runner/crates',
    method: 'POST',
    body: {
      if (dupes) 'dupes': true,
      if (ensemble) 'crate': 'ensemble',
      if (mission) 'crate': 'mission',
      if (event) 'crate': 'event',
      if (packId != null) 'crate': 'pack',
      'packId': ?packId,
      if (event && eventId != null) 'eventId': eventId,
      if (target != null && !ensemble && !mission && !event && packId == null)
        'target': target,
      ..._wardrobeFlags(controller),
    },
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
      ..._wardrobeFlags(controller),
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
    body: {'rarity': from, ..._wardrobeFlags(controller)},
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
    body: {'itemId': item.id, ..._wardrobeFlags(controller)},
    idempotencyKey: key ?? crateKey(),
  ),
);

/// The celebration of the milestones up to [km] was shown.
Future<Wardrobe> markEnsembleSeen(AppController controller, num km) async =>
    Wardrobe.fromJson(
      await controller.remote(
        '/games/runner/ensemble/seen',
        method: 'PUT',
        body: {'km': km, ..._wardrobeFlags(controller)},
      ),
    );

/// The celebration of the unique figures [itemIds] was shown.
Future<Wardrobe> markUniqueSeen(
  AppController controller,
  List<String> itemIds,
) async => Wardrobe.fromJson(
  await controller.remote(
    '/games/runner/unique/seen',
    method: 'PUT',
    body: {'itemIds': itemIds, ..._wardrobeFlags(controller)},
  ),
);
