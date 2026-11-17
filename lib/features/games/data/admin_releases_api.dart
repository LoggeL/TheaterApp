import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import 'admin_skins_api.dart';

/// Whether the admins' Release-Zeitplan of the stage runner is offered:
/// to admins who have the Skin-Viewer, and only when the server announces
/// it (`runnerReleaseSchedule`). The server checks the role again on every
/// request (403 for members).
bool adminReleasesAvailable(AppController controller) =>
    adminSkinsAvailable(controller) &&
    controller.supports('runnerReleaseSchedule');

/// Where a release stands (`status` on the server).
enum AdminReleaseStatus {
  /// Started and complete: the players have it.
  live('Live'),

  /// Not started yet.
  scheduled('Geplant'),

  /// Started, but held back until every picture of its pack is there.
  blocked('Blockiert');

  const AdminReleaseStatus(this.label);
  final String label;

  static AdminReleaseStatus parse(String value) => switch (value) {
    'live' => live,
    'blocked' => blocked,
    _ => scheduled,
  };
}

/// One release of the plan (`GET /admin/runner/releases`): releases.json
/// with the date the admins gave it, if any.
class AdminRelease {
  const AdminRelease({
    required this.id,
    required this.name,
    required this.startsAt,
    required this.plannedStartsAt,
    required this.status,
    this.overridden = false,
    this.itemCount = 0,
    this.ready = true,
    this.missing = 0,
    this.pushState = 'pending',
    this.pushAt,
  });
  final String id, name;
  final DateTime startsAt, plannedStartsAt;
  final AdminReleaseStatus status;

  /// The date differs from releases.json (changed in this screen).
  final bool overridden;
  final int itemCount;

  /// Every picture of its pack is there; [missing] counts those that are not.
  final bool ready;
  final int missing;

  /// The drop push: `sent`, `skipped`, `held`, `silent` or `pending`.
  final String pushState;
  final DateTime? pushAt;

  static AdminRelease? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = jsonMap(value);
    final id = textValue(json['id']);
    final startsAt = DateTime.tryParse(textValue(json['startsAt']));
    if (id.isEmpty || startsAt == null) return null;
    final push = jsonMap(json['push']);
    return AdminRelease(
      id: id,
      name: textValue(json['name'], id),
      startsAt: startsAt.toUtc(),
      plannedStartsAt:
          DateTime.tryParse(textValue(json['plannedStartsAt']))?.toUtc() ??
          startsAt.toUtc(),
      status: AdminReleaseStatus.parse(textValue(json['status'])),
      overridden: json['overridden'] == true,
      itemCount: json['itemCount'] is int ? json['itemCount'] as int : 0,
      ready: json['ready'] != false,
      missing: json['missing'] is int ? json['missing'] as int : 0,
      pushState: textValue(push['state'], 'pending'),
      pushAt: DateTime.tryParse(textValue(push['at']))?.toUtc(),
    );
  }
}

/// The plan, earliest first, and the server's time when it was read.
class AdminReleasePlan {
  const AdminReleasePlan({required this.releases, this.serverTime});
  final List<AdminRelease> releases;
  final DateTime? serverTime;

  factory AdminReleasePlan.fromJson(JsonMap json) {
    final releases = [
      for (final r in jsonList(json['releases'])) ?AdminRelease.fromJson(r),
    ]..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    return AdminReleasePlan(
      releases: releases,
      serverTime: DateTime.tryParse(textValue(json['serverTime']))?.toUtc(),
    );
  }
}

Future<AdminReleasePlan> loadAdminReleases(AppController controller) async =>
    AdminReleasePlan.fromJson(
      await controller.remote('/admin/runner/releases'),
    );

String _two(int n) => n.toString().padLeft(2, '0');

/// Moves release [id] to [day] at [hour]:[minute] on the Berlin wall clock
/// (the server works out the offset), or back to the date of releases.json
/// with [reset]. [confirm] is needed to move a live release into the future
/// (otherwise the server answers 409 `release_live`).
Future<AdminRelease> rescheduleAdminRelease(
  AppController controller,
  String id, {
  DateTime? day,
  int hour = 18,
  int minute = 0,
  bool reset = false,
  bool confirm = false,
}) async {
  final body = <String, Object?>{
    if (reset)
      'startsAt': null
    else ...{
      'date': '${day!.year}-${_two(day.month)}-${_two(day.day)}',
      'time': '${_two(hour)}:${_two(minute)}',
    },
    if (confirm) 'confirm': true,
  };
  final json = await controller.remote(
    '/admin/runner/releases/${Uri.encodeComponent(id)}',
    method: 'PUT',
    body: body,
  );
  return AdminRelease.fromJson(json) ??
      (throw StateError('Ungültige Antwort des Servers.'));
}
