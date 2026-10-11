part of '../../../core/app_controller.dart';

/// Reporting and removing absences.
extension AbsencesController on AppController {
  /// Reports an absence. Throws when the server rejected it (the entry then
  /// stays in the outbox as failed, for review). Once confirmed by a server
  /// with `absenceOutcome`, the result's data lists `declinedEventIds`.
  Future<ActionResult> addAbsence(
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
    return performActionWithResult({
      'action': 'absence.create',
      'from': dateOnly(from),
      'to': dateOnly(to),
      'reason': reason.trim(),
    });
  }

  /// Removes an absence. With [reopen] a server with `absenceOutcome` also
  /// reopens the events it declined automatically; the result's data then
  /// lists `reopenedEventIds`. Older servers ignore the wish.
  Future<ActionResult> deleteAbsence(String id, {bool reopen = false}) async {
    final generation = _generation;
    if (id.startsWith('local:')) {
      final pendingId = id.substring(6);
      // A request may already be in flight; wait until its outcome is known.
      if (_drainTask != null) await _drainTask;
      if (!_current(generation)) {
        return const ActionResult(ActionOutcome.synced);
      }
      final pending = _outbox.where((e) => e.id == pendingId).firstOrNull;
      if (pending != null) {
        _outbox.removeWhere((e) => e.id == pendingId);
        _rebuild();
        await _persistCore(generation);
        _notify();
        return const ActionResult(ActionOutcome.synced);
      }
      throw const ApiException(
        'Die Abwesenheit wurde bereits synchronisiert. Bitte aktualisieren und erneut auswählen.',
        statusCode: 409,
      );
    }
    return performActionWithResult({
      'action': 'absence.delete',
      'id': id,
      if (reopen && supports('absenceOutcome')) 'reopen': true,
    });
  }
}
