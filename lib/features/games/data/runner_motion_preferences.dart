import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The stage's scenery movement, remembered on this device like sound.
/// System accessibility settings are applied by the screen, not persisted.
class RunnerMotionPreferences extends ChangeNotifier {
  RunnerMotionPreferences({
    @visibleForTesting Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance {
    loaded = _restore();
  }

  static const _key = 'stageRunner.sceneryMotion';

  // A screen may close and reopen before a save finishes. The next screen
  // reads after pending saves, and its writes cannot overtake the old ones.
  // Keep only pending work: a completed Future can retain the async zone
  // of a screen that has already gone away (notably a widget test's zone).
  static Future<void>? _writes;

  final Future<SharedPreferences> Function() _loadPreferences;
  bool _sceneryMotion = true;
  bool _ready = false;
  bool _changed = false;
  bool _disposed = false;

  bool get sceneryMotion => _sceneryMotion;
  bool get ready => _ready;

  /// Completes even when storage is unavailable, using the default then.
  late final Future<void> loaded;

  Future<void> _restore() async {
    try {
      final pending = _writes;
      if (pending != null) await pending;
      final preferences = await _loadPreferences();
      final stored = preferences.getBool(_key);
      if (!_disposed && !_changed && stored != null) {
        _sceneryMotion = stored;
      }
    } catch (_) {
      // Storage can be unavailable; the game still opens with the default.
    } finally {
      _ready = true;
      if (!_disposed) notifyListeners();
    }
  }

  /// Applies immediately. A failed save leaves the in-memory choice intact
  /// and reports the error to the caller so the UI can explain it.
  Future<void> setSceneryMotion(bool enabled) {
    if (_disposed) return Future<void>.value();
    _changed = true;
    if (_sceneryMotion != enabled) {
      _sceneryMotion = enabled;
      notifyListeners();
    }
    Future<void> persist() async {
      final preferences = await _loadPreferences();
      if (!await preferences.setBool(_key, enabled)) {
        throw StateError(
          'Die Bewegungseinstellung konnte nicht gespeichert werden.',
        );
      }
    }

    final pending = _writes;
    final save = pending == null ? persist() : pending.then((_) => persist());
    // Handle the queue's error even if its caller has already left the
    // screen. The returned save still reports it to callers that await it.
    late final Future<void> queued;
    void clearQueue() {
      if (identical(_writes, queued)) _writes = null;
    }

    queued = save.then<void>(
      (_) => clearQueue(),
      onError: (Object _, StackTrace _) => clearQueue(),
    );
    _writes = queued;
    return save;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
