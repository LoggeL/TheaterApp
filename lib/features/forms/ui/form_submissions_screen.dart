import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../data/form_pdf_exporter.dart';
import '../data/forms_api.dart';
import 'form_response_screen.dart';

class FormSubmissionsScreen extends StatefulWidget {
  const FormSubmissionsScreen({
    super.key,
    required this.controller,
    required this.messageId,
  });
  final AppController controller;
  final String messageId;

  @override
  State<FormSubmissionsScreen> createState() => _FormSubmissionsScreenState();
}

class _FormSubmissionsScreenState extends State<FormSubmissionsScreen> {
  late final String? _account;
  List<JsonMap> _submissions = [];
  bool _loading = true, _sessionEnded = false;
  String? _error;
  bool get _allowed =>
      !_sessionEnded &&
      widget.controller.hasAccess &&
      widget.controller.user?.isAdmin == true &&
      widget.controller.user?.id == _account;

  @override
  void initState() {
    super.initState();
    _account = widget.controller.user?.id;
    widget.controller.addListener(_sessionChanged);
    _load();
  }

  void _sessionChanged() {
    if (!_allowed) {
      _sessionEnded = true;
      _submissions = [];
      _error = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sessionChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!_allowed) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final submissions = await FormsApi(
        widget.controller,
      ).submissions(widget.messageId);
      if (mounted && _allowed) {
        setState(() => _submissions = submissions);
      }
    } catch (error) {
      if (mounted && _allowed) setState(() => _error = userMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Abgegebene Formulare',
    onRefresh: _load,
    children: (context) => [
      if (!_allowed)
        const Text('Bitte die Übersicht mit deinem Konto erneut öffnen.')
      else if (_loading && _submissions.isEmpty)
        const Center(child: CircularProgressIndicator())
      else ...[
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          OutlinedButton(onPressed: _load, child: const Text('Erneut laden')),
        ],
        Text(
          '${_submissions.length} abgegeben',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        if (_submissions.isEmpty && _error == null)
          const Text('Bisher hat niemand dieses Formular abgegeben.'),
        for (final submission in _submissions)
          Card(
            child: ListTile(
              leading: const Icon(Icons.assignment_turned_in_outlined),
              title: Text(textValue(submission['personName'])),
              subtitle: Text(_submittedAt(submission)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final deleted = await openPage<bool>(
                  context,
                  _SubmissionReceiptScreen(
                    controller: widget.controller,
                    submission: submission,
                  ),
                );
                if (deleted == true && mounted && _allowed) {
                  setState(() => _submissions.remove(submission));
                  await _load();
                }
              },
            ),
          ),
      ],
    ],
  );
}

String _submittedAt(JsonMap submission) {
  final date = DateTime.tryParse(textValue(submission['submittedAt']));
  return date == null
      ? textValue(submission['submittedAt'])
      : DateFormat('dd.MM.yyyy, HH:mm').format(date.toLocal());
}

class _SubmissionReceiptScreen extends StatefulWidget {
  const _SubmissionReceiptScreen({
    required this.controller,
    required this.submission,
  });
  final AppController controller;
  final JsonMap submission;

  @override
  State<_SubmissionReceiptScreen> createState() =>
      _SubmissionReceiptScreenState();
}

class _SubmissionReceiptScreenState extends State<_SubmissionReceiptScreen> {
  late final String? _account;
  JsonMap? _submission;
  bool _busy = false;
  String? _withdrawKey;
  bool get _allowed =>
      widget.controller.hasAccess &&
      widget.controller.user?.isAdmin == true &&
      widget.controller.user?.id == _account &&
      _submission != null;

  @override
  void initState() {
    super.initState();
    _account = widget.controller.user?.id;
    _submission = cloneJson(widget.submission);
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (!_allowed) _submission = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  Future<void> _export() async {
    if (!_allowed) return;
    setState(() => _busy = true);
    try {
      await exportFormPdf(
        form: jsonMap(_submission!['form']),
        submission: _submission,
      );
    } catch (error) {
      if (mounted && _allowed) showProblem(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw() async {
    if (!_allowed || _busy) return;
    final confirmed = await confirmDestructive(
      context,
      title: 'Abgabe löschen?',
      message:
          'Die Antworten und die Unterschrift von ${textValue(_submission!['personName'])} werden gelöscht. Bereits exportierte PDF-Kopien bleiben erhalten.',
      confirmLabel: 'Abgabe löschen',
    );
    if (!confirmed || !mounted || !_allowed) return;
    _withdrawKey ??=
        'withdraw-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';
    setState(() => _busy = true);
    try {
      await FormsApi(
        widget.controller,
      ).withdraw(_submission!, forAdmin: true, idempotencyKey: _withdrawKey!);
      if (!mounted || !_allowed) return;
      setState(() => _submission = null);
      showDone(context, 'Abgabe gelöscht.');
      widget.controller.refresh().catchError((Object _) {});
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted && _allowed) showProblem(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Abgabe')),
    body: !_allowed
        ? const Center(
            child: Text('Bitte die Abgabe mit deinem Konto erneut öffnen.'),
          )
        : ListView(
            padding: pagePadding(context),
            children: [
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
            ],
          ),
  );
}
