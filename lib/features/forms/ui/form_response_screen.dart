import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../data/form_pdf_exporter.dart';
import '../data/forms_api.dart';
import 'widgets/signature_pad.dart';

class FormResponseScreen extends StatefulWidget {
  const FormResponseScreen({
    super.key,
    required this.controller,
    required this.messageId,
  });
  final AppController controller;
  final String messageId;

  @override
  State<FormResponseScreen> createState() => _FormResponseScreenState();
}

class _FormResponseScreenState extends State<FormResponseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _signature = SignatureController();
  final _signer = TextEditingController();
  final JsonMap _answers = {};
  late final String? _account;
  JsonMap? _form, _submission;
  bool _loading = true, _busy = false, _confirmed = false;
  bool _addressed = false, _accepted = false, _sessionEnded = false;
  bool _closed = false;
  bool _attempted = false;
  int _submissionGeneration = 0;
  String? _error, _lastPayload, _attemptKey;
  String? _withdrawKey;

  FormsApi get _api => FormsApi(widget.controller);
  bool get _sameAccount =>
      !_sessionEnded &&
      widget.controller.hasAccess &&
      widget.controller.user?.id == _account;
  bool get _dirty =>
      !_accepted &&
      _submission == null &&
      (_answers.values.any((value) => value != '' && value != false) ||
          _confirmed ||
          _signer.text.isNotEmpty ||
          !_signature.isEmpty);

  @override
  void initState() {
    super.initState();
    _account = widget.controller.user?.id;
    widget.controller.addListener(_sessionChanged);
    _signature.addListener(_changed);
    _load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _sessionChanged() {
    if (!_sameAccount && !_sessionEnded) {
      _sessionEnded = true;
      _form = null;
      _submission = null;
      _answers.clear();
      _signer.clear();
      _signature.clear();
      _lastPayload = null;
      _attemptKey = null;
      _withdrawKey = null;
      _confirmed = false;
      _submissionGeneration = 0;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sessionChanged);
    _signature.removeListener(_changed);
    _signature.dispose();
    _signer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_sameAccount) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _api.message(widget.messageId);
      if (!mounted || !_sameAccount) return;
      setState(() {
        _form = jsonMap(data['form']);
        _submission = data['mySubmission'] is Map
            ? jsonMap(data['mySubmission'])
            : null;
        _addressed = data['addressedToMe'] == true;
        _submissionGeneration = intValue(data['submissionGeneration']);
        _closed = data['closed'] == true;
        if (_closed) {
          _accepted = false;
          _answers.clear();
          _signer.clear();
          _signature.clear();
          _confirmed = false;
          _attemptKey = null;
          _lastPayload = null;
        }
        if (_submission != null) {
          _accepted = true;
          _answers.clear();
          _signer.clear();
          _signature.clear();
          _lastPayload = null;
        }
      });
    } catch (error) {
      if (mounted && _sameAccount) setState(() => _error = userMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    setState(() => _attempted = true);
    final valid = _formKey.currentState?.validate() == true;
    if (!valid ||
        !_confirmed ||
        (_form?['signatureRequired'] == true && !_signature.isValid)) {
      return;
    }
    if (!_sameAccount || !_addressed || _closed || _busy || _accepted) return;
    final payload = <String, dynamic>{
      'messageId': widget.messageId,
      'formVersion': _form!['version'],
      'submissionGeneration': _submissionGeneration,
      'answers': Map<String, dynamic>.of(_answers),
      'confirmed': true,
      'signerName': _signer.text.trim(),
      'signature': _signature.toJson,
    };
    final encoded = jsonEncode(payload);
    if (_lastPayload != encoded) {
      _lastPayload = encoded;
      _attemptKey =
          'form-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _api.submit(payload, idempotencyKey: _attemptKey!);
      if (!mounted || !_sameAccount) return;
      if (result['ok'] != true) {
        throw 'Die Abgabe wurde vom Server nicht bestätigt. Bitte erneut versuchen.';
      }
      setState(() => _accepted = true);
      await _load();
      if (mounted && _sameAccount) {
        showDone(context, 'Formular abgegeben.');
        // The receipt came directly from the server. A failed snapshot refresh
        // does not change the confirmed submission or persist its private data.
        widget.controller.refresh().catchError((Object _) {});
      }
    } catch (error) {
      if (mounted && _sameAccount) setState(() => _error = userMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_form == null || !_sameAccount) return;
    setState(() => _busy = true);
    try {
      await exportFormPdf(
        form: _form!,
        submission: _submission,
        answers: _answers,
        signerName: _signer.text.trim(),
        signature: _signature.toJson,
      );
    } catch (error) {
      if (mounted && _sameAccount) showProblem(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw() async {
    if (!_sameAccount || _submission == null || _busy) return;
    final confirmed = await confirmDestructive(
      context,
      title: 'Abgabe löschen?',
      message:
          'Deine Antworten und deine Unterschrift werden gelöscht. Bereits exportierte PDF-Kopien bleiben erhalten.',
      confirmLabel: 'Abgabe löschen',
    );
    if (!confirmed || !mounted || !_sameAccount || _submission == null) return;
    _withdrawKey ??=
        'withdraw-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.withdraw(_submission!, idempotencyKey: _withdrawKey!);
      if (!mounted || !_sameAccount) return;
      setState(() {
        _submission = null;
        _accepted = false;
        _form = null;
        _answers.clear();
        _signature.clear();
        _signer.clear();
        _confirmed = false;
        _attempted = false;
        _attemptKey = null;
        _lastPayload = null;
        _withdrawKey = null;
      });
      showDone(context, 'Abgabe gelöscht.');
      await _load();
      widget.controller.refresh().catchError((Object _) {});
    } catch (error) {
      if (mounted && _sameAccount) setState(() => _error = userMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DiscardGuard(
    dirty: _sameAccount && _dirty,
    child: Scaffold(
      appBar: AppBar(title: const Text('Formular')),
      body: !_sameAccount
          ? const Center(
              child: Text('Bitte das Formular mit deinem Konto erneut öffnen.'),
            )
          : _loading && _form == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: pagePadding(context),
              children: [
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_form == null)
                  OutlinedButton(
                    onPressed: _load,
                    child: const Text('Erneut laden'),
                  )
                else if (_submission != null) ...[
                  FormReceipt(submission: _submission!),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('PDF exportieren'),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _withdraw,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Abgabe löschen'),
                  ),
                ] else if (_accepted) ...[
                  const Text('Dein Formular wurde abgegeben.'),
                  const SizedBox(height: 8),
                  const Text(
                    'Lade den Beleg, um deine gespeicherten Angaben zu sehen oder als PDF zu exportieren.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _loading ? null : _load,
                    child: const Text('Beleg laden'),
                  ),
                ] else
                  ..._input(context),
              ],
            ),
    ),
  );

  List<Widget> _input(BuildContext context) => [
    Text(
      textValue(_form!['title']),
      style: Theme.of(context).textTheme.headlineSmall,
    ),
    if (textValue(_form!['description']).isNotEmpty) ...[
      const SizedBox(height: 12),
      Text(textValue(_form!['description'])),
    ],
    const SizedBox(height: 16),
    if (textValue(_form!['deleteAfter']).isNotEmpty) ...[
      Text(formDeletionNotice(_form!)),
      const SizedBox(height: 12),
    ],
    Text(
      _closed
          ? 'Dieses Formular ist geschlossen. Die Aufbewahrungsfrist ist abgelaufen.'
          : _addressed
          ? 'Deine Abgabe sehen nur du und die Admins. Pflichtfelder sind mit * markiert.'
          : 'Dieses Formular ist an andere Personen gerichtet. Du kannst es ansehen und als PDF exportieren.',
    ),
    const SizedBox(height: 20),
    if (_closed)
      OutlinedButton.icon(
        onPressed: _busy ? null : _export,
        icon: const Icon(Icons.picture_as_pdf_outlined),
        label: const Text('PDF exportieren'),
      )
    else
      Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final field in jsonList(_form!['fields']).map(jsonMap)) ...[
              _field(field),
              const SizedBox(height: 20),
            ],
            if (_form!['signatureRequired'] == true) ...[
              _labeledField(
                'Name der unterschreibenden Person *',
                TextFormField(
                  key: const ValueKey('form-signer-name'),
                  controller: _signer,
                  enabled: _addressed && !_busy,
                  decoration: const InputDecoration(
                    hintText: 'Vor- und Nachname',
                  ),
                  maxLength: 120,
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Bitte deinen Namen eintragen.'
                      : null,
                  onChanged: (_) => _changed(),
                ),
              ),
              const SizedBox(height: 12),
              SignaturePad(
                controller: _signature,
                enabled: _addressed && !_busy,
              ),
              if (_attempted && !_signature.isValid)
                Text(
                  'Bitte im Feld unterschreiben.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 16),
            ],
            if (_addressed) ...[
              CheckboxListTile(
                key: const ValueKey('form-confirmation'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(textValue(_form!['confirmationText'])),
                value: _confirmed,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _confirmed = value == true),
              ),
              if (_attempted && !_confirmed)
                Text(
                  'Bitte die Bestätigung ankreuzen.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 8),
              const Text(
                'Für eine Korrektur kannst du die Abgabe löschen und das offene Formular erneut ausfüllen.',
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const ValueKey('form-submit'),
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: const Text('Formular abgeben'),
              ),
              if (widget.controller.isOffline)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Zum Abgeben brauchst du eine Internetverbindung. Deine Eingaben bleiben auf dieser Seite erhalten.',
                  ),
                ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _export,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('PDF exportieren'),
            ),
            const Text('Der PDF-Export gibt das Formular nicht ab.'),
          ],
        ),
      ),
  ];

  Widget _field(JsonMap field) {
    final id = textValue(field['id']);
    final required = field['required'] == true;
    final label = '${textValue(field['label'])}${required ? ' *' : ''}';
    final enabled = _addressed && !_busy;
    switch (field['type']) {
      case 'checkbox':
        return FormField<bool>(
          key: ValueKey('form-field-$id'),
          initialValue: _answers[id] == true,
          validator: (value) =>
              required && value != true ? 'Bitte bestätigen.' : null,
          builder: (state) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(label),
                value: _answers[id] == true,
                onChanged: enabled
                    ? (value) {
                        state.didChange(value == true);
                        setState(() => _answers[id] = value == true);
                      }
                    : null,
              ),
              if (state.hasError)
                Text(
                  state.errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        );
      case 'choice':
        return _labeledField(
          label,
          DropdownButtonFormField<String>(
            key: ValueKey('form-field-$id'),
            decoration: const InputDecoration(),
            isExpanded: true,
            itemHeight: null,
            menuMaxHeight: 360,
            initialValue: _answers[id] as String?,
            items: [
              const DropdownMenuItem(value: '', child: Text('Bitte wählen')),
              for (final option in jsonList(field['options']))
                DropdownMenuItem(
                  value: option.toString(),
                  child: Text(option.toString()),
                ),
            ],
            selectedItemBuilder: (context) => [
              const Text(
                'Bitte wählen',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              for (final option in jsonList(field['options']))
                Text(
                  option.toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
            onChanged: enabled
                ? (value) => setState(() => _answers[id] = value ?? '')
                : null,
            validator: (value) => required && (value ?? '').isEmpty
                ? 'Bitte eine Auswahl treffen.'
                : null,
          ),
        );
      case 'date':
        return _labeledField(
          label,
          FormField<String>(
            key: ValueKey('form-field-$id'),
            initialValue: textValue(_answers[id]),
            validator: (value) => required && (value ?? '').isEmpty
                ? 'Bitte ein Datum wählen.'
                : null,
            builder: (state) => InkWell(
              onTap: !enabled
                  ? null
                  : () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate:
                            DateTime.tryParse(textValue(_answers[id])) ??
                            DateTime.now(),
                        firstDate: DateTime(1900),
                        lastDate: DateTime(2100, 12, 31),
                      );
                      if (picked == null || !mounted || !_sameAccount) return;
                      final value = DateFormat('yyyy-MM-dd').format(picked);
                      state.didChange(value);
                      setState(() => _answers[id] = value);
                    },
              child: InputDecorator(
                decoration: InputDecoration(
                  enabled: enabled,
                  errorText: state.errorText,
                  suffixIcon: textValue(_answers[id]).isEmpty
                      ? const Icon(Icons.calendar_today_outlined)
                      : IconButton(
                          tooltip: 'Datum löschen',
                          onPressed: !enabled
                              ? null
                              : () {
                                  state.didChange('');
                                  setState(() => _answers[id] = '');
                                },
                          icon: const Icon(Icons.clear),
                        ),
                ),
                child: Text(formAnswerText(field, _answers[id])),
              ),
            ),
          ),
        );
      default:
        return _labeledField(
          label,
          TextFormField(
            key: ValueKey('form-field-$id'),
            initialValue: textValue(_answers[id]),
            enabled: enabled,
            decoration: const InputDecoration(),
            maxLines: field['type'] == 'multiline' ? 5 : 1,
            minLines: field['type'] == 'multiline' ? 3 : 1,
            maxLength: field['type'] == 'multiline' ? 10000 : 1000,
            validator: (value) => required && (value ?? '').trim().isEmpty
                ? 'Bitte ausfüllen.'
                : null,
            onChanged: (value) => setState(() => _answers[id] = value),
          ),
        );
    }
  }

  /// Questions remain fully visible on phones, including long consent-related
  /// prompts. The input's semantics keep the whole question as its label.
  Widget _labeledField(String label, Widget input) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Semantics(label: label, child: input),
    ],
  );
}

