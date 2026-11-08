import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/runner_ghost.dart';

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
/// missions are shown in full, which ranking is open, which ghosts runs
/// of the Wochenprobe show ([GhostMode]), and which entries of "Neu im
/// Bühnenlauf" were shown (see `runner_news.dart`). Only a convenience:
/// without storage the defaults apply and a failed save is ignored.
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

  /// The ghosts of the Wochenprobe: `few` or `all` ([GhostMode]). The
  /// switch for training before it (`stageRunner.trainingGhosts`) is not
  /// read: ghosts are never all off now, and "Wenige" is calm enough.
  static const ghostModeKey = 'stageRunner.ghostMode';

  /// The ids of the news entries shown on this device.
  static const newsSeenKey = 'stageRunner.newsSeen';

  final Future<SharedPreferences> Function() _loadPreferences;
  bool _doneMissionsOpen = false, _disposed = false;
  bool _changedDone = false, _changedBoard = false;
  GhostMode _ghostMode = GhostMode.few;
  bool _changedGhosts = false;
  RunnerBoardView _board = RunnerBoardView.month;
  final _newsSeen = <String>{};
  bool _newsKnown = false;

  /// Whether finished missions show as rows (else one short line).
  bool get doneMissionsOpen => _doneMissionsOpen;
  RunnerBoardView get board => _board;

  /// Which ghosts the runs of the Wochenprobe show; [GhostMode.few] unless
  /// chosen otherwise.
  GhostMode get ghostMode => _ghostMode;

  /// The news entries already shown here.
  Set<String> get newsSeen => Set.unmodifiable(_newsSeen);

  /// Whether [newsSeen] is known: storage answered. Without it no news is
  /// offered, so it cannot come again at every start.
  bool get newsKnown => _newsKnown;

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
      final ghosts = preferences.getString(ghostModeKey);
      if (!_changedGhosts) {
        _ghostMode =
            GhostMode.values.where((m) => m.name == ghosts).firstOrNull ??
            _ghostMode;
      }
      _newsSeen.addAll(preferences.getStringList(newsSeenKey) ?? const []);
      _newsKnown = true;
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

  void setGhostMode(GhostMode mode) {
    if (_disposed || mode == _ghostMode) return;
    _changedGhosts = true;
    _ghostMode = mode;
    notifyListeners();
    _save((p) => p.setString(ghostModeKey, mode.name));
  }

  /// Remembers the news entries [ids] as shown, with all seen before.
  void markNewsSeen(Iterable<String> ids) {
    if (_disposed || _newsSeen.containsAll(ids)) return;
    _newsSeen.addAll(ids);
    notifyListeners();
    final all = _newsSeen.toList();
    _save((p) async {
      // Another screen may have marked others meanwhile.
      final stored = p.getStringList(newsSeenKey) ?? const [];
      return p.setStringList(newsSeenKey, {...stored, ...all}.toList());
    });
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
