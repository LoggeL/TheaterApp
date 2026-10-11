import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;

import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';

/// A German message for a failed password change. Firebase reports a wrong
/// current password as invalid credentials; everything else uses the
/// general [userMessage].
String passwordChangeError(Object error) {
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-credential' || 'wrong-password':
        return 'Das aktuelle Passwort stimmt nicht.';
      case 'requires-recent-login':
        return 'Bitte melde dich neu an und ändere dein Passwort danach direkt.';
      case 'weak-password':
        return 'Bitte ein längeres oder weniger leicht zu erratendes Passwort wählen.';
    }
  }
  return userMessage(error);
}

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
  final _form = GlobalKey<FormState>();
  final _old = TextEditingController(),
      _next = TextEditingController(),
      _confirm = TextEditingController();
  final _nextFocus = FocusNode(), _confirmFocus = FocusNode();
  bool _hideOld = true, _hideNext = true, _hideConfirm = true;
  String? _error;
  bool _working = false;
  @override
  void dispose() {
    _old.dispose();
    _next.dispose();
    _confirm.dispose();
    _nextFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_working || !_form.currentState!.validate()) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.changePassword(_old.text, _next.text);
      if (!mounted) return;
      TextInput.finishAutofillContext();
      if (!widget.requiredChange) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        messenger.showSnackBar(
          const SnackBar(content: Text('Dein Passwort wurde geändert.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = passwordChangeError(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _visibility(bool hidden, VoidCallback toggle) => IconButton(
    tooltip: hidden ? 'Passwort anzeigen' : 'Passwort verbergen',
    onPressed: () => setState(toggle),
    icon: Icon(
      hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final error = _error ?? widget.controller.error;
    return Scaffold(
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: AutofillGroup(
            child: Form(
              key: _form,
              child: ListView(
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
                  TextFormField(
                    controller: _old,
                    obscureText: _hideOld,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Aktuelles Passwort',
                      suffixIcon: _visibility(
                        _hideOld,
                        () => _hideOld = !_hideOld,
                      ),
                    ),
                    validator: (v) => v == null || v.isEmpty
                        ? 'Bitte dein aktuelles Passwort eingeben.'
                        : null,
                    onFieldSubmitted: (_) => _nextFocus.requestFocus(),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _next,
                    focusNode: _nextFocus,
                    obscureText: _hideNext,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Neues Passwort',
                      suffixIcon: _visibility(
                        _hideNext,
                        () => _hideNext = !_hideNext,
                      ),
                    ),
                    validator: (v) =>
                        (v ?? '').length < 12 ? 'Mindestens 12 Zeichen.' : null,
                    onFieldSubmitted: (_) => _confirmFocus.requestFocus(),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _confirm,
                    focusNode: _confirmFocus,
                    obscureText: _hideConfirm,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Neues Passwort wiederholen',
                      suffixIcon: _visibility(
                        _hideConfirm,
                        () => _hideConfirm = !_hideConfirm,
                      ),
                    ),
                    validator: (v) => v != _next.text
                        ? 'Die Passwörter stimmen nicht überein.'
                        : null,
                    onFieldSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 20),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          error,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: _working ? null : _save,
                    child: Text(
                      _working ? 'Wird gespeichert …' : 'Passwort speichern',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
