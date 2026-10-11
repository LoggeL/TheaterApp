import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// What the server knows about the responses to one event beyond the
/// snapshot: decline reasons, reported absences and, on servers with
/// `eventDetailsV2`, who is invited and who still has to answer.
class EventDetails {
  const EventDetails({
    this.reasons = const {},
    this.absentIds = const {},
    this.invitedIds,
    this.openIds,
    this.lastRemindedAt,
    this.remindCount = 0,
  });

  /// Decline reason per person id; only non-empty reasons are kept.
  final Map<int, String> reasons;

  /// People whose reported absence covers the event day.
  final Set<int> absentIds;

  /// Active invitees and those of them without an answer; null from older
  /// servers, where the audience is computed on the device.
  final List<int>? invitedIds, openIds;
  final DateTime? lastRemindedAt;
  final int remindCount;

  factory EventDetails.fromJson(JsonMap json) {
    final responses = jsonList(json['responses']).map(jsonMap);
    List<int>? ids(Object? value) =>
        value is List ? value.map(intValue).toList() : null;
    final invited = ids(json['invitedIds']);
    return EventDetails(
      reasons: {
        for (final r in responses)
          if (r['status'] == 'no' && textValue(r['reason']).trim().isNotEmpty)
            intValue(r['personId'], -1): textValue(r['reason']).trim(),
      },
      // Older servers send the absences covering the day, of everyone.
      absentIds:
          ids(json['absentIds'])?.toSet() ??
          {
            for (final a in jsonList(json['absences']).map(jsonMap))
              if (invited == null || invited.contains(intValue(a['personId'])))
                intValue(a['personId'], -1),
          },
      invitedIds: invited,
      openIds: ids(json['openIds']),
      lastRemindedAt: dateValue(json['lastRemindedAt'])?.toLocal(),
      remindCount: intValue(json['remindCount']),
    );
  }
}

/// Loads [EventDetails] for admins (`GET /admin/events/<id>`).
class EventDetailsApi {
  const EventDetailsApi(this.controller);
  final AppController controller;

  /// Throws in the demo, offline and for older or failing servers; callers
  /// then keep showing what the snapshot knows.
  Future<EventDetails> load(String eventId) async => EventDetails.fromJson(
    await controller.remote('/admin/events/${Uri.encodeComponent(eventId)}'),
  );
}
