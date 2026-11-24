import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/slot_pool.dart';

final _slotWeekday = DateFormat.E('de');
final _slotDayMonth = DateFormat('d.M.', 'de');
final _slotHm = DateFormat.Hm('de');

String slotDay(DateTime day) =>
    '${_slotWeekday.format(day).replaceAll('.', '')} '
    '${_slotDayMonth.format(day)}';

String slotTime(TimeSlot slot) =>
    '${_slotHm.format(slot.startsAt)}–'
    '${_slotHm.format(slot.endsAt)}';

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
    return '${slotDay(first)}, ${_slotHm.format(first)}–'
        '${_slotHm.format(last)}';
  }
  return '${slotDay(first)} – ${slotDay(last)}';
}
