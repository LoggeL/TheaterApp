import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../events/domain/event_format.dart';
import '../domain/absence_impact.dart';

String _period(DateTime from, DateTime to) =>
    '${DateFormat('dd.MM.yyyy').format(from)} – ${DateFormat('dd.MM.yyyy').format(to)}';

String _events(int count) => count == 1 ? '1 Termin' : '$count Termine';

class AbsencesScreen extends StatelessWidget {
  const AbsencesScreen({super.key, required this.controller});
  final AppController controller;

  Future<void> _delete(BuildContext context, Absence absence) async {
    final reopenable =
        controller.supports('absenceOutcome') &&
        !absence.id.startsWith('local:');
    final bool? reopen;
    if (reopenable) {
      reopen = await showDialog<bool>(
        context: context,
        builder: (context) => const _DeleteAbsenceDialog(),
      );
      if (reopen == null) return;
    } else {
      final confirmed = await confirmDestructive(
        context,
        title: 'Abwesenheit entfernen?',
        message:
            'Bereits gespeicherte Absagen bleiben bestehen. Ändere sie bei Bedarf im jeweiligen Termin.',
        confirmLabel: 'Entfernen',
      );
      if (!confirmed) return;
      reopen = false;
    }
    if (!context.mounted) return;
    try {
      final result = await controller.deleteAbsence(absence.id, reopen: reopen);
      final reopened = jsonList(result.data?['reopenedEventIds']).length;
      if (context.mounted) {
        showDone(
          context,
          reopened == 0
              ? 'Abwesenheit entfernt.'
              : 'Abwesenheit entfernt · ${_events(reopened)} wieder geöffnet.',
        );
      }
    } catch (e) {
      if (context.mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final today = dateOnly(controller.now);
      final absences = [...controller.absences]
        ..sort((a, b) => a.from.compareTo(b.from));
      final current = absences
          .where((a) => dateOnly(a.to).compareTo(today) >= 0)
          .toList();
      final past = absences
          .where((a) => dateOnly(a.to).compareTo(today) < 0)
          .toList()
          .reversed
          .toList();
      Widget card(Absence absence) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: _AbsenceCard(
          absence: absence,
          onDelete: () => _delete(context, absence),
        ),
      );
      return Scaffold(
        appBar: AppBar(title: const Text('Abwesenheiten')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () =>
              openPage(context, AddAbsenceScreen(controller: controller)),
          icon: const Icon(Icons.add),
          label: const Text('Zeitraum melden'),
        ),
        body: ListView(
          padding: pagePadding(context, top: 16, bottom: 100),
          children: [
            Text(
              'Mal nicht da?',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            const Text(
              'Sag dem Ensemble Bescheid, wenn du länger fehlst. Passende bestehende Proben werden beim Speichern automatisch abgesagt.',
            ),
            const SizedBox(height: 8),
            if (absences.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: EmptyState(
                  icon: Icons.beach_access_outlined,
                  title: 'Keine Abwesenheiten',
                  message:
                      'Urlaub, Arbeit oder eine Pause: Melde hier deinen Zeitraum.',
                ),
              )
            else ...[
              const SectionTitle('Aktuell & geplant'),
              if (current.isEmpty)
                Text(
                  'Gerade ist keine Abwesenheit gemeldet.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ...current.map(card),
              if (past.isNotEmpty) ...[
                const SizedBox(height: 14),
                Card(
                  child: ExpansionTile(
                    shape: const Border(),
                    leading: const Icon(Icons.history),
                    title: Text('Vergangen (${past.length})'),
                    childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                    children: past.map(card).toList(),
                  ),
                ),
              ],
            ],
          ],
        ),
      );
    },
  );
}

/// Confirms removing an absence and asks whether the events it declined
/// should be reopened (servers with `absenceOutcome`). Resolves to null when
/// the member cancels, else to the reopen choice.
class _DeleteAbsenceDialog extends StatefulWidget {
  const _DeleteAbsenceDialog();
  @override
  State<_DeleteAbsenceDialog> createState() => _DeleteAbsenceDialogState();
}

class _DeleteAbsenceDialogState extends State<_DeleteAbsenceDialog> {
  bool _reopen = true;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      scrollable: true,
      title: const Text('Abwesenheit entfernen?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Termine, die beim Melden automatisch abgesagt wurden, kannst du wieder öffnen. Gesperrte Termine und solche, die bald beginnen, bleiben abgesagt.',
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _reopen,
            onChanged: (value) => setState(() => _reopen = value ?? false),
            title: const Text('Abgesagte Termine wieder öffnen'),
          ),
        ],
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(context, _reopen),
          child: const Text('Entfernen'),
        ),
      ],
    );
  }
}

