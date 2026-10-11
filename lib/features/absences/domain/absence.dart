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
