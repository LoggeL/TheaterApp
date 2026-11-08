import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart' show ApiException;
import '../domain/runner_ghost.dart';
import 'leaderboard_api.dart';

/// The Wochenprobe (`runnerWeekly`): one course for everyone per Berlin
/// calendar week, three ranked attempts each and as much training as
/// anyone likes on it, its own ranking with the runs as ghosts, and a little
/// Gage for the places once the week is over. Its runs count for the
/// crates, missions and Gage like any other, but not for the other lists.
bool weeklyAvailable(AppController controller) =>
    leaderboardAvailable(controller) && controller.supports('runnerWeekly');

/// One place in the week's ranking: the best ranked run of a member.
class WeeklyEntry {
  const WeeklyEntry({
    required this.rank,
    required this.personId,
    required this.name,
    required this.score,
    this.meters = 0,
    this.at,
    this.me = false,
  });
  final int rank, personId, score, meters;
  final String name;

  /// When the run was made; the earlier one wins a tie.
  final DateTime? at;
  final bool me;

  factory WeeklyEntry.fromJson(JsonMap json) => WeeklyEntry(
    rank: intValue(json['rank']),
    personId: intValue(json['personId']),
    name: textValue(json['name']),
    score: intValue(json['score']),
    meters: intValue(json['meters']),
    at: json['at'] is String ? DateTime.tryParse(json['at'] as String) : null,
    me: json['me'] == true,
  );
}

/// The own place of last week, until its banner was seen.
class WeeklyLastWeek {
  const WeeklyLastWeek({
    required this.week,
    required this.rank,
    required this.score,
    required this.gage,
  });
  final String week;
  final int rank, score, gage;

  factory WeeklyLastWeek.fromJson(JsonMap json) => WeeklyLastWeek(
    week: textValue(json['week']),
    rank: intValue(json['rank']),
    score: intValue(json['score']),
    gage: intValue(json['gage']),
  );
}

/// The best ranked run so far.
class WeeklyBest {
  const WeeklyBest({required this.score, this.meters = 0});
  final int score, meters;

  /// From `{score, meters}` or a bare score.
  static WeeklyBest? of(Object? json) => switch (json) {
    num score => WeeklyBest(score: score.toInt()),
    Map() => WeeklyBest(
      score: intValue(json['score']),
      meters: intValue(json['meters']),
    ),
    _ => null,
  };
}

/// This week's course and standing (`GET /games/runner/weekly`).
class WeeklyChallenge {
  const WeeklyChallenge({
    required this.week,
    required this.seed,
    required this.startsAt,
    required this.endsAt,
    this.used = 0,
    this.max = 3,
    this.best,
    this.leaderboard = const [],
    this.ghosts = const [],
    this.lastWeek,
    this.cached = false,
  });

  /// The ISO week, e.g. `2026-W46`.
  final String week;

  /// The course's seed, a uint32.
  final int seed;

  /// Monday 00:00 and the next Monday 00:00 in Berlin.
  final DateTime startsAt, endsAt;

  /// Ranked attempts started and allowed this week.
  final int used, max;
  final WeeklyBest? best;
  final List<WeeklyEntry> leaderboard;
  final List<RunnerGhost> ghosts;
  final WeeklyLastWeek? lastWeek;

  /// Only the course, kept on this device from an earlier visit: enough
  /// for training without a connection, nothing else.
  final bool cached;

  int get left => (max - used).clamp(0, max);
  bool currentAt(DateTime now) => now.isBefore(endsAt);
  WeeklyEntry? get own => leaderboard.where((e) => e.me).firstOrNull;

  factory WeeklyChallenge.fromJson(JsonMap json, {int? me}) {
    final attempts = json['attempts'] is Map
        ? jsonMap(json['attempts'])
        : const <String, Object?>{};
    final max = attempts['max'] is num ? intValue(attempts['max']) : 3;
    return WeeklyChallenge(
      week: textValue(json['week']),
      seed: intValue(json['seed']),
      startsAt: _time(json['startsAt']),
      endsAt: _time(json['endsAt']),
      used: intValue(attempts['used']),
      max: max,
      best: WeeklyBest.of(json['best']),
      leaderboard: [
        for (final e in jsonList(json['leaderboard']))
          if (e is Map) WeeklyEntry.fromJson(jsonMap(e)),
      ],
      ghosts: [
        for (final g in jsonList(json['ghosts']))
          if (g is Map) ?RunnerGhost.fromJson(jsonMap(g), me: me),
      ],
      lastWeek: json['lastWeek'] is Map
          ? WeeklyLastWeek.fromJson(jsonMap(json['lastWeek']))
          : null,
    );
  }

