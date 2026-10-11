import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../shared/audience/recipients.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';

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
  Recipients _to = const Recipients();
  @override
  void dispose() {
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
      final outcome = await widget.controller.performAction({
        'action': 'message.send',
        'title': _title.text,
        'body': _body.text,
        'link': _link.text.trim(),
        'linkLabel': _linkLabel.text.trim(),
        ..._to.toJson(),
        'push': _withPush,
      });
      if (mounted) {
        showDone(
          context,
          outcomeText(
            outcome,
            done: 'Mitteilung veröffentlicht.',
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
                ? 'Die Mitteilung bleibt zusätzlich im Reiter Mitteilungen zum Nachlesen.'
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
