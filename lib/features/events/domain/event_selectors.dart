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
List<TheaterEvent> upcomingEvents(AppController controller, DateTime now) =>
    controller.events
        .where(
          (e) => e.startsAt == null || (e.endsAt ?? e.startsAt!).isAfter(now),
        )
        .toList()
      ..sort(
        (a, b) => (a.startsAt ?? DateTime(9999)).compareTo(
          b.startsAt ?? DateTime(9999),
        ),
      );

/// The first of the [upcomingEvents], if any.
TheaterEvent? nextEvent(AppController controller, DateTime now) =>
    upcomingEvents(controller, now).firstOrNull;