  /// The week once its [lastWeek] banner was shown: the server leaves it
  /// out from then on, and so does the menu.
  WeeklyChallenge withoutLastWeek() => lastWeek == null
      ? this
      : WeeklyChallenge(
          week: week,
          seed: seed,
          startsAt: startsAt,
          endsAt: endsAt,
          used: used,
          max: max,
          best: best,
          leaderboard: leaderboard,
          ghosts: ghosts,
          cached: cached,
        );

  /// What is kept for training offline.
  JsonMap toCache() => {
    'week': week,
    'seed': seed,
    'startsAt': startsAt.toUtc().toIso8601String(),
    'endsAt': endsAt.toUtc().toIso8601String(),
  };

  factory WeeklyChallenge.fromCache(JsonMap json) => WeeklyChallenge(
    week: textValue(json['week']),
    seed: intValue(json['seed']),
    startsAt: _time(json['startsAt']),
    endsAt: _time(json['endsAt']),
    cached: true,
  );

  static DateTime _time(Object? value) =>
      (value is String ? DateTime.tryParse(value) : null) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

Future<WeeklyChallenge> loadWeekly(AppController controller) async =>
    WeeklyChallenge.fromJson(
      await controller.remote('/games/runner/weekly'),
      me: controller.user?.personId,
    );

/// Marks last week's banner as seen; it shows once.
Future<void> markWeeklySeen(AppController controller, String week) => controller
    .remote('/games/runner/weekly/seen', method: 'PUT', body: {'week': week});

/// A weekly run started on the server.
class WeeklyStart {
  const WeeklyStart({
    required this.roundId,
    required this.week,
    required this.ranked,
    this.seed,
    this.attempt = 0,
  });
  final String roundId, week;

  /// The course as the server started it; the week's when it says none.
  final int? seed;
  final bool ranked;

  /// Which of the week's ranked attempts this is (1–3); 0 for training.
  final int attempt;
}

/// Why a ranked run cannot start.
enum WeeklyRefusal {
  /// All of this week's attempts are used (`attempts_used`).
  attemptsUsed,

  /// The week has ended meanwhile (`week_over`).
  weekOver,
}

WeeklyRefusal? weeklyRefusal(Object error) => switch (error) {
  ApiException(statusCode: 409, code: 'attempts_used') =>
    WeeklyRefusal.attemptsUsed,
  ApiException(statusCode: 409, code: 'week_over') => WeeklyRefusal.weekOver,
  _ => null,
};

/// Starts a run of [week]'s course. A ranked one counts as an attempt from
/// here on, however it ends.
Future<WeeklyStart> startWeeklyRound(
  AppController controller, {
  required String week,
  required bool ranked,
}) async {
  final data = await controller.remote(
    '/games/runner/rounds',
    method: 'POST',
    body: {
      'weekly': {'week': week, 'ranked': ranked},
    },
  );
  final weekly = data['weekly'] is Map
      ? jsonMap(data['weekly'])
      : const <String, Object?>{};
  return WeeklyStart(
    roundId: textValue(data['roundId']),
    week: weekly['week'] is String ? weekly['week'] as String : week,
    seed: weekly['seed'] is num ? intValue(weekly['seed']) : null,
    ranked: weekly['ranked'] is bool ? weekly['ranked'] as bool : ranked,
    attempt: intValue(weekly['attempt']),
  );
}

/// What a weekly run changed (`weekly` with its score).
class WeeklyRunResult {
  const WeeklyRunResult({
    this.improved = false,
    this.best,
    this.rank,
    this.used,
    this.max,
  });
  final bool improved;
  final WeeklyBest? best;
  final int? rank, used, max;

  factory WeeklyRunResult.fromJson(JsonMap json) {
    final attempts = json['attempts'];
    return WeeklyRunResult(
      improved: json['improved'] == true,
      best: WeeklyBest.of(json['best']),
      rank: json['rank'] is num ? intValue(json['rank']) : null,
      used: switch (attempts) {
        num n => n.toInt(),
        Map() when attempts['used'] is num => intValue(attempts['used']),
        _ => null,
      },
      max: attempts is Map && attempts['max'] is num
          ? intValue(attempts['max'])
          : null,
    );
  }
}

/// The course of the current week kept on this device, so training runs
/// without a connection. Only a convenience: without storage there is none.
class WeeklyCourseCache {
  WeeklyCourseCache({Future<SharedPreferences> Function()? loadPreferences})
    : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'stageRunner.weeklyCourse';
  final Future<SharedPreferences> Function() _loadPreferences;

  Future<WeeklyChallenge?> read() async {
    try {
      final raw = (await _loadPreferences()).getString(key);
      if (raw == null) return null;
      return WeeklyChallenge.fromCache(jsonMap(jsonDecode(raw)));
    } catch (_) {
      return null;
    }
  }

  Future<void> write(WeeklyChallenge week) async {
    try {
      await (await _loadPreferences()).setString(
        key,
        jsonEncode(week.toCache()),
      );
    } catch (_) {
      // Training offline is a convenience.
    }
  }
}
