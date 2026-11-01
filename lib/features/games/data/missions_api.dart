import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../domain/stage_runner.dart';
import 'wardrobe_api.dart';

/// The "Tagesmissionen" (`runnerMissions`): three missions a day, measured
/// on the own runs. The server picks them, sets the targets, checks the runs
/// and pays out; the app shows them and tells live when a run makes one.
bool missionsAvailable(AppController controller) =>
    wardrobeAvailable(controller) && controller.supports('runnerMissions');

/// Plurals of the pickups' names, the plain ones and those of the backdrops
/// (`collectibleNames` in the catalog, singular there).
const _plurals = {
  'Rose': 'Rosen',
  'Maske': 'Masken',
  'Stern': 'Sterne',
  'Bonbon': 'Bonbons',
  'Kürbis': 'Kürbisse',
  'Vollmond': 'Vollmonde',
  'Pfennig': 'Pfennige',
  'Siegel': 'Siegel',
  'Krone': 'Kronen',
  'Garnrolle': 'Garnrollen',
  'Lorbeerkranz': 'Lorbeerkränze',
  'Kranz': 'Kränze',
  'Glut': 'Glutstücke',
  'Flämmchen': 'Flämmchen',
  'Datenchip': 'Datenchips',
  'Chip': 'Chips',
  'Würfel': 'Würfel',
  'Feder': 'Federn',
  'Dublone': 'Dublonen',
  'Herz': 'Herzen',
  'Mond': 'Monde',
  'Dolch': 'Dolche',
  'Daumenschraube': 'Daumenschrauben',
  'Falke': 'Falken',
  'Ausgestopfter Falke': 'Ausgestopfte Falken',
};

/// Singular names that change after "Sammle 1" (the accusative); the
/// others stay as they are ("Sammle 1 Dolch").
const _accusatives = {
  'Falke': 'Falken',
  'Ausgestopfter Falke': 'ausgestopften Falken',
};

/// A pickup's [name] as the one to collect: "Sammle 1 ausgestopften Falken".
String collectibleAccusative(String name) =>
    _accusatives[name.trim()] ?? name.trim();

/// The German plural of a pickup's [name]: known words (also as the end of
/// a compound, "Teufelsstern" → "Teufelssterne", and the last of several,
/// "Julias Rose" → "Julias Rosen"), else the usual endings.
String collectiblePlural(String name) {
  final word = name.trim();
  if (_plurals[word] case final plural?) return plural;
  final space = word.lastIndexOf(' ');
  if (space > 0) {
    return '${word.substring(0, space + 1)}${collectiblePlural(word.substring(space + 1))}';
  }
  final lower = word.toLowerCase();
  final keys = _plurals.keys.toList()..sort((a, b) => b.length - a.length);
  for (final key in keys) {
    if (lower.length > key.length && lower.endsWith(key.toLowerCase())) {
      return word.substring(0, word.length - key.length) +
          _plurals[key]!.toLowerCase();
    }
  }
  if (RegExp(r'(chen|lein|el|er|en)$').hasMatch(word)) return word;
  if (word.endsWith('e')) return '${word}n';
  if (word.endsWith('nis')) return '${word}se';
  if (RegExp(r'(ung|heit|keit|schaft|ion)$').hasMatch(word)) return '${word}en';
  if (RegExp(r'([aiouy]|ip|on)$').hasMatch(word)) return '${word}s';
  return '${word}e';
}

final _number = NumberFormat.decimalPattern('de');

/// One mission of the day.
class DailyMission {
  const DailyMission({
    required this.slot,
    required this.type,
    required this.text,
    required this.target,
    this.kind,
    this.min = 0,
    this.progress = 0,
    this.done = false,
    this.reward = 0,
    this.rewardInPoints = false,
    this.unit = '',
    this.perRun = true,
    this.justDone = false,
    this.rerolled = false,
    this.pickup,
    this.obstacle,
  });

  /// [kind] as the game's enums, resolved once (live checks run per frame).
  final PickupKind? pickup;
  final ObstacleKind? obstacle;

  /// `easy`, `medium` or `hard`.
  final String slot;

  /// `distance`, `points`, `collect`, `ground`, `ceiling`, `pass`,
  /// `noPickup`, `dailyDistance`, `debut` or `runs`; unknown ones (from a
  /// newer server) are shown but not checked live.
  final String type;

  /// A pickup or obstacle kind, for `collect`, `pass` and `debut`.
  final String? kind;
  final String text, unit;
  final int target, progress, reward;

  /// Whether [reward] is crate points (`runnerCratePoints`); before, crate
  /// metres.
  final bool rewardInPoints;

  /// The metres each run of a `runs` mission needs.
  final int min;
  final bool done;

  /// Whether one run must make it; else the day adds up.
  final bool perRun;

  /// Completed by the run whose reply this is.
  final bool justDone;
  final bool rerolled;

  String get slotLabel => switch (slot) {
    'easy' => 'Leicht',
    'medium' => 'Mittel',
    _ => 'Schwer',
  };

