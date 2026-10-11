import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/identity.dart';
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
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await widget.controller.identity!.reload();
    } catch (e) {
      if (mounted) setState(() => _error = identityError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addPassword() async {
    final password = TextEditingController();
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Passwort ergänzen'),
        content: TextField(
          controller: password,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Mindestens 12 Zeichen'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, password.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    // The dialog route disposes after its closing animation.
    if (chosen != null) {
      await _run(() => widget.controller.identity!.addPassword(chosen));
    }
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
                title: Text(providerNames[p] ?? p),
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
                            : () => _run(
                                () => identity.linkedProviders.contains(p)
                                    ? identity.unlink(p)
                                    : identity.social(p, link: true),
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
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
