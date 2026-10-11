import '../../../core/json.dart';

class FocusState {
  const FocusState({
    required this.productionId,
    this.revision = '',
    this.cueId,
    this.sequence = 0,
    this.updatedBy,
    this.updatedAt,
    this.canDirect = false,
    this.source = 'app',
    this.connected = true,
  });
  final String source;
  final bool connected;
  final String productionId, revision;
  final String? cueId, updatedBy;
  final DateTime? updatedAt;
  final int sequence;
  final bool canDirect;
  factory FocusState.fromJson(JsonMap json) => FocusState(
    productionId: textValue(json['productionId']),
    revision: textValue(json['revision']),
    cueId: json['cueId'] as String?,
    sequence: intValue(json['sequence']),
    updatedBy: json['updatedBy'] as String?,
    updatedAt: dateValue(json['updatedAt']),
    canDirect: json['canDirect'] == true,
    source: textValue(json['source'], 'app'),
    connected: json['connected'] != false,
  );
}
