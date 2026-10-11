import '../json.dart';

/// What happened to a change right after it was handed to the controller:
/// confirmed by the server ([synced]) or kept in the outbox ([queued]).
enum ActionOutcome { synced, queued }

/// The [outcome] of a change together with the server's reply. [data] is
/// only set once the server confirmed it; it stays null while the change is
/// queued, in the demo and for replies the controller no longer holds.
class ActionResult {
  const ActionResult(this.outcome, [this.data]);
  final ActionOutcome outcome;
  final JsonMap? data;
}

/// Error codes after which sending the same change again cannot succeed.
const hopelessErrorCodes = {
  'closed',
  'full',
  'not_found',
  'nothing_open',
  'version_conflict',
  'forbidden',
  'access',
};

class PendingAction {
  const PendingAction({
    required this.id,
    required this.payload,
    required this.createdAt,
    this.status = 'pending',
    this.lastError,
    this.lastStatus,
    this.lastErrorCode,
  });
  final String id, status;
  final JsonMap payload;
  final DateTime createdAt;
  final String? lastError;

  /// The HTTP status and the server's error code of the last rejection;
  /// both are missing for entries stored by older app versions.
  final int? lastStatus;
  final String? lastErrorCode;
  bool get failed => status == 'failed';

  /// Whether sending this rejected change again could still succeed.
  bool get retryable =>
      lastErrorCode == null || !hopelessErrorCodes.contains(lastErrorCode);
  String get label => switch (payload['action']) {
    'attendance' => 'Terminrückmeldung',
    'poll.vote' => 'Abstimmung',
    'absence.create' => 'Abwesenheit',
    'absence.delete' => 'Abwesenheit entfernen',
    'settings.reminders' => 'Erinnerungseinstellungen',
    'checkin.save' => 'Anwesenheits-Check-in',
    'event.script' => 'Drehbuchzuordnung',
    _ => 'Änderung',
  };
  PendingAction withStatus(
    String next, [
    String? error,
    int? errorStatus,
    String? errorCode,
  ]) => PendingAction(
    id: id,
    payload: payload,
    createdAt: createdAt,
    status: next,
    lastError: error,
    lastStatus: errorStatus,
    lastErrorCode: errorCode,
  );
  factory PendingAction.fromJson(JsonMap json) => PendingAction(
    id: textValue(json['id']),
    payload: jsonMap(json['payload']),
    createdAt: DateTime.parse(textValue(json['createdAt'])),
    status: textValue(json['status'], 'pending'),
    lastError: json['lastError'] as String?,
    lastStatus: json['lastStatus'] is num
        ? (json['lastStatus'] as num).toInt()
        : null,
    lastErrorCode: json['lastErrorCode'] is String
        ? json['lastErrorCode'] as String
        : null,
  );
  JsonMap toJson() => {
    'id': id,
    'payload': payload,
    'createdAt': createdAt.toIso8601String(),
    'status': status,
    'lastError': lastError,
    if (lastStatus != null) 'lastStatus': lastStatus,
    if (lastErrorCode != null) 'lastErrorCode': lastErrorCode,
  };
}
