import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../shared/audience/recipients.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';

class MessageComposerScreen extends StatefulWidget {
  const MessageComposerScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<MessageComposerScreen> createState() => _MessageComposerScreenState();
}

class _MessageComposerScreenState extends State<MessageComposerScreen> {
  final _title = TextEditingController(),
      _body = TextEditingController(),
      _link = TextEditingController(),
      _linkLabel = TextEditingController();
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

  bool get _ready =>
      _title.text.trim().isNotEmpty &&
      _body.text.trim().isNotEmpty &&
      _linkError == null &&
      _to.chosen;

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'message.send',
        'title': _title.text,
        'body': _body.text,
        'link': _link.text.trim(),
        'linkLabel': _linkLabel.text.trim(),
        ..._to.toJson(),
        'push': _push && widget.controller.pushConfigured,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.pendingCount > 0
                  ? 'Mitteilung zur Übertragung vorgemerkt.'
                  : 'Mitteilung veröffentlicht.',
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
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
    ],
  );
}
