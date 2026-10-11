part of '../../../core/app_controller.dart';

/// Reporting and removing absences.
extension AbsencesController on AppController {
  /// Reports an absence. Resolves to [ActionOutcome.queued] while it waits
  /// for a connection, and to null when the server rejected it: that entry
  /// then stays in the outbox as failed, for review, instead of throwing.
  Future<ActionOutcome?> addAbsence(
    DateTime from,
    DateTime to,
    String reason,
  ) async {
    if (dateOnly(to).compareTo(dateOnly(from)) < 0) {
      throw const ApiException(
        'Das Enddatum liegt vor dem Startdatum.',
        statusCode: 400,
      );
    }
    if (reason.trim().length > 500) {
      throw const ApiException(
        'Der Grund darf höchstens 500 Zeichen haben.',
        statusCode: 400,
      );
    }
    final previous = _outbox.map((a) => a.id).toSet();
    await _enqueue({
      'action': 'absence.create',
      'from': dateOnly(from),
      'to': dateOnly(to),
      'reason': reason.trim(),
    });
    final added = _outbox.where((a) => !previous.contains(a.id));
    if (added.any((a) => a.failed)) return null;
    return _outcomeSince(previous);
  }

  Future<void> deleteAbsence(String id) async {
    final generation = _generation;
    if (id.startsWith('local:')) {
      final pendingId = id.substring(6);
      // A request may already be in flight; wait until its outcome is known.
      if (_drainTask != null) await _drainTask;
      if (!_current(generation)) return;
      final pending = _outbox.where((e) => e.id == pendingId).firstOrNull;
      if (pending != null) {
        _outbox.removeWhere((e) => e.id == pendingId);
        _rebuild();
        await _persistCore(generation);
        _notify();
        return;
      }
      throw const ApiException(
        'Die Abwesenheit wurde bereits synchronisiert. Bitte aktualisieren und erneut auswählen.',
        statusCode: 409,
      );
    }
    await _enqueue({'action': 'absence.delete', 'id': id});
  }
}
