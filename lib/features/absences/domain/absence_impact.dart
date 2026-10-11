import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// The viewer's events that an absence from [from] to [to] (both whole days)
/// declines on saving, mirroring the offline projection: on one of those
/// days, still open for a decline, not locked, not booked through a slot pool
/// and addressed to the viewer. Events already declined are left out.
List<TheaterEvent> affectedEventsForAbsence(
  AppController controller,
  DateTime from,
  DateTime to,
) {
  final user = controller.user;
  if (user == null) return const [];
  final viewer = TheaterMember(
    id: user.personId ?? -1,
    name: '',
    roleIds: user.roleIds,
  );
  final now = controller.now;
  final first = dateOnly(from), last = dateOnly(to);
  return [
    for (final event in controller.events)
      if (event.startsAt != null &&
          event.endsAt != null &&
          !event.endsAt!.isBefore(now) &&
          event.acceptsDeclineAt(now) &&
          event.response != 'no' &&
          dateOnly(event.startsAt!).compareTo(first) >= 0 &&
          dateOnly(event.startsAt!).compareTo(last) <= 0 &&
          viewer.inAudience(
            event.roleIds,
            event.personIds,
            controller.ensemblesOf(event.productionIds),
          ))
        event,
  ]..sort((a, b) => a.startsAt!.compareTo(b.startsAt!));
}