class _AbsenceCard extends StatelessWidget {
  const _AbsenceCard({required this.absence, required this.onDelete});
  final Absence absence;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          const Icon(Icons.date_range_outlined, color: StageTheme.orange),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _period(absence.from, absence.to),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (absence.reason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(absence.reason),
                  ),
                // Created offline; the server has not confirmed it yet.
                if (absence.id.startsWith('local:'))
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: StatePill(
                      'Wird übertragen',
                      color: StageTheme.orange,
                      icon: Icons.cloud_upload_outlined,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Abwesenheit löschen',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    ),
  );
}

class AddAbsenceScreen extends StatefulWidget {
  const AddAbsenceScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<AddAbsenceScreen> createState() => _AddAbsenceScreenState();
}

class _AddAbsenceScreenState extends State<AddAbsenceScreen> {
  DateTimeRange? _range;
  final _reason = TextEditingController();
  bool _saving = false;
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final range = _range;
    if (range == null) return;
    final controller = widget.controller;
    final declined = affectedEventsForAbsence(
      controller,
      range.start,
      range.end,
    ).length;
    setState(() => _saving = true);
    try {
      final result = await controller.addAbsence(
        range.start,
        range.end,
        _reason.text.trim(),
      );
      if (!mounted) return;
      // The server knows best which events it declined (Berlin dates, events
      // this device has not loaded yet); the preview is the fallback.
      final serverIds = result.data?['declinedEventIds'];
      final ids = jsonList(serverIds).map((e) => '$e').toList();
      final count = serverIds is List ? ids.length : declined;
      final suffix = count == 0 ? '' : ' · ${_events(count)} abgesagt';
      final navigator = Navigator.of(context);
      final shown = [
        for (final event in controller.events)
          if (ids.contains(event.id)) event,
      ];
      showDone(
        context,
        outcomeText(
          result.outcome,
          done: 'Abwesenheit gespeichert$suffix',
          queued:
              'Abwesenheit vorgemerkt$suffix – wird bei Verbindung gesendet',
        ),
        actionLabel: shown.isEmpty ? null : 'Termine ansehen',
        onAction: () => showModalBottomSheet<void>(
          context: navigator.context,
          showDragHandle: true,
          builder: (_) => _DeclinedEventsSheet(events: shown),
        ),
      );
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            'Die Abwesenheit wurde nicht gespeichert: ${userMessage(e)}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final now = widget.controller.now;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Abwesenheit melden')),
      body: ListView(
        padding: pagePadding(context),
        children: [
          Text('Wann fehlst du?', style: theme.textTheme.headlineLarge),
          const SizedBox(height: 10),
          const Text(
            'Termine in diesem Zeitraum werden beim Speichern automatisch abgesagt.',
          ),
          const SizedBox(height: 22),
          OutlinedButton.icon(
            onPressed: _saving
                ? null
                : () async {
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: now.subtract(const Duration(days: 365)),
                      lastDate: now.add(const Duration(days: 730)),
                      initialDateRange: _range,
                    );
                    if (mounted && picked != null) {
                      setState(() => _range = picked);
                    }
                  },
            icon: const Icon(Icons.calendar_month),
            label: Text(
              range == null
                  ? 'Zeitraum auswählen'
                  : _period(range.start, range.end),
            ),
          ),
          if (range != null) ...[
            const SizedBox(height: 12),
            _AffectedEvents(
              events: affectedEventsForAbsence(
                widget.controller,
                range.start,
                range.end,
              ),
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Grund (freiwillig)',
              hintText: 'Zum Beispiel: Urlaub',
            ),
            minLines: 3,
            maxLines: 5,
            maxLength: 500,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: range == null || _saving ? null : _save,
            child: Text(_saving ? 'Wird gespeichert …' : 'Abwesenheit melden'),
          ),
        ],
      ),
    );
  }
}

/// The events the server declined for a newly reported absence.
class _DeclinedEventsSheet extends StatelessWidget {
  const _DeclinedEventsSheet({required this.events});
  final List<TheaterEvent> events;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Abgesagte Termine',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        for (final event in events)
          ListTile(
            leading: const Icon(Icons.event_busy_outlined),
            title: Text(event.title),
            subtitle: Text(eventDate(event)),
          ),
      ],
    ),
  );
}

/// Preview of the events the chosen period declines.
class _AffectedEvents extends StatelessWidget {
  const _AffectedEvents({required this.events});
  final List<TheaterEvent> events;
  static const _shown = 5;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = events.isEmpty
        ? theme.colorScheme.onSurfaceVariant
        : StageTheme.orange;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                events.isEmpty
                    ? Icons.event_available_outlined
                    : Icons.event_busy_outlined,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  events.isEmpty
                      ? 'Damit sagst du keine Termine ab.'
                      : 'Damit sagst du ${_events(events.length)} ab',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          for (final event in events.take(_shown))
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 34),
              child: Text(
                '${event.title} · ${eventDate(event)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (events.length > _shown)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 34),
              child: Text(
                '+ ${events.length - _shown} weitere',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
