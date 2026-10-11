import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../events/ui/rsvp/rsvp_actions.dart';

/// Asks for the expected arrival of a late member; see [pickLateArrival].
typedef ArrivalPicker =
    Future<LateArrival?> Function(BuildContext context, TheaterEvent event);

/// Answers a still open event right on the start page.
class QuickRsvp extends StatefulWidget {
  const QuickRsvp({
    super.key,
    required this.event,
    required this.controller,
    this.dense = false,
    this.onAnswer,
    this.pickArrival = pickLateArrival,
  });
  final TheaterEvent event;
  final AppController controller;

  /// Small chips for a row on a light card instead of the large tiles on the
  /// dark next-event card.
  final bool dense;

  /// Called right before an answer is sent, e.g. to keep the card in place
  /// while it collapses.
  final VoidCallback? onAnswer;

  /// Replaceable in tests, where the platform time picker is awkward.
  final ArrivalPicker pickArrival;
  @override
  State<QuickRsvp> createState() => _QuickRsvpState();
}

class _QuickRsvpState extends State<QuickRsvp> {
  bool _busy = false;

  /// Sends [status] and confirms it with an undo. The row may disappear
  /// once the answer is in, so feedback goes through the captured messenger.
  Future<void> _send(String status, {DateTime? arrival}) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = widget.controller;
    final before = widget.event;
    widget.onAnswer?.call();
    setState(() => _busy = true);
    try {
      final outcome = await controller.respond(
        before.id,
        status,
        expectedArrivalAt: arrival,
      );
      _confirm(messenger, controller, before, status, outcome);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(userMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _late() async {
    final event = widget.event;
    final start = event.startsAt, end = event.endsAt;
    DateTime? arrival;
    // Without a start or an end there is no window to pick a time in; the
    // arrival then simply stays open.
    if (start != null && end != null) {
      final picked = await widget.pickArrival(context, event);
      if (picked == null || !mounted) return;
      arrival = picked.arrival;
      if (arrival != null &&
          (!arrival.isAfter(start) || !arrival.isBefore(end))) {
        final hm = DateFormat.Hm('de');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Die Ankunft muss zwischen ${hm.format(start)} und '
              '${hm.format(end)} Uhr liegen.',
            ),
          ),
        );
        return;
      }
    }
    await _send('late', arrival: arrival);
  }

  Future<void> _decline() async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = widget.controller;
    final before = widget.event;
    widget.onAnswer?.call();
    // The shared sheet sends the answer and reports its own errors.
    await declineEvent(context, controller, before);
    final after = controller.events.where((e) => e.id == before.id);
    if (before.response == 'no' || after.firstOrNull?.response != 'no') {
      return;
    }
    final queued = controller.outbox.any(
      (a) =>
          !a.failed &&
          a.payload['action'] == 'attendance' &&
          a.payload['eventId'] == before.id,
    );
    _confirm(
      messenger,
      controller,
      before,
      'no',
      queued ? ActionOutcome.queued : ActionOutcome.synced,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final event = widget.event;
    final canDecline = controller.canDecline(event);
    final options = [
      _RsvpOption(
        icon: Icons.thumb_up_alt_outlined,
        label: 'Bin dabei',
        primary: true,
        onTap: _busy ? null : () => _send('yes'),
      ),
      _RsvpOption(
        icon: Icons.schedule,
        label: 'Komme später',
        onTap: _busy ? null : _late,
      ),
      _RsvpOption(
        icon: Icons.thumb_down_alt_outlined,
        label: 'Kann nicht',
        onTap: _busy || !canDecline ? null : _decline,
      ),
    ];
    // Shortly before the start only confirming or arriving late is left.
    final hint = canDecline || !controller.canRespondTo(event)
        ? null
        : 'Absage nicht mehr möglich – bitte melde dich direkt bei der '
              'Probenleitung.';
    if (widget.dense) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [for (final o in options) o.chip()],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      );
    }
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
        if (hint != null) ...[
          const SizedBox(height: 10),
          Text(
            hint,
            style: const TextStyle(color: Color(0xFFDAE0D9), fontSize: 13),
          ),
        ],
      ],
    );
  }
}

/// Confirms a quick answer and offers to take it back while the event still
/// accepts the previous answer.
void _confirm(
  ScaffoldMessengerState messenger,
  AppController controller,
  TheaterEvent before,
  String status,
  ActionOutcome outcome,
) {
  final label = switch (status) {
    'yes' => 'Zusage',
    'late' => 'Später',
    _ => 'Absage',
  };
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          outcomeText(
            outcome,
            done: '$label gespeichert',
            queued: '$label vorgemerkt – wird bei Verbindung gesendet',
          ),
        ),
        action: _canRestore(controller, before)
            ? SnackBarAction(
                label: 'Rückgängig',
                onPressed: () => _restore(messenger, controller, before),
              )
            : null,
      ),
    );
}

bool _canRestore(AppController controller, TheaterEvent before) =>
    controller.canRespondTo(before) &&
    (!const {'open', 'no'}.contains(before.response) ||
        controller.canDecline(before));

Future<void> _restore(
  ScaffoldMessengerState messenger,
  AppController controller,
  TheaterEvent before,
) async {
  try {
    await controller.respond(
      before.id,
      before.response,
      reason: before.declineReason,
      expectedArrivalAt: before.response == 'late'
          ? before.expectedArrivalAt
          : null,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          before.response == 'open'
              ? 'Rückmeldung zurückgenommen'
              : 'Vorherige Rückmeldung wiederhergestellt',
        ),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(userMessage(e))));
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

  /// The same answer as a small chip for rows on light cards.
  Widget chip() => ActionChip(
    avatar: Icon(icon, size: 18),
    label: Text(label),
    visualDensity: VisualDensity.compact,
    onPressed: onTap,
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
