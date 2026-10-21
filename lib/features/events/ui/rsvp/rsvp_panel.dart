import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../app/theme/stage_theme.dart';

import '../../../../core/app_controller.dart';
import '../../../../core/models.dart';
import '../../../../shared/feedback.dart';
import '../event_style.dart';
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

  /// Saves [status]; [done] confirms it, or [queued] while it waits in the
  /// outbox for a connection.
  Future<void> _save(String status, {String? done, String? queued}) async {
    setState(() => _busy = true);
    try {
      final outcome = await widget.controller.respond(
        widget.event.id,
        status,
        expectedArrivalAt: status == 'late' ? _arrival : null,
      );
      if (mounted) setState(() => _editingLate = false);
      if (done != null && mounted) {
        showDone(
          context,
          outcomeText(outcome, done: done, queued: queued ?? done),
        );
      }
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

  /// Withdraws the decline of an auto-accepted event. Without an own answer
  /// the person attends again; after the decline cutoff, or when an own
  /// absence covers the day, only an explicit yes brings that back.
  void _withdrawDecline() {
    final e = widget.event, start = e.startsAt;
    final absent =
        start != null &&
        widget.controller.absences.any((a) => a.coversDay(start));
    _save(
      widget.controller.canDecline(e) && !absent ? 'open' : 'yes',
      done: 'Du bist wieder eingeplant.',
      queued: 'Rücknahme vorgemerkt – wird bei Verbindung gesendet',
    );
  }

  Widget _choice(
    String status,
    String label,
    IconData icon,
    VoidCallback action,
  ) {
    // The implicit yes of an auto-accepted event shows as chosen.
    final implicit =
        !_editingLate && status == 'yes' && widget.event.implicitYes;
    final selected = _editingLate
        ? status == 'late'
        : widget.event.response == status || implicit;
    final enabled =
        !_busy &&
        (status == 'no'
            ? widget.controller.canDecline(widget.event)
            : widget.controller.canRespondTo(widget.event));
    final color = responseColor(
      status,
      dark: Theme.of(context).brightness == Brightness.dark,
    );
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
          label: Text(implicit ? '$label · automatisch' : label),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (implicit)
                          Text(
                            'automatisch',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
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
          !canRespond
              ? 'Deine Rückmeldung'
              // Planned in means attending: an absence without a decline
              // row ends the implicit yes as well.
              : e.autoAccept && e.attending
              ? 'Du bist eingeplant'
              : 'Bist du dabei?',
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
              status: displayResponse(e),
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
              color: Theme.of(context).brightness == Brightness.dark
                  ? StageTheme.amberTone.dark.withValues(alpha: .12)
                  : const Color(0xFFFFE9BF).withValues(alpha: .35),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.schedule,
                  color: responseColor(
                    'late',
                    dark: Theme.of(context).brightness == Brightness.dark,
                  ),
                  size: 30,
                ),
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
        ] else if (e.implicitYes && canRespond)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              // A withdrawn decline waiting in the outbox is not saved yet.
              pending
                  ? 'Auf diesem Gerät vorgemerkt'
                  : 'Alle gelten als zugesagt. Kannst du nicht? Bitte absagen.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else if (e.response != 'open')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              pending
                  ? 'Auf diesem Gerät vorgemerkt'
                  : 'Rückmeldung gespeichert',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        // On auto-accepted events only a decline is withdrawn: an own yes
        // and the implicit one mean the same.
        if (!_editingLate && e.autoAccept && e.response == 'no' && canRespond)
          TextButton(
            onPressed: _busy ? null : _withdrawDecline,
            child: const Text('Absage zurücknehmen'),
          )
        else if (!_editingLate &&
            !e.autoAccept &&
            e.response != 'open' &&
            canDecline)
          TextButton(
            onPressed: _busy ? null : () => _save('open'),
            child: const Text('Rückmeldung zurücknehmen'),
          ),
      ],
    );
  }
}
