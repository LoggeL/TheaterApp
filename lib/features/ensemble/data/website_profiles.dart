import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../domain/website_profile.dart';

/// Loads the imported website profiles once per session and keeps them for
/// a few minutes; screens share the same request. Demo sessions and older
/// servers have none.
class WebsiteProfiles {
  WebsiteProfiles._();

  static const feature = 'ensembleProfiles';
  static const _maxAge = Duration(minutes: 10);
  static final _cache = Expando<_Entry>('websiteProfiles');

  static bool available(AppController controller) =>
      !controller.isDemo &&
      controller.hasAccess &&
      controller.supports(feature);

  /// The last loaded profiles of this session, if any.
  static List<WebsiteProfile>? peek(AppController controller) {
    final entry = _cache[controller];
    return entry?.epoch == controller.sessionEpoch ? entry!.value : null;
  }

  static Future<List<WebsiteProfile>> load(
    AppController controller, {
    bool refresh = false,
  }) {
    if (!available(controller)) return Future.value(const []);
    final entry = _cache[controller];
    if (!refresh &&
        entry != null &&
        entry.epoch == controller.sessionEpoch &&
        DateTime.now().difference(entry.loadedAt) < _maxAge) {
      return entry.task;
    }
    final epoch = controller.sessionEpoch;
    late final _Entry next;
    final task = controller
        .remote('/ensemble/website-profiles')
        .then((json) => parse(json))
        .then((profiles) {
          next.value = profiles;
          return profiles;
        });
    next = _Entry(epoch, DateTime.now(), task, entry?.value);
    _cache[controller] = next;
    // A failed request is tried again next time.
    task.catchError((Object _) {
      if (identical(_cache[controller], next)) _cache[controller] = null;
      return const <WebsiteProfile>[];
    });
    return task;
  }

  /// Replaces the cache with a fresh server answer, e.g. after linking.
  static List<WebsiteProfile> store(AppController controller, JsonMap json) {
    final profiles = parse(json);
    _cache[controller] = _Entry(
      controller.sessionEpoch,
      DateTime.now(),
      Future.value(profiles),
      profiles,
    );
    return profiles;
  }

  static List<WebsiteProfile> parse(JsonMap json) => jsonList(
    json['profiles'],
  ).map((e) => WebsiteProfile.fromJson(jsonMap(e))).toList();
}

class _Entry {
  _Entry(this.epoch, this.loadedAt, this.task, this.value);
  final int epoch;
  final DateTime loadedAt;
  final Future<List<WebsiteProfile>> task;
  List<WebsiteProfile>? value;
}
