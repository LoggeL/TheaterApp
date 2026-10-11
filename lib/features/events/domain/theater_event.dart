import '../../../core/json.dart';

class TheaterEvent {
  const TheaterEvent({
    required this.id,
    required this.title,
    this.startsAt,
    this.endsAt,
    this.description = '',
    this.time = '',
    this.place = '',
    this.kind = 'other',
    this.tone = 'orange',
    this.locked = false,
    this.attendeeCount = 0,
    this.response = 'open',
    this.declineReason = '',
    this.productionId,
    this.sceneIds = const [],
    this.isCustom = false,
    this.expectedArrivalAt,
    this.version = 1,
    this.roleIds = const [],
    this.personIds = const [],
    this.productionIds = const [],
    this.slotPoolId,
    this.seriesId,
    this.addressedToMe = true,
    this.lastRemindedAt,
    this.remindCount = 0,
  });
  final String id,
      title,
      description,
      time,
      place,
      kind,
      tone,
      response,
      declineReason;
  final DateTime? startsAt, endsAt;
  final bool locked, isCustom;
  final int attendeeCount;
  final String? productionId;
  final List<String> sceneIds;
  final DateTime? expectedArrivalAt;
  final int version;

  /// Person roles addressed by this event; empty means everyone.
  final List<String> roleIds;

  /// Productions whose whole ensemble is invited.
  final List<String> productionIds;

  /// People invited by name in addition to [roleIds].
  final List<int> personIds;

  /// Set for events generated from a booked slot of a slot pool; their
  /// attendance follows the booking instead of a response.
  final String? slotPoolId;
  bool get fromSlotPool => slotPoolId != null;

  /// Shared by the events created together as a recurring series; each one is
  /// still edited on its own.
  final String? seriesId;
  bool get inSeries => seriesId != null;

  /// Whether the signed-in person is invited. Always true for members; admins
  /// also receive events of other groups and other people's slot events.
  final bool addressedToMe;

  /// When an admin last reminded the open invitees, and how often (admins on
  /// servers with `nudges` only).
  final DateTime? lastRemindedAt;
  final int remindCount;
  bool get needsResponse =>
      response == 'open' && !locked && !fromSlotPool && addressedToMe;
  bool acceptsResponsesAt(DateTime now) =>
      !locked &&
      !fromSlotPool &&
      !((endsAt ?? startsAt)?.isBefore(now) ?? false);

  /// Shortly before the start, members may still confirm or report a late
  /// arrival, but can no longer decline or withdraw. Mirrors the server.
  static const declineCutoff = Duration(hours: 1);
  bool acceptsDeclineAt(DateTime now) =>
      acceptsResponsesAt(now) &&
      (startsAt == null || startsAt!.subtract(declineCutoff).isAfter(now));
  factory TheaterEvent.fromJson(JsonMap json) => TheaterEvent(
    id: textValue(json['id']),
    title: textValue(json['title']),
    description: textValue(json['description']),
    startsAt: dateValue(json['startsAt'])?.toLocal(),
    endsAt: dateValue(json['endsAt'])?.toLocal(),
    time: textValue(json['time']),
    place: textValue(json['place']),
    kind: textValue(json['type'] ?? json['kind'], 'other'),
    tone: textValue(json['tone'], 'orange'),
    locked: json['locked'] == true,
    isCustom: json['isCustom'] == true,
    attendeeCount: intValue(json['people'] ?? json['attendeeCount']),
    response: textValue(json['response'], 'open'),
    declineReason: textValue(json['declineReason']),
    expectedArrivalAt: dateValue(json['expectedArrivalAt'])?.toLocal(),
    version: intValue(json['version'], 1),
    productionId: json['productionId'] as String?,
    sceneIds: jsonList(json['sceneIds']).map((e) => e.toString()).toList(),
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
    personIds: jsonList(json['personIds']).map(intValue).toList(),
    productionIds: jsonList(
      json['productionIds'],
    ).map((e) => e.toString()).toList(),
    slotPoolId: json['slotPoolId'] == null
        ? null
        : textValue(json['slotPoolId']),
    seriesId: json['seriesId'] == null ? null : textValue(json['seriesId']),
    addressedToMe: json['addressedToMe'] != false,
    lastRemindedAt: dateValue(json['lastRemindedAt'])?.toLocal(),
    remindCount: intValue(json['remindCount']),
  );
  TheaterEvent copyWith({
    String? response,
    bool? addressedToMe,
    String? declineReason,
    DateTime? expectedArrivalAt,
    bool clearExpectedArrival = false,
  }) => TheaterEvent(
    id: id,
    title: title,
    description: description,
    startsAt: startsAt,
    endsAt: endsAt,
    time: time,
    place: place,
    kind: kind,
    tone: tone,
    locked: locked,
    attendeeCount: attendeeCount,
    response: response ?? this.response,
    declineReason: declineReason ?? this.declineReason,
    productionId: productionId,
    sceneIds: sceneIds,
    isCustom: isCustom,
    expectedArrivalAt: clearExpectedArrival
        ? null
        : expectedArrivalAt ?? this.expectedArrivalAt,
    version: version,
    roleIds: roleIds,
    personIds: personIds,
    productionIds: productionIds,
    slotPoolId: slotPoolId,
    seriesId: seriesId,
    addressedToMe: addressedToMe ?? this.addressedToMe,
    lastRemindedAt: lastRemindedAt,
    remindCount: remindCount,
  );
  JsonMap toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'startsAt': startsAt?.toIso8601String(),
    'endsAt': endsAt?.toIso8601String(),
    'time': time,
    'place': place,
    'type': kind,
    'tone': tone,
    'locked': locked,
    'isCustom': isCustom,
    'people': attendeeCount,
    'response': response,
    'declineReason': declineReason,
    'expectedArrivalAt': expectedArrivalAt?.toUtc().toIso8601String(),
    'version': version,
    'roleIds': roleIds,
    'personIds': personIds,
    'productionIds': productionIds,
    'productionId': productionId,
    'sceneIds': sceneIds,
    if (slotPoolId != null) 'slotPoolId': slotPoolId,
    if (seriesId != null) 'seriesId': seriesId,
    if (!addressedToMe) 'addressedToMe': false,
    if (lastRemindedAt != null)
      'lastRemindedAt': lastRemindedAt!.toUtc().toIso8601String(),
    if (remindCount != 0) 'remindCount': remindCount,
  };
}
