import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../data/forms_api.dart';

const _fieldNames = {
  'text': 'Kurzer Text',
  'multiline': 'Langer Text',
  'choice': 'Auswahl',
  'checkbox': 'Bestätigung',
  'date': 'Datum',
};

/// Edits a reusable form. Published messages keep their own frozen copy.
class FormEditorScreen extends StatefulWidget {
  const FormEditorScreen({
    super.key,
    required this.controller,
    this.template,
    this.initialDefinition,
    this.requireDescription = false,
    this.requireDeleteAfter = false,
  }) : assert(template == null || initialDefinition == null);
  final AppController controller;
  final JsonMap? template;

  /// Unsaved starting fields. Unlike [template], this has no server identity.
  final JsonMap? initialDefinition;
  final bool requireDescription;
  final bool requireDeleteAfter;

  @override
  State<FormEditorScreen> createState() => _FormEditorScreenState();
}

class _FormEditorScreenState extends State<FormEditorScreen> {
  final _form = GlobalKey<FormState>();
  JsonMap get _initial =>
      widget.template ?? widget.initialDefinition ?? const {};
  late final _title = TextEditingController(text: textValue(_initial['title']));
  late final _description = TextEditingController(
    text: textValue(_initial['description']),
  );
  late final _confirmation = TextEditingController(
    text: textValue(
      _initial['confirmationText'],
      'Ich bestätige die Angaben in diesem Formular.',
    ),
  );
  late final List<JsonMap> _fields = [
    for (final field in jsonList(_initial['fields'])) cloneJson(jsonMap(field)),
  ];
  late bool _signature = _initial['signatureRequired'] == true;
  late String? _deleteAfter = textValue(_initial['deleteAfter']).isEmpty
      ? null
      : textValue(_initial['deleteAfter']);
  late bool _dirty = widget.initialDefinition != null;
  bool _busy = false, _fieldError = false;
  bool _sessionEnded = false;
  late final String? _owner;
  String? _saveKey, _saveBody;
  int _fieldSequence = 0;

