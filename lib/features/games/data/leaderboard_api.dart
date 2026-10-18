import '../../../core/app_controller.dart';
import '../../../core/models.dart';

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

/// The best scores of the ensemble and the member's own placement.
class Leaderboard {
  const Leaderboard({this.top = const [], this.own, this.players = 0});
  final List<LeaderboardEntry> top;

  /// Null while the member has no score above zero.
  final LeaderboardEntry? own;
  final int players;

  factory Leaderboard.fromJson(JsonMap json) => Leaderboard(
    top: [
      for (final e in jsonList(json['top']))
        LeaderboardEntry.fromJson(jsonMap(e)),
    ],
    own: json['own'] == null
        ? null
        : LeaderboardEntry.fromJson(jsonMap(json['own'])),
    players: intValue(json['players']),
  );
}

/// The result of a submitted run.
class RoundResult {
  const RoundResult({required this.improved, required this.leaderboard});
  final bool improved;
  final Leaderboard leaderboard;
}

Future<Leaderboard> loadLeaderboard(AppController controller) async =>
    Leaderboard.fromJson(await controller.remote('/games/runner/leaderboard'));

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
}) async {
  final data = await controller.remote(
    '/games/runner/scores',
    method: 'POST',
    body: {'roundId': roundId, 'score': score},
  );
  return RoundResult(
    improved: data['improved'] == true,
    leaderboard: Leaderboard.fromJson(jsonMap(data['leaderboard'])),
  );
}
