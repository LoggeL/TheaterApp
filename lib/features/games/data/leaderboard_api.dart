import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart' show ApiException;
import '../domain/stage_runner.dart';
import 'wardrobe_api.dart';

/// Whether rounds count for the shared leaderboard: the server must offer it,
/// and the demo has no server.
bool leaderboardAvailable(AppController controller) =>
    !controller.isDemo && controller.supports('stageRunner');

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.rank,
    required this.personId,
    required this.name,
    required this.score,
  });
  final int rank, personId, score;
  final String name;

  factory LeaderboardEntry.fromJson(JsonMap json) => LeaderboardEntry(
    rank: intValue(json['rank']),
    personId: intValue(json['personId']),
    name: textValue(json['name']),
    score: intValue(json['score']),
  );
}

/// The best scores of the ensemble and the member's own placement; of all
/// time, or of one calendar month ([month], from `period=month`).
class Leaderboard {
  const Leaderboard({
    this.top = const [],
    this.own,
    this.players = 0,
    this.month,
    this.endsAt,
  });
  final List<LeaderboardEntry> top;

  /// Null while the member has no score above zero.
  final LeaderboardEntry? own;
  final int players;

  /// The month of a month list as `YYYY-MM`; null for the all-time list.
  final String? month;

  /// When the month ends (Berlin midnight on the next first).
  final DateTime? endsAt;

  factory Leaderboard.fromJson(JsonMap json) => Leaderboard(
    top: [
      for (final e in jsonList(json['top']))
        LeaderboardEntry.fromJson(jsonMap(e)),
    ],
    own: json['own'] == null
        ? null
        : LeaderboardEntry.fromJson(jsonMap(json['own'])),
    players: intValue(json['players']),
    month: json['month'] is String ? json['month'] as String : null,
    endsAt: json['endsAt'] is String
        ? DateTime.tryParse(json['endsAt'] as String)
        : null,
  );
}

/// The result of a submitted run.
class RoundResult {
  const RoundResult({
    required this.improved,
    required this.leaderboard,
    this.progress,
  });
  final bool improved;
  final Leaderboard leaderboard;

  /// The metres towards the next costume crate; only from servers with
  /// `runnerUnlocks`.
  final RunnerProgress? progress;
}

Future<Leaderboard> loadLeaderboard(AppController controller) async =>
    Leaderboard.fromJson(await controller.remote('/games/runner/leaderboard'));

/// Whether the app asks for the Monatsrangliste (`runnerMonthlyLeaderboard`):
/// the best run of each member in the current Berlin calendar month.
bool monthlyBoardAvailable(AppController controller) =>
    leaderboardAvailable(controller) &&
    controller.supports('runnerMonthlyLeaderboard');

/// The Monatsrangliste of the current month, or of [month] (`YYYY-MM`).
/// Failures are thrown; the menu then falls back to the all-time list.
Future<Leaderboard> loadMonthlyLeaderboard(
  AppController controller, {
  String? month,
}) async => Leaderboard.fromJson(
  await controller.remote(
    month == null
        ? '/games/runner/leaderboard?period=month'
        : '/games/runner/leaderboard?period=month&month=$month',
  ),
);

/// Whether the app asks for the collection ranking ("wer hat die
/// kompletteste Sammlung", `runnerCollection`): the server must announce it,
/// and it needs the shared list and the wardrobe. Should a server still
/// answer with 404, [loadCollectionBoard] gives null and the menu leaves it
/// out quietly.
bool collectionBoardAvailable(AppController controller) =>
    leaderboardAvailable(controller) &&
    wardrobeAvailable(controller) &&
    controller.supports('runnerCollection');

/// One member in the collection ranking: [owned] of the board's total
/// collectible items, [shiny] of them in their shiny version.
class CollectionEntry {
  const CollectionEntry({
    required this.rank,
    required this.personId,
    required this.name,
    required this.owned,
    this.shiny = 0,
    this.percent = 0,
    this.me = false,
  });
  final int rank, personId, owned, shiny;
  final String name;
  final double percent;

  /// The signed-in member's own row.
  final bool me;

  factory CollectionEntry.fromJson(JsonMap json) => CollectionEntry(
    rank: intValue(json['rank']),
    personId: intValue(json['personId']),
    name: textValue(json['name']),
    owned: intValue(json['owned']),
    shiny: intValue(json['shiny']),
    percent: json['percent'] is num ? (json['percent'] as num).toDouble() : 0,
    me: json['me'] == true,
  );
}

/// "Wer hat die kompletteste Sammlung": everybody's collection, best first.
/// Equal collections share their rank.
class CollectionBoard {
  const CollectionBoard({required this.total, this.entries = const []});

  /// Collectible items in all.
  final int total;
  final List<CollectionEntry> entries;

  /// The own row, if the member is listed.
  CollectionEntry? get own => entries.where((e) => e.me).firstOrNull;

  factory CollectionBoard.fromJson(JsonMap json) {
    final entries = [
      for (final e in jsonList(json['entries']))
        if (e is Map) CollectionEntry.fromJson(jsonMap(e)),
    ];
    // A server that lists only the best may still name the own row apart.
    if (json['own'] is Map && !entries.any((e) => e.me)) {
      final own = CollectionEntry.fromJson(jsonMap(json['own']));
      entries.add(
        CollectionEntry(
          rank: own.rank,
          personId: own.personId,
          name: own.name,
          owned: own.owned,
          shiny: own.shiny,
          percent: own.percent,
          me: true,
        ),
      );
    }
    return CollectionBoard(total: intValue(json['total']), entries: entries);
  }
}

/// The collection ranking; null where the server does not know it yet (404),
/// so the app leaves it out quietly. Other failures are thrown as usual.
Future<CollectionBoard?> loadCollectionBoard(AppController controller) async {
  try {
    return CollectionBoard.fromJson(
      await controller.remote('/games/runner/collection'),
    );
  } on ApiException catch (e) {
    if (e.statusCode == 404) return null;
    rethrow;
  }
}

/// Starts a run on the server; returns its id.
Future<String> startRound(AppController controller) async {
  final data = await controller.remote(
    '/games/runner/rounds',
    method: 'POST',
    body: const {},
  );
  return textValue(data['roundId']);
}

Future<RoundResult> submitRound(
  AppController controller, {
  required String roundId,
  required int score,
  required int meters,
  ObstacleKind? hitBy,
  Map<String, Object>? missionStats,
}) async {
  final data = await controller.remote(
    '/games/runner/scores',
    method: 'POST',
    // Older servers ignore metres and the obstacle.
    body: {
      'roundId': roundId,
      'score': score,
      'meters': meters,
      if (hitBy != null) 'hitBy': hitBy.name,
      // For the Tagesmissionen (`runnerMissions`); older servers ignore it.
      'missionStats': ?missionStats,
    },
  );
  return RoundResult(
    improved: data['improved'] == true,
    leaderboard: Leaderboard.fromJson(jsonMap(data['leaderboard'])),
    progress: data['progress'] is Map
        ? RunnerProgress.fromJson(jsonMap(data['progress']))
        : null,
  );
}
