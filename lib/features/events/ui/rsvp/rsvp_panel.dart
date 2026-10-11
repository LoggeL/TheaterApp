import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/app_controller.dart';
import '../../../../core/models.dart';
import '../../../../shared/feedback.dart';
import 'rsvp_actions.dart';
import 'rsvp_status_badge.dart';

class RsvpPanel extends StatefulWidget {
  const RsvpPanel({
    super.key,
    required this.controller,
    required this.event,
    this.compact = false,
  });
  final AppController controller;
  final TheaterEvent event;
  final bool compact;
  @override
  State<RsvpPanel> createState() => _RsvpPanelState();
}

class _RsvpPanelState extends State<RsvpPanel> {
  bool _editingLate = false, _busy = false;
  DateTime? _arrival;
  Future<void> _save(String status) async {
    setState(() => _busy = true);
    try {
      await widget.controller.respond(
        widget.event.id,
        status,
        expectedArrivalAt: status == 'late' ? _arrival : null,
      );
      if (mounted) setState(() => _editingLate = false);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime() async {
    final picked = await pickLateArrival(
      context,
      widget.event,
      initial: _arrival,
    );
    if (picked == null || !mounted) return;
    setState(() => _arrival = picked.arrival);
  }

  Widget _choice(
    String status,
    String label,
    IconData icon,
    VoidCallback action,
  ) {
    final selected = _editingLate
        ? status == 'late'
        : widget.event.response == status;
    final enabled =
        !_busy &&
        (status == 'no'
            ? widget.controller.canDecline(widget.event)
            : widget.controller.canRespondTo(widget.event));
    final color = statusColor(status);
    if (widget.compact) {
      return Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: OutlinedButton.icon(
          onPressed: enabled ? action : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            backgroundColor: selected ? color.withValues(alpha: .11) : null,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          icon: Icon(icon, size: 18),
          label: Text(label),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      // One of three exclusive choices, announced like a radio button.
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        enabled: enabled,
        child: Material(
          color: selected
              ? color.withValues(alpha: .11)
              : Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: selected
                  ? color.withValues(alpha: .45)
                  : Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: .5),
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: enabled ? action : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              child: Row(
                children: [
                  Icon(icon, color: color),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? color
                        : Theme.of(context).colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final canRespond = widget.controller.canRespondTo(e);
    final canDecline = widget.controller.canDecline(e);
    final pending = widget.controller.outbox.any(
      (a) =>
          !a.failed &&
          a.payload['action'] == 'attendance' &&
          a.payload['eventId'] == e.id,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          canRespond ? 'Bist du dabei?' : 'Deine Rückmeldung',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        if (canRespond)
          if (widget.compact)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _choice(
                  'yes',
                  'Bin dabei',
                  Icons.thumb_up_alt_outlined,
                  () => _save('yes'),
                ),
                _choice(
                  'late',
                  'Komme später',
                  Icons.schedule,
                  () => setState(() {
                    _editingLate = true;
                    _arrival = e.expectedArrivalAt;
                  }),
                ),
                _choice(
                  'no',
                  'Kann nicht',
                  Icons.thumb_down_alt_outlined,
                  () => declineEvent(context, widget.controller, e),
                ),
              ],
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _choice(
                  'yes',
                  'Bin dabei',
                  Icons.thumb_up_alt_outlined,
                  () => _save('yes'),
                ),
                _choice(
                  'late',
                  'Komme später',
                  Icons.schedule,
                  () => setState(() {
                    _editingLate = true;
                    _arrival = e.expectedArrivalAt;
                  }),
                ),
                _choice(
                  'no',
                  'Kann nicht',
                  Icons.thumb_down_alt_outlined,
                  () => declineEvent(context, widget.controller, e),
                ),
              ],
            )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: RsvpStatusBadge(
              status: e.response,
              expectedArrivalAt: e.expectedArrivalAt,
              locked: true,
            ),
          ),
        if (!canRespond)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              e.locked
                  ? 'Rückmeldungen sind geschlossen.'
                  : 'Der Termin ist vorbei. Rückmeldungen sind geschlossen.',
            ),
          ),
        if (canRespond && !canDecline)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Ab einer Stunde vor Beginn ist keine Absage mehr möglich. '
              'Bitte melde dich direkt bei der Probenleitung.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_editingLate && canRespond) ...[
          const SizedBox(height: 12),
          const Text('Voraussichtlich da ab'),
          const SizedBox(height: 8),
          if (e.startsAt == null || e.endsAt == null)
            Text(
              e.startsAt == null
                  ? 'Für diesen Termin steht noch keine Uhrzeit fest, '
                        'deshalb bleibt deine Ankunft offen.'
                  : 'Für diesen Termin ist keine Endzeit eingetragen, '
                        'deshalb bleibt deine Ankunft offen.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Card(
              child: ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(
                  _arrival == null
                      ? 'Uhrzeit optional'
                      : '${DateFormat.Hm('de').format(_arrival!)} Uhr',
                ),
                onTap: _pickTime,
                trailing: _arrival == null
                    ? const Icon(Icons.edit_outlined)
                    : IconButton(
                        tooltip: 'Uhrzeit entfernen',
                        onPressed: () => setState(() => _arrival = null),
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : () => _save('late'),
            child: const Text('Späterkommen speichern'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() => _editingLate = false),
            child: const Text('Abbrechen'),
          ),
        ] else if (e.response == 'late') ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFFFFE9BF).withValues(alpha: .35),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.schedule, color: Color(0xFFA25B06), size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.expectedArrivalAt == null
                            ? 'Später · Uhrzeit offen'
                            : 'Voraussichtlich ${DateFormat.Hm('de').format(e.expectedArrivalAt!)} Uhr',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        pending
                            ? 'Auf diesem Gerät vorgemerkt'
                            : 'Rückmeldung gespeichert',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ] else if (e.response != 'open')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              pending
                  ? 'Auf diesem Gerät vorgemerkt'
                  : 'Rückmeldung gespeichert',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (!_editingLate && e.response != 'open' && canDecline)
          TextButton(
            onPressed: _busy ? null : () => _save('open'),
            child: const Text('Rückmeldung zurücknehmen'),
          ),
      ],
    );
  }
}
