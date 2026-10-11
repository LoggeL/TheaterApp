import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// The shared live focus of one production: following the director or
/// directing yourself.
///
/// Polling and publishing run independently. A cue tapped while a request
/// is in flight is never dropped: the latest one waits and is sent right
/// after the current publish. Poll answers older than the last published
/// focus are ignored, so a slow poll cannot move the focus back.
class LiveFocusController extends ChangeNotifier {
  LiveFocusController({
    required this.controller,
    required this.productionId,
    required this.revision,
    this.onFollow,
    this.onPublishFailed,
    this.pollInterval = const Duration(seconds: 3),
  });
  final AppController controller;
  final String productionId;

  /// The revision of the script on this device, null while none is loaded.
  final String? Function() revision;

  /// Called when the followed focus moved; a null cue means it was cleared.
  final Future<void> Function(String? cueId)? onFollow;

  /// Called with a readable message when a tapped cue could not be shared.
  final void Function(String message)? onPublishFailed;
  final Duration pollInterval;

  FocusState? _focus;
  String? _error;
  bool _following = false, _directing = false, _foreground = true;
  bool _polling = false, _publishing = false, _disposed = false;
  String? _queuedCueId;
  int _lastSequence = -1;
  Timer? _timer;

  FocusState? get focus => _focus;
  String? get error => _error;
  bool get following => _following;
  bool get directing => _directing;
  bool get active => _following || _directing;
  bool get canDirect => _focus?.canDirect == true;

  /// The focused cue while following or directing, otherwise null.
  String? get activeCueId => active ? _focus?.cueId : null;

  void setForeground(bool foreground) {
    _foreground = foreground;
    _restartPolling();
  }

  void setFollowing(bool value) {
    _following = value;
    if (value) {
      _directing = false;
      // The next poll counts as a change, so the reader jumps right away.
      _lastSequence = -1;
    }
    _changed();
    _restartPolling();
  }

  void setDirecting(bool value) {
    _directing = value;
    if (value) _following = false;
    _changed();
    _restartPolling();
  }

  /// Ends following and directing on this device.
  void stop() {
    _following = false;
    _directing = false;
    _timer?.cancel();
    _changed();
  }

  void _restartPolling() {
    _timer?.cancel();
    if (!_foreground || !active || _disposed) return;
    refresh();
    _timer = Timer.periodic(pollInterval, (_) => refresh());
  }

  /// Fetches the current focus. Skipped while another poll is running.
  Future<void> refresh() async {
    if (_polling || !_foreground || _disposed) return;
    _polling = true;
    try {
      final result = await controller.getFocus(productionId);
      if (_disposed || !_foreground) return;
      // A publish in flight or queued makes this answer outdated.
      if (_publishing || _queuedCueId != null) return;
      if (result.productionId != productionId ||
          result.sequence < _lastSequence) {
        return;
      }
      final moved = result.sequence > _lastSequence;
      _lastSequence = result.sequence;
      _focus = result;
      if (result.cueId != null && result.revision != revision()) {
        _error =
            'Andere Drehbuchfassung. Bitte aktualisieren, um dem Fokus zu folgen.';
        _changed();
        return;
      }
      _error = null;
      if (!result.canDirect) _directing = false;
      _changed();
      if (moved && _following) await onFollow?.call(result.cueId);
    } catch (_) {
      if (_disposed) return;
      _error = 'Fokus zurzeit nicht erreichbar. Dein Drehbuch bleibt lesbar.';
      _changed();
    } finally {
      _polling = false;
    }
  }

  /// Shares [cueId] with everyone following. Taps during a running publish
  /// are coalesced: only the latest one is sent afterwards.
  Future<void> publish(String cueId) async {
    _queuedCueId = cueId;
    if (_publishing) return;
    _publishing = true;
    try {
      while (_queuedCueId != null && !_disposed) {
        final next = _queuedCueId!;
        _queuedCueId = null;
        final currentRevision = revision();
        if (currentRevision == null) break;
        try {
          final result = await controller.publishFocus(
            productionId,
            revision: currentRevision,
            cueId: next,
          );
          if (_disposed) return;
          _focus = result;
          _error = null;
          if (result.sequence > _lastSequence) _lastSequence = result.sequence;
          _changed();
        } catch (_) {
          if (_disposed) return;
          _error = 'Der Fokus wurde nicht geteilt. Bitte erneut versuchen.';
          _changed();
          onPublishFailed?.call(_error!);
        }
      }
    } finally {
      _publishing = false;
    }
  }

  /// Removes the shared focus for everyone.
  Future<void> clear() async {
    final result = await controller.clearFocus(productionId);
    if (_disposed) return;
    _focus = result;
    if (result.sequence > _lastSequence) _lastSequence = result.sequence;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
