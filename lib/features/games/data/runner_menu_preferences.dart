import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which ranking the Bühnenlauf menu shows.
enum RunnerBoardView {
  /// The best run of the current month ("Monat", `runnerMonthlyLeaderboard`):
  /// the main view, everybody starts again each month.
  month,

  /// The best points of a run of all time ("Allzeit", the "Bestenliste").
  score,

  /// Who has the most complete collection.
  collection,
}

/// Small choices of the Bühnenlauf menu, remembered on this device like the
/// scenery motion (`RunnerMotionPreferences`): whether the day's finished
/// missions are shown in full, and which ranking is open. Only a
/// convenience: without storage the defaults apply and a failed save is
/// ignored.
class RunnerMenuPreferences extends ChangeNotifier {
  RunnerMenuPreferences({
    @visibleForTesting Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance {
    loaded = _restore();
  }

  static const doneMissionsKey = 'stageRunner.doneMissionsOpen';

  /// The ranking since the Monatsrangliste: `month`, `score` or `collection`.
  static const boardKey = 'stageRunner.rankingView';

  /// The ranking before it (`score` or `collection`). `score` was the
  /// default and the only points list then, so it moves on to the month;
  /// a chosen collection stays.
  static const legacyBoardKey = 'stageRunner.boardView';

  final Future<SharedPreferences> Function() _loadPreferences;
  bool _doneMissionsOpen = false, _disposed = false;
  bool _changedDone = false, _changedBoard = false;
  RunnerBoardView _board = RunnerBoardView.month;

  /// Whether finished missions show as rows (else one short line).
  bool get doneMissionsOpen => _doneMissionsOpen;
  RunnerBoardView get board => _board;

  /// Completes even when storage is unavailable.
  late final Future<void> loaded;

  Future<void> _restore() async {
    try {
      final preferences = await _loadPreferences();
      if (_disposed) return;
      final done = preferences.getBool(doneMissionsKey);
      final board =
          preferences.getString(boardKey) ??
          switch (preferences.getString(legacyBoardKey)) {
            'collection' => RunnerBoardView.collection.name,
            _ => null,
          };
      if (!_changedDone && done != null) _doneMissionsOpen = done;
      if (!_changedBoard) {
        _board =
            RunnerBoardView.values.where((v) => v.name == board).firstOrNull ??
            _board;
      }
      notifyListeners();
    } catch (_) {
      // Storage can be unavailable; the menu keeps its defaults.
    }
  }

  void setDoneMissionsOpen(bool open) {
    if (_disposed || open == _doneMissionsOpen) return;
    _changedDone = true;
    _doneMissionsOpen = open;
    notifyListeners();
    _save((p) => p.setBool(doneMissionsKey, open));
  }

  void setBoard(RunnerBoardView board) {
    if (_disposed || board == _board) return;
    _changedBoard = true;
    _board = board;
    notifyListeners();
    _save((p) => p.setString(boardKey, board.name));
  }

  Future<void> _save(Future<bool> Function(SharedPreferences) write) async {
    try {
      await write(await _loadPreferences());
    } catch (_) {
      // Only a convenience: the choice still holds for now.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
