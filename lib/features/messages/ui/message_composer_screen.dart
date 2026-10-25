import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/audience/recipients.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../forms/ui/forms_admin_screen.dart';

/// Writes a message that stays in the Mitteilungen tab. Pops `true` once
/// it was published or queued.
class MessageComposerScreen extends StatefulWidget {
  const MessageComposerScreen({
    super.key,
    required this.controller,
    this.initialTitle = '',
    this.initialBody = '',
  });
  final AppController controller;

  /// Text taken over, e.g. from a push draft.
  final String initialTitle, initialBody;
  @override
  State<MessageComposerScreen> createState() => _MessageComposerScreenState();
}

class _MessageComposerScreenState extends State<MessageComposerScreen> {
  late final _title = TextEditingController(text: widget.initialTitle),
      _body = TextEditingController(text: widget.initialBody);
  final _link = TextEditingController(), _linkLabel = TextEditingController();
  bool _push = true, _busy = false;
  JsonMap? _selectedForm;
  String? _publicationKey, _publicationBody;
  late final String? _owner;
  Recipients _to = const Recipients();
  @override
  void initState() {
    super.initState();
    _owner = widget.controller.user?.id;
    widget.controller.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (_selectedForm != null &&
        (widget.controller.user?.id != _owner ||
            !widget.controller.hasAccess ||
            widget.controller.user?.isAdmin != true)) {
      setState(() => _selectedForm = null);
      _publicationBody = _publicationKey = null;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sessionChanged);
    _title.dispose();
    _body.dispose();
    _link.dispose();
    _linkLabel.dispose();
    super.dispose();
  }

  String? get _linkError {
    final link = _link.text.trim();
    if (link.isEmpty) return null;
    final uri = Uri.tryParse(link);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty &&
            !link.contains(' ')
        ? null
        : 'Bitte einen vollständigen Link mit https:// angeben.';
  }

  /// What still keeps the message from being published.
  List<String> get _missing => [
    if (_title.text.trim().isEmpty) 'Betreff',
    if (_body.text.trim().isEmpty) 'Nachricht',
    if (_linkError != null) 'gültiger Link',
    if (!_to.chosen) 'Empfänger',
  ];

  bool get _ready => _missing.isEmpty;

  /// Unsaved input; text taken over from elsewhere still exists there.
  bool get _dirty =>
      _title.text != widget.initialTitle ||
      _body.text != widget.initialBody ||
      _link.text.isNotEmpty ||
      _linkLabel.text.isNotEmpty ||
      _selectedForm != null ||
      !_to.everyone;

  bool get _withPush => _push && widget.controller.pushConfigured;

  /// Everyone gets a push right away, so the reach is confirmed first.
  Future<bool> _confirmPush() {
    final count = _to.members(widget.controller).length;
    return confirmAction(
      context,
      title: count == 1
          ? 'Mitteilung an 1 Person veröffentlichen?'
          : 'Mitteilung an $count Personen veröffentlichen?',
      message: count == 1
          ? 'Die Person erhält zusätzlich einen Push.'
          : 'Alle erhalten zusätzlich einen Push.',
      confirmLabel: 'Veröffentlichen',
    );
  }

