/// JSON helpers shared by the models, the controller and the offline cache.
typedef JsonMap = Map<String, dynamic>;

JsonMap jsonMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

/// Read-only view of [value] as a [JsonMap], avoiding a map copy when [value]
/// is already a [JsonMap]. Callers must never mutate the returned map.
JsonMap readJsonMap(Object? value) => value is JsonMap
    ? value
    : value is Map
    ? Map<String, dynamic>.from(value)
    : const <String, dynamic>{};

List<dynamic> jsonList(Object? value) => value is List ? value : const [];
String textValue(Object? value, [String fallback = '']) =>
    value == null ? fallback : value.toString();
int intValue(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
DateTime? dateValue(Object? value) => DateTime.tryParse(textValue(value));

String dateOnly(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

Object? _cloneValue(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _cloneValue(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) _cloneValue(item)];
  }
  return value;
}

/// Clone JSON snapshots so optimistic changes never alter the server baseline.
JsonMap cloneJson(JsonMap value) => _cloneValue(value)! as JsonMap;
