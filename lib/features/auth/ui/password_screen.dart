import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';

class PasswordScreen extends StatefulWidget {
  const PasswordScreen({
    super.key,
    required this.controller,
    this.requiredChange = false,
  });
  final AppController controller;
  final bool requiredChange;
  @override
  State<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends State<PasswordScreen> {
  final _old = TextEditingController(),
      _next = TextEditingController(),
      _confirm = TextEditingController();
  String? _error;
  bool _working = false;
  @override
  void dispose() {
    _old.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_next.text.length < 12 || _next.text != _confirm.text) {
      setState(
        () => _error =
            'Mindestens 12 Zeichen; beide neuen Passwörter müssen gleich sein.',
      );
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.changePassword(_old.text, _next.text);
      if (mounted && !widget.requiredChange) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Passwort ändern'),
      automaticallyImplyLeading: !widget.requiredChange,
      actions: [
        if (widget.requiredChange)
          TextButton(
            onPressed: () => widget.controller.logout(),
            child: const Text('Abmelden'),
          ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          widget.requiredChange
              ? 'Mach dein Konto zu deinem.'
              : 'Ein neues Passwort.',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        const Text(
          'Verwende mindestens 12 Zeichen. Ein längerer Satz lässt sich oft gut merken.',
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _old,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Aktuelles Passwort'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _next,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Neues Passwort'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _confirm,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Neues Passwort wiederholen',
          ),
        ),
        const SizedBox(height: 20),
        if (_error != null || widget.controller.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              _error ?? widget.controller.error ?? '',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: _working ? null : _save,
          child: Text(_working ? 'Wird gespeichert …' : 'Passwort speichern'),
        ),
      ],
    ),
  );
}
