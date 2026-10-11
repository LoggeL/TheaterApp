import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/app_controller.dart';
import '../../../../core/models.dart';
import '../../../../shared/feedback.dart';
import '../../../../shared/navigation.dart';
import '../../../absences/ui/absences_screen.dart';

Future<void> declineEvent(
  BuildContext context,
  AppController controller,
  TheaterEvent event,
) async {
  final reason = TextEditingController(text: event.declineReason);
  // Longer absences are reported once instead of declining event by event.
  var reportAbsence = false;
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        4,
        24,
        MediaQuery.viewInsetsOf(ctx).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dieses Mal ohne dich.',
            style: Theme.of(ctx).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Ein kurzer Grund hilft bei der Probenplanung. Die Angabe ist freiwillig und nur für die Theaterleitung sichtbar.',
          ),
          const SizedBox(height: 18),
          TextField(
            controller: reason,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Absagegrund (optional)',
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx, reason.text.trim()),
              child: const Text('Absagen'),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: () {
                reportAbsence = true;
                Navigator.pop(ctx);
              },
              child: const Text('Länger weg? Abwesenheit melden'),
            ),
          ),
        ],
      ),
    ),
  );
  if (reportAbsence && context.mounted) {
    openPage(context, AddAbsenceScreen(controller: controller));
  } else if (result != null && context.mounted) {
    await runAction(
      context,
      () => controller.respond(event.id, 'no', reason: result),
    );
  }
  // Let the closing sheet finish using its controller before disposal.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  reason.dispose();
}

/// The result of [pickLateArrival]; [arrival] null means "time still open".
class LateArrival {
  const LateArrival(this.arrival);
  final DateTime? arrival;
}

/// Asks for the expected arrival time. Resolves to null when cancelled.
///
/// The dialog only accepts a time after the start and before the end and
/// offers 'Ohne Uhrzeit'. Without a start or an end there is nothing to
/// check a time against, so it resolves to an open time without asking.
Future<LateArrival?> pickLateArrival(
  BuildContext context,
  TheaterEvent event, {
  DateTime? initial,
}) async {
  final start = event.startsAt, end = event.endsAt;
  if (start == null || end == null) return const LateArrival(null);
  return showDialog<LateArrival>(
    context: context,
    builder: (_) => _LateArrivalDialog(
      start: start,
      end: end,
      initial: initial ?? _suggestedArrival(start, end),
    ),
  );
}

/// Half an hour after the start, or halfway for shorter events.
DateTime _suggestedArrival(DateTime start, DateTime end) {
  final later = start.add(const Duration(minutes: 30));
  return later.isBefore(end)
      ? later
      : start.add(Duration(minutes: end.difference(start).inMinutes ~/ 2));
}

/// The arrival for a picked wall-clock [time] on the day of [start]; a time
/// before the start belongs to the next day for events that end after
/// midnight.
DateTime _arrivalAt(TimeOfDay time, DateTime start, DateTime end) {
  final arrival = DateTime(
    start.year,
    start.month,
    start.day,
    time.hour,
    time.minute,
  );
  if (!arrival.isAfter(start) && dateOnly(end) != dateOnly(start)) {
    return arrival.add(const Duration(days: 1));
  }
  return arrival;
}

class _LateArrivalDialog extends StatefulWidget {
  const _LateArrivalDialog({
    required this.start,
    required this.end,
    required this.initial,
  });
  final DateTime start, end, initial;
  @override
  State<_LateArrivalDialog> createState() => _LateArrivalDialogState();
}

class _LateArrivalDialogState extends State<_LateArrivalDialog> {
  late DateTime _arrival = widget.initial;

  bool get _valid =>
      _arrival.isAfter(widget.start) && _arrival.isBefore(widget.end);

  String _time(DateTime t) => DateFormat.Hm('de').format(t);

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_arrival),
    );
    if (time == null || !mounted) return;
    setState(() => _arrival = _arrivalAt(time, widget.start, widget.end));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Common choices shortly after the start, as long as they are valid.
    final quick = [
      for (final minutes in const [15, 30, 60])
        if (widget.start.add(Duration(minutes: minutes)).isBefore(widget.end))
          widget.start.add(Duration(minutes: minutes)),
    ];
    return AlertDialog(
      title: const Text('Voraussichtlich da ab'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Der Termin geht von ${_time(widget.start)} bis '
            '${_time(widget.end)} Uhr.',
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _pickTime,
            icon: const Icon(Icons.schedule),
            label: Text('${_time(_arrival)} Uhr'),
          ),
          if (!_valid) ...[
            const SizedBox(height: 8),
            Text(
              'Bitte eine Uhrzeit nach ${_time(widget.start)} und vor '
              '${_time(widget.end)} Uhr wählen.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (quick.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final time in quick)
                  ChoiceChip(
                    label: Text(_time(time)),
                    selected: time == _arrival,
                    onSelected: (_) => setState(() => _arrival = time),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const LateArrival(null)),
          child: const Text('Ohne Uhrzeit'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _valid
              ? () => Navigator.pop(context, LateArrival(_arrival))
              : null,
          child: const Text('Übernehmen'),
        ),
      ],
    );
  }
}
