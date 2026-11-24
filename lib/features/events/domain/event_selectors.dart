import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// The events badge only counts open responses for the near future.
const responseBadgeWindow = Duration(days: 14);

int unansweredSoon(AppController controller, DateTime now) => controller.events
    .where(
      (event) =>
          event.needsResponse &&
          (event.startsAt == null ||
              ((event.endsAt ?? event.startsAt!).isAfter(now) &&
                  event.startsAt!.isBefore(now.add(responseBadgeWindow)))),
    )
    .length;

/// Events that have not ended yet, sorted by start; undated events last.
/// [AppController.events] is already maintained in start-time order.
List<TheaterEvent> upcomingEvents(AppController controller, DateTime now) => [
  for (final e in controller.events)
    if (e.startsAt == null || (e.endsAt ?? e.startsAt!).isAfter(now)) e,
];

/// The first of the [upcomingEvents], if any.
TheaterEvent? nextEvent(AppController controller, DateTime now) {
  for (final e in controller.events) {
    if (e.startsAt == null || (e.endsAt ?? e.startsAt!).isAfter(now)) return e;
  }
  return null;
}