  @override
  void initState() {
    super.initState();
    _owner = widget.controller.user?.id;
    widget.controller.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (_sessionEnded ||
        (widget.controller.user?.id == _owner &&
            widget.controller.hasAccess &&
            widget.controller.user?.isAdmin == true)) {
      return;
    }
    setState(() {
      _sessionEnded = true;
      _dirty = false;
      _fields.clear();
      _title.clear();
      _description.clear();
      _confirmation.clear();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sessionChanged);
    _title.dispose();
    _description.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _changed() => setState(() => _dirty = true);

  Future<void> _editField([int? index]) async {
    final value = await showDialog<JsonMap>(
      context: context,
      builder: (_) => _FieldEditor(
        field: index == null ? null : _fields[index],
        newId:
            'field_${DateTime.now().microsecondsSinceEpoch}_${_fieldSequence++}',
      ),
    );
    if (value == null || !mounted || _sessionEnded) return;
    setState(() {
      if (index == null) {
        _fields.add(value);
      } else {
        _fields[index] = value;
      }
      _fieldError = false;
      _dirty = true;
    });
  }

  void _move(int from, int to) => setState(() {
    _fields.insert(to, _fields.removeAt(from));
    _dirty = true;
  });

  Future<void> _chooseDeletionDate() async {
    final now = widget.controller.now;
    final first = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    final last = first.add(const Duration(days: 364));
    final existing = DateTime.tryParse(_deleteAfter ?? '');
    final initial = existing == null || existing.isBefore(first)
        ? first
        : existing.isAfter(last)
        ? last
        : existing;
    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: 'Antworten löschen am',
    );
    if (selected == null || !mounted || _sessionEnded) return;
    setState(() {
      _deleteAfter =
          '${selected.year.toString().padLeft(4, '0')}-'
          '${selected.month.toString().padLeft(2, '0')}-'
          '${selected.day.toString().padLeft(2, '0')}';
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final valid = _form.currentState?.validate() == true;
    setState(() => _fieldError = _fields.isEmpty);
    // ListView may have disposed fields above the viewport. Validate the
    // required controllers as well as the currently mounted FormFields.
    if (_title.text.trim().isEmpty || _confirmation.text.trim().isEmpty) {
      showProblem(
        context,
        _title.text.trim().isEmpty
            ? 'Bitte einen Formularnamen angeben.'
            : 'Bitte den Bestätigungstext angeben.',
      );
      return;
    }
    if (widget.requireDescription && _description.text.trim().isEmpty) {
      showProblem(
        context,
        'Bitte Datum, Ort und Teilnahmebedingungen ergänzen.',
      );
      return;
    }
    if (widget.requireDeleteAfter && _deleteAfter == null) {
      showProblem(
        context,
        'Bitte einen Termin zum Löschen der Antworten wählen.',
      );
      return;
    }
    if (!valid || _fieldError) return;
    setState(() => _busy = true);
    try {
      final body = <String, dynamic>{
        if (widget.template != null) ...{
          'id': widget.template!['id'],
          'version': widget.template!['version'],
        },
        'title': _title.text.trim(),
        'description': _description.text.trim(),
        'fields': _fields,
        'signatureRequired': _signature,
        'confirmationText': _confirmation.text.trim(),
        'deleteAfter': _deleteAfter,
      };
      final encoded = jsonEncode(body);
      if (_saveBody != encoded) {
        _saveBody = encoded;
        final random = Random.secure();
        _saveKey = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
      }
      final saved = await FormsApi(
        widget.controller,
      ).save(body, idempotencyKey: _saveKey);
      if (!mounted || _sessionEnded) return;
      setState(() => _dirty = false);
      showDone(context, 'Formular gespeichert.');
      Navigator.pop(context, saved);
    } catch (error) {
      if (mounted) showProblem(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _sessionEnded
      ? Scaffold(
          appBar: AppBar(title: const Text('Formular')),
          body: const Center(child: Text('Bitte das Formular erneut öffnen.')),
        )
      : DiscardGuard(
          dirty: _dirty && !_busy,
          child: Form(
            key: _form,
            child: AdminPage(
              controller: widget.controller,
              title: widget.template == null
                  ? 'Formular erstellen'
                  : 'Formular bearbeiten',
              children: (context) => [
                if (widget.template != null) ...[
                  const Text(
                    'Änderungen gelten für künftige Mitteilungen. Bereits verschickte Formulare und abgegebene Antworten bleiben erhalten.',
                  ),
                  const SizedBox(height: 18),
                ],
                if (widget.initialDefinition != null) ...[
                  const Text(
                    'Diese Startvorlage ist frei bearbeitbar. Prüfe die Fragen und ergänze Datum, Ort und Teilnahmebedingungen für eure Probenfreizeit, bevor du das Formular verwendest.',
                  ),
                  const SizedBox(height: 18),
                ],
                TextFormField(
                  controller: _title,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Formularname'),
                  maxLength: 160,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => _changed(),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Bitte einen Formularnamen angeben.'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: widget.requireDescription
                        ? 'Datum, Ort und Teilnahmebedingungen'
                        : 'Beschreibung (optional)',
                    hintText: widget.requireDescription
                        ? 'Trage hier die Angaben zu eurer Probenfreizeit ein.'
                        : 'Worum geht es, und was sollen die Mitglieder wissen?',
                    alignLabelWithHint: true,
                  ),
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 10000,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => _changed(),
                  validator: (value) =>
                      widget.requireDescription &&
                          (value == null || value.trim().isEmpty)
                      ? 'Bitte Datum, Ort und Teilnahmebedingungen ergänzen.'
                      : null,
                ),
                const SectionTitle('Felder'),
                if (_fields.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Füge die Fragen hinzu, die deine Mitglieder beantworten sollen.',
                    ),
                  ),
                for (var i = 0; i < _fields.length; i++) _fieldCard(i),
                OutlinedButton.icon(
                  onPressed: _busy || _fields.length >= 40
                      ? null
                      : () => _editField(),
                  icon: const Icon(Icons.add),
                  label: const Text('Feld hinzufügen'),
                ),
                if (_fieldError)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Bitte mindestens ein Feld hinzufügen.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SectionTitle('Abgabe'),
                TextFormField(
                  controller: _confirmation,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Bestätigung bei der Abgabe',
                    helperText:
                        'Dieser Text wird vor dem Absenden ausdrücklich bestätigt.',
                    helperMaxLines: 3,
                    alignLabelWithHint: true,
                  ),
                  minLines: 2,
                  maxLines: 6,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => _changed(),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Bitte den Bestätigungstext angeben.'
                      : null,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _signature,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _signature = value;
                          _dirty = true;
                        }),
                  title: const Text('Unterschrift erforderlich'),
                  subtitle: const Text(
                    'Mitglieder geben ihren Namen an und unterschreiben mit Finger oder Maus.',
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_busy_outlined),
                  title: const Text('Antworten löschen am'),
                  subtitle: Text(
                    _deleteAfter == null
                        ? widget.requireDeleteAfter
                              ? 'Bitte ein Datum wählen'
                              : 'Kein früheres Löschdatum gewählt'
                        : _deleteAfter!.split('-').reversed.join('.'),
                  ),
                  onTap: _busy ? null : _chooseDeletionDate,
                  trailing: _deleteAfter == null
                      ? const Icon(Icons.chevron_right)
                      : IconButton(
                          tooltip: 'Löschdatum entfernen',
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _deleteAfter = null;
                                  _dirty = true;
                                }),
                          icon: const Icon(Icons.close),
                        ),
                ),
                Text(
                  'Wähle einen Termin kurz nach der Veranstaltung. Spätestens nach einem Jahr werden Antworten automatisch gelöscht.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Formular speichern'),
                ),
              ],
            ),
          ),
        );

  Widget _fieldCard(int index) {
    final field = _fields[index];
    final type = textValue(field['type']);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${index + 1}. ${textValue(field['label'])}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '${_fieldNames[type] ?? type}${field['required'] == true ? ' · Pflichtfeld' : ' · Optional'}',
            ),
            if (type == 'choice') Text(jsonList(field['options']).join(' / ')),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Feld nach oben',
                  onPressed: _busy || index == 0
                      ? null
                      : () => _move(index, index - 1),
                  icon: const Icon(Icons.arrow_upward, size: 20),
                ),
                IconButton(
                  tooltip: 'Feld nach unten',
                  onPressed: _busy || index == _fields.length - 1
                      ? null
                      : () => _move(index, index + 1),
                  icon: const Icon(Icons.arrow_downward, size: 20),
                ),
                IconButton(
                  tooltip: 'Feld bearbeiten',
                  onPressed: _busy ? null : () => _editField(index),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                IconButton(
                  tooltip: 'Feld entfernen',
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _fields.removeAt(index);
                          _dirty = true;
                        }),
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldEditor extends StatefulWidget {
  const _FieldEditor({this.field, required this.newId});
  final JsonMap? field;
  final String newId;

  @override
  State<_FieldEditor> createState() => _FieldEditorState();
}

