import 'models.dart';

class SceneAvailability {
  const SceneAvailability(this.status, this.details);
  final String status;
  final List<String> details;
  bool get playable => status == 'playable';
}

SceneAvailability evaluateScene({
  required ScriptScene scene,
  required JsonMap casting,
  required JsonMap checkins,
  required JsonMap responses,
  required JsonMap arrivals,
  required bool useCheckins,
  required DateTime at,
}) {
  var unknown = false, missing = false;
  final details = <String>[];
  for (final role in scene.roles) {
    final person = casting[role];
    if (person == null) {
      unknown = true;
      details.add('$role: Besetzung offen');
      continue;
    }
    final key = person.toString();
    if (useCheckins) {
      if (checkins[key] == true) continue;
      if (checkins[key] == false) {
        missing = true;
        details.add('$role fehlt');
      } else {
        unknown = true;
        details.add('$role noch nicht erfasst');
      }
    } else {
      switch (textValue(responses[key], 'open')) {
        case 'yes':
          break;
        case 'no':
          missing = true;
          details.add('$role abgesagt');
        case 'late':
          final arrival = dateValue(arrivals[key]);
          if (arrival == null) {
            unknown = true;
            details.add('$role kommt später, Uhrzeit offen');
          } else if (arrival.isAfter(at)) {
            missing = true;
            final local = arrival.toLocal();
            details.add(
              '$role ab ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
            );
          }
        default:
          unknown = true;
          details.add('$role ohne Rückmeldung');
      }
    }
  }
  return SceneAvailability(
    missing
        ? 'missing'
        : unknown
        ? 'unknown'
        : 'playable',
    details,
  );
}
