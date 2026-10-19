import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../app/theme/stage_theme.dart';
import '../../../../core/app_controller.dart';
import '../../../../core/models.dart';
import '../../domain/event_format.dart';
import '../event_style.dart';

Color statusColor(String status) => responseColor(status);

class RsvpStatusBadge extends StatelessWidget {
  const RsvpStatusBadge({
    super.key,
    required this.status,
    this.expectedArrivalAt,
    this.locked = false,
    this.onDark = false,
    this.emphasizeOpen = false,
    this.showLabel = false,
  });

  final String status;
  final DateTime? expectedArrivalAt;
  final bool locked, onDark;

  /// Draws an open, still answerable response in the accent colour.
  final bool emphasizeOpen;

  /// Spells out an open response next to the icon: 'Offen' while it can
  /// still be given, 'Geschlossen' once responses are closed.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final arrival = status == 'late' && expectedArrivalAt != null
        ? DateFormat.Hm('de').format(expectedArrivalAt!.toLocal())
        : null;
    final short =
        arrival ??
        (showLabel && status == 'open'
            ? locked
                  ? 'Geschlossen'
                  : 'Offen'
            : null);
    final label = [
      status == 'open' ? 'Rückmeldung offen' : statusText(status),
      if (status == 'late') arrival ?? 'Uhrzeit offen',
      if (locked) 'Rückmeldung geschlossen',
    ].join(' · ');
    final pending = emphasizeOpen && status == 'open' && !locked;
    final icon = switch (status) {
      'yes' => Icons.thumb_up_alt,
      'no' => Icons.thumb_down_alt,
      'late' => Icons.schedule,
      _ when pending => Icons.mark_email_unread_outlined,
      _ => Icons.help_outline,
    };
    final dark = onDark || Theme.of(context).brightness == Brightness.dark;
    final (fill: _, foreground: color) = StageTheme.tintedLabel(
      pending
          ? dark
                ? const Color(0xFFFFB18A)
                : StageTheme.orangeTone.light
          : responseColor(status, dark: dark),
      dark ? Brightness.dark : Brightness.light,
      alpha: pending ? .16 : .12,
    );
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: pending ? .16 : .12),
            borderRadius: BorderRadius.circular(16),
            border: pending
                ? Border.all(color: color.withValues(alpha: .55))
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              if (short != null) ...[
                const SizedBox(width: 5),
                Text(
                  short,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (locked && short != 'Geschlossen') ...[
                const SizedBox(width: 4),
                Icon(Icons.lock_outline, size: 12, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether the badge shows a lock. Slot pool events have no responses at
/// all; their attendance follows the booking, so no lock is shown.
bool responsesClosed(AppController controller, TheaterEvent event) =>
    !event.fromSlotPool && !controller.canRespondTo(event);
