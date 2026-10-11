import 'package:intl/intl.dart';

/// How long the server refuses another reminder for the same target.
const remindCooldown = Duration(minutes: 10);

/// Whether a reminder sent at [last] still blocks the next one at [now].
bool remindCoolingDown(DateTime? last, DateTime now) =>
    last != null && now.difference(last) < remindCooldown;

/// "Zuletzt erinnert: heute, 18:30 (2×)" for a reminder sent at [at].
String lastRemindedLabel(DateTime at, int count, DateTime now) {
  final local = at.toLocal(), today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final date = switch (today.difference(day).inDays) {
    0 => 'heute',
    1 => 'gestern',
    _ => DateFormat('d. MMMM', 'de').format(local),
  };
  final times = count > 1 ? ' ($count×)' : '';
  return 'Zuletzt erinnert: $date, ${DateFormat.Hm('de').format(local)}$times';
}
