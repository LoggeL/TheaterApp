import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';

class AbsencesScreen extends StatelessWidget {
  const AbsencesScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Abwesenheiten')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            openPage(context, AddAbsenceScreen(controller: controller)),
        icon: const Icon(Icons.add),
        label: const Text('Zeitraum melden'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 100),
        children: [
          Text(
            'Mal nicht da?',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 10),
          const Text(
            'Sag dem Ensemble Bescheid, wenn du länger fehlst. Passende bestehende Proben werden beim Speichern automatisch abgesagt.',
          ),
          const SizedBox(height: 24),
          if (controller.absences.isEmpty)
            const EmptyState(
              icon: Icons.beach_access_outlined,
              title: 'Keine Abwesenheiten',
              message:
                  'Urlaub, Arbeit oder eine Pause: Melde hier deinen Zeitraum.',
            ),
          ...controller.absences.map(
            (absence) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.date_range_outlined,
                        color: StageTheme.orange,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${DateFormat('dd.MM.yyyy').format(absence.from)} – ${DateFormat('dd.MM.yyyy').format(absence.to)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (absence.reason.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 7),
                                child: Text(absence.reason),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Abwesenheit löschen',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Abwesenheit entfernen?'),
                              content: const Text(
                                'Bereits gespeicherte Absagen bleiben bestehen. Ändere sie bei Bedarf im jeweiligen Termin.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Abbrechen'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Entfernen'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true && context.mounted) {
                            await runAction(
                              context,
                              () => controller.deleteAbsence(absence.id),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
    if (_range == null) return;
    setState(() => _saving = true);
    try {
      await widget.controller.addAbsence(
        _range!.start,
        _range!.end,
        _reason.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Abwesenheit melden')),
    body: ListView(
      padding: pagePadding(context),
      children: [
        Text(
          'Wann fehlst du?',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 22),
        OutlinedButton.icon(
          onPressed: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime.now().subtract(const Duration(days: 365)),
              lastDate: DateTime.now().add(const Duration(days: 730)),
              initialDateRange: _range,
            );
            if (mounted && picked != null) setState(() => _range = picked);
          },
          icon: const Icon(Icons.calendar_month),
          label: Text(
            _range == null
                ? 'Zeitraum auswählen'
                : '${DateFormat('dd.MM.yyyy').format(_range!.start)} – ${DateFormat('dd.MM.yyyy').format(_range!.end)}',
          ),
        ),
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
          onPressed: _range == null || _saving ? null : _save,
          child: Text(_saving ? 'Wird gespeichert …' : 'Abwesenheit melden'),
        ),
      ],
    ),
  );
}
