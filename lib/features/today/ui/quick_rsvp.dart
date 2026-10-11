import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../events/ui/rsvp/rsvp_actions.dart';

/// Answers a still open event right on the start page.
class QuickRsvp extends StatefulWidget {
  const QuickRsvp({super.key, required this.event, required this.controller});
  final TheaterEvent event;
  final AppController controller;
  @override
  State<QuickRsvp> createState() => _QuickRsvpState();
}

class _QuickRsvpState extends State<QuickRsvp> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _late() async {
    final start = widget.event.startsAt;
    final time = start == null
        ? null
        : await showTimePicker(
            context: context,
            helpText: 'Voraussichtlich da ab',
            initialTime: TimeOfDay.fromDateTime(
              start.add(const Duration(minutes: 30)),
            ),
          );
    if ((start != null && time == null) || !mounted) return;
    await _run(
      () => widget.controller.respond(
        widget.event.id,
        'late',
        expectedArrivalAt: start == null
            ? null
            : DateTime(
                start.year,
                start.month,
                start.day,
                time!.hour,
                time.minute,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final options = [
      _RsvpOption(
        icon: Icons.thumb_up_alt_outlined,
        label: 'Bin dabei',
        primary: true,
        onTap: _busy
            ? null
            : () =>
                  _run(() => widget.controller.respond(widget.event.id, 'yes')),
      ),
      _RsvpOption(
        icon: Icons.schedule,
        label: 'Komme später',
        onTap: _busy ? null : _late,
      ),
      _RsvpOption(
        icon: Icons.thumb_down_alt_outlined,
        label: 'Kann nicht',
        onTap: _busy || !widget.controller.canDecline(widget.event)
            ? null
            : () => declineEvent(context, widget.controller, widget.event),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Bist du dabei?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            // Three equal tiles side by side; stacked when space is tight.
            final stacked =
                constraints.maxWidth < 260 ||
                MediaQuery.textScalerOf(context).scale(14) > 20;
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, o) in options.indexed) ...[
                    if (i > 0) const SizedBox(height: 8),
                    o,
                  ],
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, o) in options.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: o.vertical()),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// One answer on the dark next-event card.
class _RsvpOption extends StatelessWidget {
  const _RsvpOption({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.column = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary, column;

  _RsvpOption vertical() => _RsvpOption(
    icon: icon,
    label: label,
    onTap: onTap,
    primary: primary,
    column: true,
  );

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final foreground = primary ? StageTheme.ink : Colors.white;
    final content = [
      Icon(icon, size: column ? 22 : 18, color: foreground),
      SizedBox(width: column ? 0 : 10, height: column ? 6 : 0),
      Flexible(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: foreground,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    ];
    return Semantics(
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : .45,
        child: Material(
          color: primary ? Colors.white : Colors.white.withValues(alpha: .06),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: primary
                ? BorderSide.none
                : BorderSide(color: Colors.white.withValues(alpha: .28)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: column ? 14 : 13,
              ),
              child: column
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: content,
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: content,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
