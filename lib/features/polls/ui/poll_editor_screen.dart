import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/audience/audience_pickers.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';

class PollEditorScreen extends StatefulWidget {
  const PollEditorScreen({super.key, required this.controller, this.poll});
  final AppController controller;
  final Poll? poll;
  @override
  State<PollEditorScreen> createState() => _PollEditorScreenState();
}

class _PollEditorScreenState extends State<PollEditorScreen> {
  late final TextEditingController _title, _description;
  late final List<TextEditingController> _options;
  DateTime? _closes;
  late bool _anonymous;
  late Set<String> _roleIds;
  late Set<int> _personIds;
  late Set<String> _productionIds;
  bool _busy = false;
  final _form = GlobalKey<FormState>();
  bool get _fixed => (widget.poll?.totalVotes ?? 0) > 0;
  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.poll?.title);
    _description = TextEditingController(text: widget.poll?.description);
    _options =
        widget.poll?.options
            .map((o) => TextEditingController(text: o.label))
            .toList() ??
        [TextEditingController(), TextEditingController()];
    _closes = widget.poll?.closesAt?.toLocal();
    _anonymous = widget.poll?.anonymous ?? true;
    _roleIds = {...?widget.poll?.roleIds};
    _personIds = {...?widget.poll?.personIds};
    _productionIds = {...?widget.poll?.productionIds};
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_closes != null &&
        !_closes!.isAfter(DateTime.now()) &&
        widget.poll?.closesAt?.isAtSameMomentAs(_closes!) != true) {
      showProblem(
        context,
        'Enddatum und Uhrzeit müssen in der Zukunft liegen.',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'poll.save',
        'id': widget.poll?.id,
        'version': widget.poll?.version,
        'title': _title.text,
        'description': _description.text,
        'anonymous': _anonymous,
        'roleIds': _roleIds.toList(),
        'personIds': _personIds.toList(),
        'productionIds': _productionIds.toList(),
        'options': _options.map((o) => {'label': o.text}).toList(),
        'closesAt': _closes?.toUtc().toIso8601String(),
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: widget.poll == null
        ? 'Abstimmung erstellen'
        : 'Abstimmung bearbeiten',
    children: (context) => [
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _title,
              maxLength: 250,
              decoration: const InputDecoration(labelText: 'Frage'),
              validator: (v) => v == null || v.trim().isEmpty
                  ? 'Bitte eine Frage eingeben.'
                  : null,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 6,
              maxLength: 3000,
              decoration: const InputDecoration(labelText: 'Beschreibung'),
            ),
            const SizedBox(height: 8),
            AudiencePicker(
              controller: widget.controller,
              label: 'Wer darf abstimmen?',
              allowEveryone: _personIds.isEmpty && _productionIds.isEmpty,
              selected: _roleIds,
              onChanged: (value) => setState(() => _roleIds = value),
            ),
            const SizedBox(height: 16),
            ProductionAudiencePicker(
              controller: widget.controller,
              selected: _productionIds,
              onChanged: (value) => setState(() => _productionIds = value),
            ),
            const SizedBox(height: 16),
            PersonPicker(
              controller: widget.controller,
              selected: _personIds,
              onChanged: (value) => setState(() => _personIds = value),
            ),
            const SizedBox(height: 8),
            Text(
              'Abstimmen dürfen: ${widget.controller.audienceLabel(_roleIds, _personIds, _productionIds)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SectionTitle('Abstimmungsart'),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Anonym'),
                  icon: Icon(Icons.visibility_off_outlined),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Namentlich'),
                  icon: Icon(Icons.people_outline),
                ),
              ],
              selected: {_anonymous},
              onSelectionChanged: _fixed || _busy
                  ? null
                  : (selection) =>
                        setState(() => _anonymous = selection.single),
            ),
            const SizedBox(height: 10),
            Text(
              _anonymous
                  ? 'Nur die Stimmenzahlen werden angezeigt.'
                  : 'Alle Mitglieder sehen die Namen bei der gewählten Antwort.',
            ),
            if (_fixed) ...[
              const SizedBox(height: 8),
              const Text(
                'Die Abstimmungsart bleibt nach der ersten Stimme erhalten.',
              ),
            ],
            const SectionTitle('Antworten'),
            for (var i = 0; i < _options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _options[i],
                        enabled: !_fixed && !_busy,
                        maxLength: 200,
                        decoration: InputDecoration(
                          labelText: 'Antwort ${i + 1}',
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Bitte eine Antwort eingeben.'
                            : null,
                      ),
                    ),
                    if (!_fixed && _options.length > 2)
                      IconButton(
                        tooltip: 'Antwort entfernen',
                        onPressed: _busy
                            ? null
                            : () {
                                final removed = _options[i];
                                setState(() => _options.removeAt(i));
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => removed.dispose(),
                                );
                              },
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
              ),
            if (!_fixed && _options.length < 12)
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () =>
                          setState(() => _options.add(TextEditingController())),
                icon: const Icon(Icons.add),
                label: const Text('Antwort hinzufügen'),
              ),
            if (_fixed)
              const Text(
                'Die Antworten bleiben nach der ersten Stimme erhalten.',
              ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enddatum festlegen'),
              value: _closes != null,
              onChanged: _busy
                  ? null
                  : (enabled) {
                      final now = DateTime.now();
                      setState(
                        () => _closes = enabled
                            ? DateTime(now.year, now.month, now.day + 7, 20)
                            : null,
                      );
                    },
            ),
            if (_closes != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enddatum und Uhrzeit'),
                subtitle: Text(
                  _closes == null
                      ? 'Ohne Frist'
                      : DateFormat(
                          'd. MMMM yyyy · HH:mm',
                          'de',
                        ).format(_closes!),
                ),
                trailing: _closes == null
                    ? const Icon(Icons.calendar_month)
                    : IconButton(
                        tooltip: 'Frist entfernen',
                        onPressed: () => setState(() => _closes = null),
                        icon: const Icon(Icons.close),
                      ),
                onTap: _busy
                    ? null
                    : () async {
                        final now = DateTime.now();
                        final day = await showDatePicker(
                          context: context,
                          initialDate: _closes?.isAfter(now) == true
                              ? _closes!
                              : now.add(const Duration(days: 7)),
                          firstDate: now,
                          lastDate: DateTime(2100),
                        );
                        if (day == null || !context.mounted) return;
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay.fromDateTime(
                            _closes ?? DateTime(2026, 1, 1, 20),
                          ),
                        );
                        if (time != null && mounted) {
                          setState(
                            () => _closes = DateTime(
                              day.year,
                              day.month,
                              day.day,
                              time.hour,
                              time.minute,
                            ),
                          );
                        }
                      },
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Wird gespeichert …' : 'Speichern'),
            ),
          ],
        ),
      ),
    ],
  );
}