  /// [text] with the pickups as the worn backdrop calls them ([names]:
  /// `collectibleNames`, e.g. `{rose: Bonbon}`); else the server's text.
  String textFor(Map<String, String> names) {
    final name = names[kind];
    if (type != 'collect' || name == null || name.trim().isEmpty) return text;
    final noun = target == 1
        ? collectibleAccusative(name)
        : collectiblePlural(name);
    return 'Sammle ${_number.format(target)} $noun in einem Lauf';
  }

  /// [unit], themed like [textFor].
  String unitFor(Map<String, String> names) {
    final name = names[kind];
    if (type != 'collect' || name == null || name.trim().isEmpty) return unit;
    return collectiblePlural(name);
  }

  double get fraction =>
      target <= 0 ? 1 : (progress / target).clamp(0, 1).toDouble();

  /// What [game] (a run going on) has of it so far, on top of [progress] for
  /// a day mission; null if the app cannot tell.
  int? live(StageRunner game) => switch (type) {
    'distance' => game.meters,
    'points' || 'debut' => game.score,
    'collect' => switch (pickup) {
      final k? => game.collectedOf(k),
      null => null,
    },
    'ground' => game.groundMeters,
    'ceiling' => game.ceilingMeters,
    'pass' => switch (obstacle) {
      final k? => game.passedOf(k),
      null => null,
    },
    'noPickup' => game.collected == 0 ? game.meters : 0,
    'dailyDistance' => progress + game.meters,
    'runs' => progress + (game.meters >= min ? 1 : 0),
    _ => null,
  };

  /// Whether [game] makes this open mission now.
  bool reachedBy(StageRunner game) {
    if (done) return false;
    final value = live(game);
    return value != null && value >= target;
  }

  factory DailyMission.fromJson(JsonMap json) => DailyMission(
    slot: textValue(json['slot']),
    type: textValue(json['type']),
    kind: json['kind'] is String ? json['kind'] as String : null,
    text: textValue(json['text']),
    unit: textValue(json['unit']),
    target: intValue(json['target']),
    min: intValue(json['min']),
    progress: intValue(json['progress']),
    done: json['done'] == true,
    reward: intValue(json['reward']),
    rewardInPoints: json['rewardUnit'] == 'points',
    perRun: json['scope'] != 'day',
    justDone: json['justDone'] == true,
    rerolled: json['rerolled'] == true,
    pickup: PickupKind.values.where((k) => k.name == json['kind']).firstOrNull,
    obstacle: ObstacleKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull,
  );
}

/// Watches a run for the day's open missions, to tell when one is made;
/// each one once. Cheap enough for every frame: no allocations.
class MissionWatch {
  MissionWatch(DailyMissions? missions)
    : _open = [
        for (final m in missions?.missions ?? const <DailyMission>[])
          if (!m.done) m,
      ] {
    _hit = List.filled(_open.length, false);
  }
  final List<DailyMission> _open;
  late final List<bool> _hit;

  /// A mission [game] has just made, or null.
  DailyMission? check(StageRunner game) {
    for (var i = 0; i < _open.length; i++) {
      if (!_hit[i] && _open[i].reachedBy(game)) {
        _hit[i] = true;
        return _open[i];
      }
    }
    return null;
  }
}

/// The day's three missions.
class DailyMissions {
  const DailyMissions({
    required this.day,
    required this.missions,
    this.rerollAvailable = false,
    this.allDone = false,
    this.crateEarned = false,
    this.shinyChance = 0,
  });
  final String day;
  final List<DailyMission> missions;
  final bool rerollAvailable, allDone;

  /// Whether all three brought today's Missionskiste, and its shine chance.
  final bool crateEarned;
  final double shinyChance;

  /// Missions the run of this reply completed.
  List<DailyMission> get justDone => [
    for (final m in missions)
      if (m.justDone) m,
  ];

  /// The run of this reply completed the last one.
  bool get justCompletedAll => allDone && justDone.isNotEmpty;

  factory DailyMissions.fromJson(JsonMap json) {
    final crate = jsonMap(json['crate']);
    return DailyMissions(
      day: textValue(json['day']),
      missions: [
        for (final m in jsonList(json['missions']))
          DailyMission.fromJson(jsonMap(m)),
      ],
      rerollAvailable: json['rerollAvailable'] == true,
      allDone: json['allDone'] == true,
      crateEarned: crate['earned'] == true,
      shinyChance: crate['shinyChance'] is num
          ? (crate['shinyChance'] as num).toDouble()
          : 0,
    );
  }
}

Future<DailyMissions> loadMissions(AppController controller) async =>
    DailyMissions.fromJson(await controller.remote('/games/runner/missions'));

/// Rerolls the mission of [slot]; once a day.
Future<DailyMissions> rerollMission(
  AppController controller,
  String slot, {
  String? key,
}) async => DailyMissions.fromJson(
  await controller.remote(
    '/games/runner/missions/reroll',
    method: 'POST',
    body: {'slot': slot},
    idempotencyKey: key ?? crateKey(),
  ),
);
