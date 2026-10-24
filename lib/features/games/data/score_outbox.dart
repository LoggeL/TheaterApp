import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/app_controller.dart';
import '../../../data/api_client.dart';
import '../domain/stage_runner.dart';
import 'leaderboard_api.dart';

/// The result of a finished run, fixed when the curtain falls: it keeps the
/// run's own server round, so a quick "Nochmal" can neither swap the round
/// nor the numbers for those of the next run.
class RunScore {
  RunScore({
    required this.round,
    required this.score,
    required this.meters,
    this.hitBy,
    this.missionStats,
  });

  /// The round the server started for this run; null when it did not start.
  final Future<String?> round;
  final int score, meters;
  final ObstacleKind? hitBy;
  final Map<String, Object>? missionStats;
}

/// Sends the results of runs, also while the next run is already playing,
/// and keeps those that failed for want of a connection to send them again
/// later (in this app session). The server takes a repeated result once
/// (see server/src/runner-rounds.mjs), so a resend never counts twice.
class RunnerScoreOutbox {
  RunnerScoreOutbox(this.controller);
  final AppController controller;

  /// At most this many results wait; the oldest goes first. As many as
  /// the server keeps runs open (`runnerRounds.open`), so no run is lost
  /// here that the server would still count.
  static const limit = 20;

  final _waiting = <_Waiting>[];
  Future<void>? _retrying;

  /// How many results wait for a resend.
  int get waiting => _waiting.length;

  /// Whether [run] waits for a resend.
  bool waits(RunScore run) => _waiting.any((w) => identical(w.run, run));

  /// Sends [run]; a failure for want of a connection keeps it for [retry].
  /// Returns null when the server did not start the run.
  Future<RoundResult?> send(RunScore run) async {
    final roundId = await run.round;
    if (roundId == null || roundId.isEmpty) return null;
    final entry = _Waiting(roundId, run);
    try {
      final result = await _submit(entry);
      unawaited(retry());
      return result;
    } catch (e) {
      if (_retryable(e)) _keep(entry);
      rethrow;
    }
  }

  /// Sends the waiting results again, one after the other; stops at the
  /// first one that still finds no connection.
  Future<void> retry() => _retrying ??= _retryAll().whenComplete(
    () => _retrying = null,
  );

  Future<void> _retryAll() async {
    while (_waiting.isNotEmpty) {
      final entry = _waiting.first;
      try {
        await _submit(entry);
      } catch (e) {
        if (_retryable(e)) return;
        if (kDebugMode) debugPrint('Bühnenlauf: Ergebnis verworfen: $e');
      }
      _waiting.remove(entry);
    }
  }

  void _keep(_Waiting entry) {
    if (_waiting.any((w) => w.roundId == entry.roundId)) return;
    _waiting.add(entry);
    if (_waiting.length > limit) _waiting.removeAt(0);
  }

  Future<RoundResult> _submit(_Waiting entry) => submitRound(
    controller,
    roundId: entry.roundId,
    score: entry.run.score,
    meters: entry.run.meters,
    hitBy: entry.run.hitBy,
    missionStats: entry.run.missionStats,
  );

  /// Errors without an answer, timeouts and server faults may pass; a
  /// rejected result (unknown, expired, implausible) stays rejected.
  static bool _retryable(Object e) => e is! ApiException || e.retryable;
}

class _Waiting {
  _Waiting(this.roundId, this.run);
  final String roundId;
  final RunScore run;
}

final _outboxes = Expando<RunnerScoreOutbox>();

/// The outbox of [controller]; it outlives the game screen.
RunnerScoreOutbox runnerScoreOutbox(AppController controller) =>
    _outboxes[controller] ??= RunnerScoreOutbox(controller);
