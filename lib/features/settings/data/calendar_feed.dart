import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';

/// Whether the member can subscribe to their events: the server must offer
/// the feed, and the demo has no server to serve it.
bool calendarFeedAvailable(AppController controller) =>
    !controller.isDemo && controller.supports('calendarFeed');

/// The member's personal calendar subscription (see
/// server/src/calendar-feed.mjs): a secret address of an iCalendar feed with
/// the events they are invited to and have not declined.
class CalendarFeed {
  const CalendarFeed({required this.url, this.createdAt});

  factory CalendarFeed.fromJson(JsonMap json) {
    final url = Uri.tryParse(textValue(json['url']));
    if (url == null ||
        !const ['https', 'http'].contains(url.scheme) ||
        url.host.isEmpty) {
      throw const ApiException(
        'Der Server hat keinen gültigen Kalender-Link geliefert.',
      );
    }
    return CalendarFeed(url: url, createdAt: dateValue(json['createdAt']));
  }

  /// The feed address itself, e.g. for copying.
  final Uri url;
  final DateTime? createdAt;

  /// The same address for calendar apps that subscribe on opening it (Apple
  /// Calendar, Outlook and others).
  Uri get webcal => url.replace(scheme: 'webcal');

  /// Google Calendar's page to add a calendar by its address.
  Uri get google => Uri.https('calendar.google.com', '/calendar/r', {
    'cid': webcal.toString(),
  });
}

/// The member's feed; the server creates it on the first request.
Future<CalendarFeed> loadCalendarFeed(AppController controller) async =>
    CalendarFeed.fromJson(await controller.remote('/calendar-feed'));

/// Replaces the feed address; the previous one stops working at once.
Future<CalendarFeed> resetCalendarFeed(AppController controller) async =>
    CalendarFeed.fromJson(
      await controller.remote('/calendar-feed/reset', method: 'POST'),
    );
