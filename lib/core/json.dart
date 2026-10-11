import 'dart:convert';

/// JSON helpers shared by the models, the controller and the offline cache.
typedef JsonMap = Map<String, dynamic>;

JsonMap jsonMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<dynamic> jsonList(Object? value) => value is List ? value : const [];
String textValue(Object? value, [String fallback = '']) =>
    value == null ? fallback : value.toString();
int intValue(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
DateTime? dateValue(Object? value) => DateTime.tryParse(textValue(value));

String dateOnly(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Clone JSON snapshots so optimistic changes never alter the server baseline.
JsonMap cloneJson(JsonMap value) => jsonMap(jsonDecode(jsonEncode(value)));
