import 'dart:async';

import '../core/app_controller.dart';

/// Refreshes the session every 45 seconds and when the app resumes, with at
/// most one automatic refresh in flight.
class BackgroundSync {
  BackgroundSync(this.controller, {required this.isStarting});
  final AppController controller;

  /// While the app is still starting, automatic refreshes are skipped.
  final bool Function() isStarting;
  Timer? _syncTimer;
  Future<void>? _automaticRefresh;

  /// (Re)starts the periodic timer.
  void start() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(refresh());
    });
  }

  void stop() => _syncTimer?.cancel();

  Future<void> refresh() async {
    final controller = this.controller;
    if (isStarting() ||
        controller.user == null ||
        controller.isDemo ||
        controller.busy ||
        _automaticRefresh != null) {
      return;
    }
    final task = controller.usesFirebase && !controller.hasAccess
        ? controller.refreshIdentityAccess()
        : controller.refresh();
    _automaticRefresh = task;
    try {
      await task;
    } catch (_) {
      // Retain the current screen when an automatic status check is offline.
      // The next check or the manual refresh can retry it.
    } finally {
      if (identical(_automaticRefresh, task)) _automaticRefresh = null;
    }
  }

  void dispose() => _syncTimer?.cancel();
}
