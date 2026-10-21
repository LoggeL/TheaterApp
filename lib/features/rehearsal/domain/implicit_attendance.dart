import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// People who attend [event] implicitly ("Alle gelten als zugesagt"), as the
/// server reported them in the snapshot; empty for other events.
Set<int> implicitAttendees(AppController controller, TheaterEvent event) =>
    event.autoAccept
    ? jsonList(
        controller.implicitAttendanceByEvent[event.id],
      ).map((id) => intValue(id, -1)).toSet()
    : const {};

/// The responses to [event] as planning sees them: real answers stay, the
/// implicit attendees of an auto-accepted event count as 'yes' and the other
/// invitees without an answer as 'no' (an absence covers the day there).
/// Keys are person ids as strings, like `memberAttendanceByEvent`.
Map<String, String> effectiveResponses(
  TheaterEvent event,
  JsonMap responses,
  Iterable<int> invitedIds,
  Set<int> implicitIds,
) {
  final result = {
    for (final entry in responses.entries)
      entry.key: textValue(entry.value, 'open'),
  };
  if (!event.autoAccept) return result;
  for (final id in invitedIds) {
    if (const {'yes', 'late', 'no'}.contains(result['$id'])) continue;
    result['$id'] = implicitIds.contains(id) ? 'yes' : 'no';
  }
  return result;
}

/// [effectiveResponses] for [event] from the snapshot, with the active
/// invitees computed on the device.
Map<String, String> plannedResponses(
  AppController controller,
  TheaterEvent event,
) => effectiveResponses(
  event,
  jsonMap(controller.memberAttendanceByEvent[event.id]),
  controller.members
      .where(
        (m) =>
            m.active &&
            m.inAudience(
              event.roleIds,
              event.personIds,
              controller.ensemblesOf(event.productionIds),
            ),
      )
      .map((m) => m.id),
  implicitAttendees(controller, event),
);
