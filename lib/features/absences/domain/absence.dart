import '../../../core/json.dart';

class Absence {
  const Absence({
    required this.id,
    required this.from,
    required this.to,
    this.reason = '',
  });
  final String id, reason;
  final DateTime from, to;

  /// Whether the absence covers the calendar [day] (from and to inclusive).
  bool coversDay(DateTime day) {
    final d = dateOnly(day);
    return d.compareTo(dateOnly(from)) >= 0 && d.compareTo(dateOnly(to)) <= 0;
  }

  factory Absence.fromJson(JsonMap json) => Absence(
    id: textValue(json['id']),
    from: DateTime.parse(textValue(json['from'])),
    to: DateTime.parse(textValue(json['to'])),
    reason: textValue(json['reason']),
  );
  JsonMap toJson() => {
    'id': id,
    'from': dateOnly(from),
    'to': dateOnly(to),
    'reason': reason,
  };
}
