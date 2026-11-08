import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/identity.dart';
import '../../../data/api_client.dart';
import '../../../shared/feedback.dart';
import 'sign_in_providers.dart';

class PasskeysScreen extends StatefulWidget {
  const PasskeysScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<PasskeysScreen> createState() => _PasskeysScreenState();
}

class _PasskeysScreenState extends State<PasskeysScreen> {
  List<Map<String, dynamic>> _keys = [];
  bool _loading = true, _busy = false, _available = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keys = await widget.controller.listPasskeys();
      final available = await widget.controller.passkeysAvailable();
      if (mounted) {
        setState(() {
          _keys = keys;
          _available = available;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = identityError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _confirmIdentity() async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => _ConfirmIdentityDialog(controller: widget.controller),
      ) ==
      true;

  Future<void> _run(
    Future<List<Map<String, dynamic>>> Function() action,
    String done,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final keys = await action();
      if (mounted) {
        setState(() => _keys = keys);
        showDone(context, done);
      }
    } catch (e) {
      if (mounted && !(e is ApiException && e.code == 'passkey_cancelled')) {
        setState(() => _error = identityError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _PasskeyNameDialog(),
    );
    if (name == null || !mounted) return;
    if (!await _confirmIdentity() || !mounted) return;
    await _run(
      () => widget.controller.addPasskey(name),
      'Passkey hinzugefügt. Du kannst dich jetzt damit anmelden.',
    );
  }

  Future<void> _remove(Map<String, dynamic> key) async {
    final confirmed = await confirmDestructive(
      context,
      title: '${key['name']} entfernen?',
      message:
          'Dieser Passkey kann sich danach nicht mehr anmelden. Bestehende Anmeldungen mit ihm enden. Den Eintrag in deinem Passwortmanager kannst du anschließend dort löschen.',
      confirmLabel: 'Entfernen',
    );
    if (!confirmed || !mounted) return;
    if (!await _confirmIdentity() || !mounted) return;
    await _run(
      () => widget.controller.removePasskey(key['id'] as String),
      'Passkey entfernt.',
    );
  }

  String _date(Object? value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    return date == null ? '' : DateFormat('dd.MM.yyyy').format(date.toLocal());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Passkeys')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Icon(Icons.key_outlined, size: 40),
        const SizedBox(height: 16),
        Text(
          'Anmelden mit deinem Gerät',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        const Text(
          'Mit einem Passkey bestätigst du die Anmeldung per Fingerabdruck, Gesichtserkennung oder Gerätesperre. Dein Passwort bleibt als weitere Anmeldeart erhalten, falls du eines eingerichtet hast.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Verlierst du den Zugriff auf deinen Passkey, nutze eine andere verknüpfte Anmeldeart. Über "Passwort vergessen" kannst du ein bestehendes Passwort zurücksetzen.',
        ),
        const SizedBox(height: 24),
        if (_loading || _busy) const LinearProgressIndicator(),
        if (!_loading && _error == null && _keys.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('Du hast noch keinen Passkey hinterlegt.'),
          ),
        for (final key in _keys)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(key['name'] as String),
                subtitle: Text(
                  key['lastUsedAt'] == null
                      ? 'Hinzugefügt am ${_date(key['createdAt'])}'
                      : 'Zuletzt verwendet am ${_date(key['lastUsedAt'])}',
                ),
                trailing: IconButton(
                  tooltip: '${key['name']} entfernen',
                  onPressed: _busy ? null : () => _remove(key),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            ),
          ),
        if (!_loading && _available && _keys.length < 10)
          FilledButton.icon(
            onPressed: _busy ? null : _add,
            icon: const Icon(Icons.add),
            label: const Text('Passkey hinzufügen'),
          ),
        if (!_loading && !_available && _error == null)
          const Text(
            'Auf diesem Gerät oder dieser App-Adresse lassen sich derzeit keine Passkeys erstellen. Deine hinterlegten Passkeys kannst du hier weiterhin verwalten.',
          ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Erneut laden'),
          ),
        ],
      ],
    ),
  );
}

class _PasskeyNameDialog extends StatefulWidget {
  const _PasskeyNameDialog();
  @override
  State<_PasskeyNameDialog> createState() => _PasskeyNameDialogState();
}

class _PasskeyNameDialogState extends State<_PasskeyNameDialog> {
  final _name = TextEditingController(text: 'Mein Passkey');
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, _name.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Passkey benennen'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _name,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(
          labelText: 'Name',
          helperText: 'Zum Beispiel "iPhone" oder "Passwortmanager".',
          helperMaxLines: 3,
        ),
        validator: (value) => value?.trim().isNotEmpty == true
            ? null
            : 'Bitte einen Namen eingeben.',
        onFieldSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Weiter')),
    ],
  );
}

class _ConfirmIdentityDialog extends StatefulWidget {
  const _ConfirmIdentityDialog({required this.controller});
  final AppController controller;
  @override
  State<_ConfirmIdentityDialog> createState() => _ConfirmIdentityDialogState();
}

class _ConfirmIdentityDialogState extends State<_ConfirmIdentityDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm({String? provider}) async {
    if (_busy) return;
    if (provider == null && _password.text.isEmpty) {
      setState(() => _error = 'Bitte dein aktuelles Passwort eingeben.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.confirmPasskeyManagement(
        password: provider == null ? _password.text : null,
        provider: provider,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = identityError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = widget.controller.identity!.linkedProviders;
    return AlertDialog(
      scrollable: true,
      title: const Text('Anmeldung bestätigen'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Bestätige dein Konto, bevor du seine Passkeys änderst.'),
          const SizedBox(height: 18),
          if (providers.contains('password')) ...[
            TextField(
              controller: _password,
              obscureText: true,
              enabled: !_busy,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(
                labelText: 'Aktuelles Passwort',
              ),
              onSubmitted: (_) => _confirm(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : () => _confirm(),
              child: const Text('Bestätigen'),
            ),
          ],
          for (final p in providers.where(
            (p) => p != 'password' && providerNames.containsKey(p),
          ))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _confirm(provider: p),
                icon: Icon(providerIcon(p)),
                label: Text('Mit ${providerNames[p]} bestätigen'),
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
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
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
      ],
    );
  }
}
