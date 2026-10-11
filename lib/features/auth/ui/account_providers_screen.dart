import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/identity.dart';
import '../../../shared/feedback.dart';
import 'sign_in_providers.dart';

class AccountProvidersScreen extends StatefulWidget {
  const AccountProvidersScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<AccountProvidersScreen> createState() => _AccountProvidersScreenState();
}

class _AccountProvidersScreenState extends State<AccountProvidersScreen> {
  bool _busy = false;
  String? _error;

  /// Runs [action], reloads the identity and confirms with [done].
  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await widget.controller.identity!.reload();
      if (mounted) showDone(context, done);
    } catch (e) {
      if (mounted) setState(() => _error = identityError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _name(String provider) => providerNames[provider] ?? provider;

  Future<void> _unlink(String provider) async {
    final identity = widget.controller.identity!;
    final remaining = identity.linkedProviders
        .where((p) => p != provider)
        .map(_name)
        .toList();
    final confirmed = await confirmDestructive(
      context,
      title: '${_name(provider)} entfernen?',
      message: remaining.isEmpty
          ? 'Danach kannst du dich nicht mehr mit ${_name(provider)} anmelden.'
          : 'Du meldest dich danach nur noch mit ${remaining.join(' oder ')} an.',
      confirmLabel: 'Entfernen',
    );
    if (!confirmed || !mounted) return;
    await _run(
      () => identity.unlink(provider),
      '${_name(provider)} wurde entfernt.',
    );
  }

  Future<void> _addPassword() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => const _AddPasswordDialog(),
    );
    if (chosen == null || !mounted) return;
    await _run(
      () => widget.controller.identity!.addPassword(chosen),
      'Passwort ergänzt. Du kannst dich jetzt auch mit E-Mail und Passwort anmelden.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final identity = widget.controller.identity!;
    return Scaffold(
      appBar: AppBar(title: const Text('Anmeldearten')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Text(
            widget.controller.user!.email,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          for (final p in FirebaseConfiguration.providers.split(','))
            Card(
              child: ListTile(
                leading: Icon(providerIcon(p)),
                title: Text(_name(p)),
                subtitle: Text(
                  identity.linkedProviders.contains(p)
                      ? 'Verknüpft'
                      : 'Noch nicht verknüpft',
                ),
                trailing: p == 'password'
                    ? (identity.linkedProviders.contains(p)
                          ? null
                          : TextButton(
                              onPressed: _busy ? null : _addPassword,
                              child: const Text('Ergänzen'),
                            ))
                    : TextButton(
                        onPressed: _busy
                            ? null
                            : () => identity.linkedProviders.contains(p)
                                  ? _unlink(p)
                                  : _run(
                                      () => identity.social(p, link: true),
                                      '${_name(p)} ist jetzt verknüpft.',
                                    ),
                        child: Text(
                          identity.linkedProviders.contains(p)
                              ? 'Entfernen'
                              : 'Verbinden',
                        ),
                      ),
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Asks for a new password twice; owns its controllers so the closing
/// animation never sees disposed ones. Pops the password or null.
class _AddPasswordDialog extends StatefulWidget {
  const _AddPasswordDialog();
  @override
  State<_AddPasswordDialog> createState() => _AddPasswordDialogState();
}

class _AddPasswordDialogState extends State<_AddPasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController(), _repeat = TextEditingController();
  final _repeatFocus = FocusNode();
  bool _hidden = true;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    _repeatFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) Navigator.pop(context, _password.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Passwort ergänzen'),
    content: AutofillGroup(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _password,
              obscureText: _hidden,
              autofocus: true,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Neues Passwort',
                helperText: 'Mindestens 12 Zeichen',
                suffixIcon: IconButton(
                  tooltip: _hidden ? 'Passwort anzeigen' : 'Passwort verbergen',
                  onPressed: () => setState(() => _hidden = !_hidden),
                  icon: Icon(
                    _hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              validator: (v) =>
                  (v ?? '').length < 12 ? 'Mindestens 12 Zeichen.' : null,
              onFieldSubmitted: (_) => _repeatFocus.requestFocus(),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _repeat,
              focusNode: _repeatFocus,
              obscureText: _hidden,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Passwort wiederholen',
              ),
              validator: (v) => v != _password.text
                  ? 'Die Passwörter stimmen nicht überein.'
                  : null,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Speichern')),
    ],
  );
}
