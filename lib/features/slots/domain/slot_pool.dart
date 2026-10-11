import 'dart:math';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// One bookable time window of a slot pool.
class TimeSlot {
  const TimeSlot({
    required this.id,
    required this.startsAt,
    required this.endsAt,
    this.capacity = 1,
    this.people = const [],
  });
  final String id;
  final DateTime startsAt, endsAt;
  final int capacity;
  final List<({int personId, String name})> people;
  int get booked => people.length;
  int get free => max(0, capacity - booked);
  bool get full => booked >= capacity;
  bool startedAt(DateTime now) => !startsAt.isAfter(now);
  factory TimeSlot.fromJson(JsonMap json) => TimeSlot(
    id: textValue(json['id']),
    startsAt: dateValue(json['startsAt'])!.toLocal(),
    endsAt: dateValue(json['endsAt'])!.toLocal(),
    capacity: intValue(json['capacity'], 1),
    people: [
      for (final p in jsonList(json['people']).map(jsonMap))
        (personId: intValue(p['personId']), name: textValue(p['name'])),
    ],
  );
}

/// A pool of time slots ("Terminfinder"); each invited person books one.
class SlotPool {
  const SlotPool({
    required this.id,
    required this.title,
    this.description = '',
    this.place = '',
    this.kind = 'other',
    this.roleIds = const [],
    this.personIds = const [],
    this.productionIds = const [],
    this.closed = false,
    this.version = 1,
    this.slots = const [],
    this.myBooking,
  });
  final String id, title, description, place, kind;
  final List<String> roleIds;
  final List<int> personIds;
  final List<String> productionIds;
  final bool closed;
  final int version;
  final List<TimeSlot> slots;
  final String? myBooking;
  TimeSlot? get mySlot => slots.where((s) => s.id == myBooking).firstOrNull;

  /// Whether any slot can still be booked by someone without a slot.
  bool hasFreeSlotAt(DateTime now) =>
      slots.any((s) => !s.startedAt(now) && !s.full);
  bool finishedAt(DateTime now) => slots.every((s) => s.startedAt(now));
  factory SlotPool.fromJson(JsonMap json) => SlotPool(
    id: textValue(json['id']),
    title: textValue(json['title']),
    description: textValue(json['description']),
    place: textValue(json['place']),
    kind: textValue(json['type'], 'other'),
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
    personIds: jsonList(json['personIds']).map(intValue).toList(),
    productionIds: jsonList(
      json['productionIds'],
    ).map((e) => e.toString()).toList(),
    closed: json['closed'] == true,
    version: intValue(json['version'], 1),
    slots: [
      for (final s in jsonList(json['slots']).map(jsonMap))
        if (dateValue(s['startsAt']) != null && dateValue(s['endsAt']) != null)
          TimeSlot.fromJson(s),
    ]..sort((a, b) => a.startsAt.compareTo(b.startsAt)),
    myBooking: json['myBooking']?.toString(),
  );
}

List<SlotPool> slotPoolsOf(AppController controller) =>
    controller.slotPools.map(SlotPool.fromJson).toList();

/// Only invited people may book; admins see every pool without being invited.
bool invitedToSlotPool(AppController controller, SlotPool pool) {
  final user = controller.user;
  if (user?.personId == null) return false;
  return TheaterMember(
    id: user!.personId!,
    name: user.name,
    roleIds: user.roleIds,
  ).inAudience(
    pool.roleIds,
    pool.personIds,
    controller.ensemblesOf(pool.productionIds),
  );
}

/// Open pools in which the signed-in person still has to choose a slot.
List<SlotPool> slotPoolsToChoose(AppController controller) =>
    slotPoolsOf(controller)
        .where(
          (p) =>
              !p.closed &&
              p.myBooking == null &&
              invitedToSlotPool(controller, p) &&
              p.hasFreeSlotAt(controller.now),
        )
        .toList();

int slotPoolsAwaitingChoice(AppController controller) =>
    slotPoolsToChoose(controller).length;

/// Gapless windows of [minutes] from [from] until [to]; a shorter rest is
/// dropped.
List<(DateTime, DateTime)> slotWindows(
  DateTime from,
  DateTime to,
  int minutes,
) {
  final windows = <(DateTime, DateTime)>[];
  var start = from;
  while (true) {
    final end = start.add(Duration(minutes: minutes));
    if (end.isAfter(to)) break;
    windows.add((start, end));
    start = end;
  }
  return windows;
}
