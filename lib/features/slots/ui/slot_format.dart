import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/slot_pool.dart';

String slotDay(DateTime day) =>
    '${DateFormat.E('de').format(day).replaceAll('.', '')} '
    '${DateFormat('d.M.', 'de').format(day)}';

String slotTime(TimeSlot slot) =>
    '${DateFormat.Hm('de').format(slot.startsAt)}–'
    '${DateFormat.Hm('de').format(slot.endsAt)}';

String slotLabel(TimeSlot slot) =>
    '${slotDay(slot.startsAt)}, ${slotTime(slot)}';

/// First to last slot, e.g. "Sa 18.10., 10:00–12:00".
String slotPoolRange(SlotPool pool) {
  if (pool.slots.isEmpty) return 'Noch keine Zeitfenster';
  final first = pool.slots.first.startsAt;
  final last = pool.slots.map((s) => s.endsAt).reduce((a, b) {
    return a.isAfter(b) ? a : b;
  });
  if (DateUtils.isSameDay(first, last)) {
    return '${slotDay(first)}, ${DateFormat.Hm('de').format(first)}–'
        '${DateFormat.Hm('de').format(last)}';
  }
  return '${slotDay(first)} – ${slotDay(last)}';
}
