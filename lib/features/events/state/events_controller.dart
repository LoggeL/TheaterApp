part of '../../../core/app_controller.dart';

/// Event responses and the script link of a rehearsal.
extension EventsController on AppController {
  bool canRespondTo(TheaterEvent event) => event.acceptsResponsesAt(_clock());
  bool canDecline(TheaterEvent event) => event.acceptsDeclineAt(_clock());

  Future<ActionOutcome> respond(
    String eventId,
    String status, {
    String reason = '',
    DateTime? expectedArrivalAt,
  }) async => (await respondWithResult(
    eventId,
    status,
    reason: reason,
    expectedArrivalAt: expectedArrivalAt,
  )).outcome;

  /// Like [respond], with the server's reply once it confirmed the answer,
  /// e.g. for [eventCrateNotice].
  Future<ActionResult> respondWithResult(
    String eventId,
    String status, {
    String reason = '',
    DateTime? expectedArrivalAt,
  }) async {
    final event = _events.where((e) => e.id == eventId).firstOrNull;
    if (event == null) {
      throw const ApiException(
        'Der Termin ist nicht mehr verfügbar.',
        statusCode: 404,
      );
    }
    if (!canRespondTo(event)) {
      throw const ApiException(
        'Die Rückmeldefrist ist abgelaufen.',
        statusCode: 409,
      );
    }
    if (!const {'open', 'yes', 'late', 'no'}.contains(status)) {
      throw const ApiException('Ungültige Rückmeldung.', statusCode: 400);
    }
    if (const {'open', 'no'}.contains(status) && !canDecline(event)) {
      throw const ApiException(
        'Ab einer Stunde vor Beginn ist keine Absage mehr möglich.',
        statusCode: 409,
      );
    }
    if (reason.trim().length > 500) {
      throw const ApiException(
        'Der Absagegrund darf höchstens 500 Zeichen haben.',
        statusCode: 400,
      );
    }
    if (status == 'late' &&
        expectedArrivalAt != null &&
        (event.startsAt == null ||
            event.endsAt == null ||
            !expectedArrivalAt.isAfter(event.startsAt!) ||
            !expectedArrivalAt.isBefore(event.endsAt!))) {
      throw const ApiException(
        'Die Ankunft muss zwischen Beginn und Ende der Probe liegen.',
        statusCode: 400,
      );
    }
    return performActionWithResult({
      'action': 'attendance',
      'eventId': eventId,
      'status': status,
      'reason': status == 'no' ? reason.trim() : '',
      'expectedArrivalAt': status == 'late'
          ? expectedArrivalAt?.toUtc().toIso8601String()
          : null,
    });
  }

  /// The thanks for a commitment that can bring a Termin-Kiste
  /// (`runnerEventCrates`): it comes once the attendance is confirmed after
  /// the event. Null otherwise, and for people who do not know the stage
  /// runner: it is a hidden game, the hint would puzzle the others (their
  /// crate comes all the same).
  String? eventCrateNotice(ActionResult result) {
    final crate = result.data?['eventCrate'];
    if (!supports('runnerEventCrates') ||
        crate is! Map ||
        crate['pending'] != true ||
        crate['player'] != true) {
      return null;
    }
    return eventCrateThanks;
  }

  static const eventCrateThanks =
      'Danke für deine Zusage! Nach dem Termin wartet eine Termin-Kiste auf dich.';

  Future<String> respondFromNotification(
    String eventId,
    String status,
    String recipientUid,
  ) async {
    final generation = _generation;
    void checkAccount() {
      if (!_current(generation) ||
          !hasAccess ||
          _isDemo ||
          _user?.id != recipientUid) {
        throw const ApiException(
          'Diese Mitteilung gehört zu einem anderen oder abgemeldeten Konto.',
          statusCode: 403,
        );
      }
    }

    checkAccount();
    if (!const {'yes', 'no'}.contains(status)) {
      throw const ApiException('Ungültige Rückmeldung.', statusCode: 400);
    }
    await refresh();
    checkAccount();
    final event = _events.where((e) => e.id == eventId).firstOrNull;
    if (event?.endsAt?.isBefore(_clock()) == true) {
      throw const ApiException(
        'Der Termin ist bereits vorbei.',
        statusCode: 409,
      );
    }
    final result = await respondWithResult(eventId, status);
    checkAccount();
    if (_outbox.any(
      (a) =>
          !a.failed &&
          a.payload['action'] == 'attendance' &&
          a.payload['eventId'] == eventId,
    )) {
      return 'Rückmeldung vorgemerkt. Sie wird bei Verbindung gesendet.';
    }
    return eventCrateNotice(result) ??
        (status == 'yes' ? 'Zusage gespeichert.' : 'Absage gespeichert.');
  }

  Future<void> linkEventScript(
    String eventId,
    String? productionId,
    List<String> sceneIds, {
    int? expectedVersion,
  }) async {
    if (_user?.canManageEvents != true) {
      throw const ApiException(
        'Für die Zuordnung ist das Recht „Termine verwalten“ nötig.',
        statusCode: 403,
      );
    }
    final event = _events.where((e) => e.id == eventId).firstOrNull;
    if (event == null) {
      throw const ApiException(
        'Der Termin ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    if (productionId != null &&
        !_productions.any((p) => p.id == productionId)) {
      throw const ApiException(
        'Die Produktion ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    await performAction({
      'action': 'event.script',
      'eventId': eventId,
      'version': expectedVersion ?? event.version,
      'productionId': productionId,
      'sceneIds': productionId == null ? <String>[] : sceneIds.toSet().toList(),
    });
  }
}