class _FieldEditorState extends State<_FieldEditor> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(
    text: textValue(widget.field?['label']),
  );
  late final _options = TextEditingController(
    text: jsonList(widget.field?['options']).join('\n'),
  );
  late String _type = textValue(widget.field?['type'], 'text');
  late bool _required = widget.field?['required'] != false;

  List<String> get _choices => _options.text
      .split('\n')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  @override
  void dispose() {
    _label.dispose();
    _options.dispose();
    super.dispose();
  }

  void _save() {
    if (_form.currentState?.validate() != true) return;
    Navigator.pop(context, <String, dynamic>{
      'id': widget.field?['id'] ?? widget.newId,
      'type': _type,
      'label': _label.text.trim(),
      'required': _required,
      if (_type == 'choice') 'options': _choices,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.field == null ? 'Feld hinzufügen' : 'Feld bearbeiten'),
    content: SizedBox(
      width: 460,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Feldtyp'),
                items: [
                  for (final type in _fieldNames.entries)
                    DropdownMenuItem(value: type.key, child: Text(type.value)),
                ],
                onChanged: (value) => setState(() => _type = value ?? 'text'),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'Frage oder Beschriftung',
                ),
                textCapitalization: TextCapitalization.sentences,
                maxLength: _type == 'checkbox' ? 2000 : 200,
                minLines: 1,
                maxLines: 3,
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Bitte eine Beschriftung angeben.'
                    : null,
              ),
              if (_type == 'choice') ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _options,
                  decoration: const InputDecoration(
                    labelText: 'Antwortmöglichkeiten',
                    helperText: 'Eine Antwort pro Zeile, mindestens zwei.',
                    alignLabelWithHint: true,
                  ),
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 8040,
                  validator: (_) {
                    final values = _choices;
                    if (values.length < 2 || values.length > 40) {
                      return 'Bitte 2 bis 40 Antworten angeben.';
                    }
                    if (values.any((value) => value.length > 200)) {
                      return 'Eine Antwort darf höchstens 200 Zeichen haben.';
                    }
                    if (values.toSet().length != values.length) {
                      return 'Bitte jede Antwort nur einmal angeben.';
                    }
                    return null;
                  },
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pflichtfeld'),
                subtitle: _type == 'checkbox'
                    ? const Text(
                        'Das Häkchen muss für die Abgabe gesetzt sein.',
                      )
                    : null,
                value: _required,
                onChanged: (value) => setState(() => _required = value),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(onPressed: _save, child: const Text('Übernehmen')),
    ],
  );
}