  Future<void> _send() async {
    if (_withPush && !await _confirmPush()) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final body = <String, dynamic>{
        'action': 'message.send',
        'title': _title.text,
        'body': _body.text,
        'link': _link.text.trim(),
        'linkLabel': _linkLabel.text.trim(),
        ..._to.toJson(),
        'push': _withPush,
        if (_selectedForm != null) ...{
          'formId': _selectedForm!['id'],
          'formVersion': _selectedForm!['version'],
        },
      };
      // Freeze the selected template only after the server accepts its version.
      // Do not queue a publication that may later use an outdated form.
      final ActionResult result;
      if (_selectedForm != null) {
        final encoded = jsonEncode(body);
        if (_publicationBody != encoded) {
          _publicationBody = encoded;
          final random = Random.secure();
          _publicationKey = List.generate(
            16,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
        }
        final data = await widget.controller.remote(
          '/actions',
          method: 'POST',
          body: body,
          idempotencyKey: _publicationKey,
        );
        result = ActionResult(ActionOutcome.synced, data);
        await widget.controller.refresh();
      } else {
        result = await widget.controller.performActionWithResult(body);
      }
      if (mounted) {
        final recipients = result.data?['recipients'];
        showDone(
          context,
          outcomeText(
            result.outcome,
            done: recipients is num
                ? recipients == 1
                      ? 'An 1 Person veröffentlicht.'
                      : 'An ${recipients.toInt()} Personen veröffentlicht.'
                : 'Mitteilung veröffentlicht.',
            queued: 'Mitteilung zur Übertragung vorgemerkt.',
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseForm() async {
    final selected = await openPage<JsonMap>(
      context,
      FormsAdminScreen(controller: widget.controller, selectMode: true),
    );
    if (mounted && selected != null) setState(() => _selectedForm = selected);
  }

  @override
  Widget build(BuildContext context) => DiscardGuard(
    dirty: _dirty && !_busy,
    child: AdminPage(
      controller: widget.controller,
      title: 'Mitteilung schreiben',
      children: (context) => [
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Betreff'),
          maxLength: 250,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _body,
          decoration: const InputDecoration(
            labelText: 'Nachricht',
            alignLabelWithHint: true,
          ),
          minLines: 7,
          maxLines: 18,
          maxLength: 10000,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _link,
          decoration: InputDecoration(
            labelText: 'Link (optional)',
            hintText: 'https://…',
            prefixIcon: const Icon(Icons.link),
            errorText: _linkError,
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
          maxLength: 2000,
          buildCounter:
              (_, {required currentLength, required isFocused, maxLength}) =>
                  null,
          onChanged: (_) => setState(() {}),
        ),
        if (_link.text.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _linkLabel,
            decoration: const InputDecoration(
              labelText: 'Beschriftung des Links (optional)',
              hintText: 'z. B. Zum Anmeldeformular',
            ),
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
          ),
        ],
        if (!widget.controller.isDemo &&
            widget.controller.supports('forms')) ...[
          const SectionTitle('Formular'),
          if (_selectedForm case final selected?) ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(textValue(selected['title'])),
                subtitle: const Text('Direkt in der App ausfüllen und abgeben'),
                trailing: IconButton(
                  tooltip: 'Formular entfernen',
                  onPressed: _busy
                      ? null
                      : () => setState(() => _selectedForm = null),
                  icon: const Icon(Icons.close),
                ),
                onTap: _busy ? null : _chooseForm,
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6, bottom: 6),
              child: Text(
                'Mit Formular wird die Mitteilung mit Verbindung veröffentlicht.',
              ),
            ),
          ] else
            OutlinedButton.icon(
              onPressed: _busy ? null : _chooseForm,
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('Formular auswählen'),
            ),
        ],
        const SectionTitle('Empfänger'),
        RecipientSelector(
          controller: widget.controller,
          value: _to,
          onChanged: (value) => setState(() => _to = value),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          value: _push && widget.controller.pushConfigured,
          onChanged: widget.controller.pushConfigured
              ? (v) => setState(() => _push = v)
              : null,
          title: const Text('Auch als Push benachrichtigen'),
          subtitle: Text(
            widget.controller.pushConfigured
                ? 'Die Mitteilung bleibt zusätzlich im Reiter „Post“ zum Nachlesen.'
                : 'Push ist noch nicht eingerichtet.',
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy || !_ready ? null : _send,
          icon: const Icon(Icons.send_outlined),
          label: const Text('Mitteilung veröffentlichen'),
        ),
        if (!_ready) ...[
          const SizedBox(height: 8),
          Text(
            'Noch fehlt: ${_missing.join(', ')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    ),
  );
}