String formAnswerText(JsonMap field, Object? value) {
  if (field['type'] == 'checkbox') return value == true ? 'Ja' : 'Nein';
  final text = textValue(value);
  if (text.isEmpty) return 'Keine Angabe';
  if (field['type'] == 'date') {
    final date = DateTime.tryParse(text);
    if (date != null) return DateFormat('dd.MM.yyyy').format(date);
  }
  return text;
}

String formDeletionNotice(JsonMap form) {
  final raw = textValue(form['deleteAfter']);
  final date = DateTime.tryParse(raw);
  return 'Antworten werden am ${date == null ? raw : DateFormat('dd.MM.yyyy').format(date)} gelöscht.';
}

/// Only renders the server's immutable receipt, never the current template.
class FormReceipt extends StatelessWidget {
  const FormReceipt({super.key, required this.submission});
  final JsonMap submission;

  @override
  Widget build(BuildContext context) {
    final form = jsonMap(submission['form']);
    final answers = jsonMap(submission['answers']);
    final signature = jsonMap(submission['signature']);
    final submittedAt = DateTime.tryParse(textValue(submission['submittedAt']));
    final date = submittedAt == null
        ? textValue(submission['submittedAt'])
        : DateFormat('dd.MM.yyyy, HH:mm').format(submittedAt.toLocal());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          textValue(form['title']),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        const Chip(
          avatar: Icon(Icons.check_circle_outline, size: 18),
          label: Text('Abgegeben'),
        ),
        Text('${textValue(submission['personName'])} · $date'),
        if (textValue(form['deleteAfter']).isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(formDeletionNotice(form)),
        ],
        const SizedBox(height: 20),
        if (textValue(form['description']).isNotEmpty) ...[
          Text(textValue(form['description'])),
          const SizedBox(height: 20),
        ],
        for (final field in jsonList(form['fields']).map(jsonMap)) ...[
          Text(
            textValue(field['label']),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          SelectableText(
            formAnswerText(field, answers[textValue(field['id'])]),
          ),
          const SizedBox(height: 18),
        ],
        Text(
          textValue(submission['confirmationText'] ?? form['confirmationText']),
        ),
        if (textValue(submission['signerName']).isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Unterschrieben von ${textValue(submission['signerName'])}'),
        ],
        if (jsonList(signature['strokes']).isNotEmpty) ...[
          const SizedBox(height: 8),
          SignaturePreview(signature: signature),
        ],
        const SizedBox(height: 16),
        Text(
          'Formularstand ${intValue(form['version'])} · Beleg ${textValue(submission['receiptId'] ?? submission['id'])}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
