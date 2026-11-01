import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../data/accounts_api.dart';

bool accountPasswordResetAvailable(AppController c, JsonMap account) =>
    c.supports('accountPasswordResetLink') &&
    textValue(account['email']).isNotEmpty;

Future<void> showPasswordResetLink(
  BuildContext context,
  AppController controller,
  JsonMap account,
) => showDialog<void>(
  context: context,
  builder: (_) =>
      _PasswordResetDialog(controller: controller, account: account),
);

class _PasswordResetDialog extends StatefulWidget {
  const _PasswordResetDialog({required this.controller, required this.account});
  final AppController controller;
  final JsonMap account;

  @override
  State<_PasswordResetDialog> createState() => _PasswordResetDialogState();
}

class _PasswordResetDialogState extends State<_PasswordResetDialog> {
  String? _link, _error;
  bool _busy = false, _copied = false;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await generatePasswordResetLink(
        widget.controller,
        widget.account,
      );
      final link = textValue(result['link']);
      if (link.isEmpty) throw StateError('Kein Passwort-Link erhalten.');
      if (mounted) setState(() => _link = link);
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _link!));
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
              'Kopieren nicht möglich. Du kannst den Link markieren und '
              'selbst kopieren.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final offline = widget.controller.isOffline;
      return AlertDialog(
        title: const Text('Passwort-Link erzeugen'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(textValue(widget.account['name'])),
                SelectableText(textValue(widget.account['email'])),
                const SizedBox(height: 16),
                const Text(
                  'Die Person kann über diesen Link ein neues Passwort setzen, '
                  'ohne ihr E-Mail-Postfach zu öffnen. Es wird keine E-Mail versendet.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Gib den Link nur direkt an diese Person weiter. Wer ihn hat, '
                  'kann ihr Passwort ändern. Der Link ist einmal verwendbar und '
                  'läuft ab. Die Theaterfreigabe und die Rechte bleiben bestehen.',
                ),
                if (_link != null) ...[
                  const SizedBox(height: 16),
                  SelectableText(
                    _link!,
                    key: const ValueKey('password-reset-link'),
                  ),
                ],
                if (offline && _link == null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Zum Erzeugen des Links brauchst du eine Verbindung.',
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
          if (_link == null)
            FilledButton(
              onPressed: _busy || offline ? null : _generate,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Link erzeugen'),
            )
          else
            FilledButton.icon(
              onPressed: _copy,
              icon: Icon(_copied ? Icons.check : Icons.copy),
              label: Text(_copied ? 'Kopiert' : 'Link kopieren'),
            ),
        ],
      );
    },
  );
}
