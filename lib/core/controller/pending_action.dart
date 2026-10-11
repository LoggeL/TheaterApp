import '../json.dart';

/// What happened to a change right after it was handed to the controller:
/// confirmed by the server ([synced]) or kept in the outbox ([queued]).
enum ActionOutcome { synced, queued }

class PendingAction {
  const PendingAction({
    required this.id,
    required this.payload,
    required this.createdAt,
    this.status = 'pending',
    this.lastError,
  });
  final String id, status;
  final JsonMap payload;
  final DateTime createdAt;
  final String? lastError;
  bool get failed => status == 'failed';
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
  PendingAction withStatus(String next, [String? error]) => PendingAction(
    id: id,
    payload: payload,
    createdAt: createdAt,
    status: next,
    lastError: error,
  );
  factory PendingAction.fromJson(JsonMap json) => PendingAction(
    id: textValue(json['id']),
    payload: jsonMap(json['payload']),
    createdAt: DateTime.parse(textValue(json['createdAt'])),
    status: textValue(json['status'], 'pending'),
    lastError: json['lastError'] as String?,
  );
  JsonMap toJson() => {
    'id': id,
    'payload': payload,
    'createdAt': createdAt.toIso8601String(),
    'status': status,
    'lastError': lastError,
  };
}
