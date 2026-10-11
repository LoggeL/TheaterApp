import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../../../app/platform/pwa_install_card.dart';
import '../../../core/app_controller.dart';
import '../../../core/identity.dart';
import '../../../shared/widgets/brand_logo.dart';
import '../../../shared/widgets/privacy_links.dart';
import 'sign_in_providers.dart';

class FirebaseWelcomeScreen extends StatefulWidget {
  const FirebaseWelcomeScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<FirebaseWelcomeScreen> createState() => _FirebaseWelcomeScreenState();
}

class _FirebaseWelcomeScreenState extends State<FirebaseWelcomeScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _email = TextEditingController(),
      _password = TextEditingController();
  bool _register = false, _hidden = true, _busy = false;
  String? _error, _info;
  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => _error = identityError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    await _run(
      () => _register
          ? widget.controller.register(_name.text, _email.text, _password.text)
          : widget.controller.login(
              email: _email.text,
              password: _password.text,
              baseUrl: widget.controller.apiBaseUrl,
            ),
    );
  }

  Future<void> _reset() async {
    if (!_email.text.contains('@')) {
      setState(() => _error = 'Bitte zuerst deine E-Mail-Adresse eintragen.');
      return;
    }
    await _run(() async {
      await widget.controller.identity!.initialize();
      await widget.controller.identity!.resetPassword(_email.text);
      if (mounted) {
        setState(
          () => _info =
              'Falls ein Konto mit dieser Adresse existiert, erhältst du eine E-Mail zum Zurücksetzen.',
        );
      }
    });
  }

  Widget _provider(String provider) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: OutlinedButton.icon(
      onPressed: _busy
          ? null
          : () => _run(() => widget.controller.loginWithProvider(provider)),
      icon: Icon(
        providerIcon(provider),
        size: provider == 'google.com' ? 30 : 24,
      ),
      label: Text('Mit ${providerNames[provider] ?? provider} fortfahren'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(double.infinity, 54),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final providers = FirebaseConfiguration.providers
        .split(',')
        .where(providerNames.containsKey)
        .toList();
    final others = providers
        .where((p) => !['password', 'google.com', 'apple.com'].contains(p))
        .toList();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: AutofillGroup(
              child: Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(28, 30, 28, 28),
                  children: [
                    const Row(
                      children: [
                        BrandLogo(size: 37),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            Brand.name,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 38),
                    Text(
                      _register ? 'Konto erstellen' : 'Willkommen zurück',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 28),
                    if (providers.contains('google.com'))
                      _provider('google.com'),
                    if (providers.contains('apple.com')) _provider('apple.com'),
                    if (others.isNotEmpty)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => showModalBottomSheet<void>(
                                context: context,
                                builder: (sheet) => SafeArea(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Weitere Anmeldearten',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleLarge,
                                        ),
                                        const SizedBox(height: 20),
                                        for (final p in others)
                                          ListTile(
                                            leading: Icon(providerIcon(p)),
                                            title: Text(providerNames[p]!),
                                            trailing: const Icon(
                                              Icons.chevron_right,
                                            ),
                                            onTap: () {
                                              Navigator.pop(sheet);
                                              _run(
                                                () => widget.controller
                                                    .loginWithProvider(p),
                                              );
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                        child: const Text('Weitere Anmeldearten'),
                      ),
                    if (providers.any((p) => p != 'password'))
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Row(
                          children: [
                            Expanded(child: Divider()),
                            Flexible(
                              flex: 3,
                              child: Padding(
                                padding: EdgeInsets.symmetric(horizontal: 12),
                                child: Text(
                                  'oder per E-Mail',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                            Expanded(child: Divider()),
                          ],
                        ),
                      ),
                    if (_register) ...[
                      TextFormField(
                        controller: _name,
                        maxLength: 120,
                        autofillHints: const [AutofillHints.name],
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Name zur Zuordnung',
                          hintText: 'Vor- und Nachname',
                          helperText:
                              'Nur zur Zuordnung deines Kontos zur richtigen Person im Ensemble.',
                          helperMaxLines: 5,
                          counterText: '',
                        ),
                        validator: (s) => s?.trim().isNotEmpty == true
                            ? null
                            : 'Bitte deinen Namen eingeben.',
                      ),
                      const SizedBox(height: 18),
                    ],
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'E-Mail'),
                      validator: (s) => s != null && s.contains('@')
                          ? null
                          : 'Bitte eine gültige E-Mail-Adresse eingeben.',
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _password,
                      obscureText: _hidden,
                      autofillHints: [
                        _register
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      decoration: InputDecoration(
                        labelText: 'Passwort',
                        helperText: _register ? 'Mindestens 12 Zeichen' : null,
                        suffixIcon: IconButton(
                          tooltip: _hidden
                              ? 'Passwort anzeigen'
                              : 'Passwort verbergen',
                          onPressed: () => setState(() => _hidden = !_hidden),
                          icon: Icon(
                            _hidden
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      onFieldSubmitted: (_) {
                        if (!_busy) _submit();
                      },
                      validator: (s) => s == null || s.isEmpty
                          ? 'Bitte dein Passwort eingeben.'
                          : _register && s.length < 12
                          ? 'Bitte mindestens 12 Zeichen verwenden.'
                          : null,
                    ),
                    if (!_register)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _busy ? null : _reset,
                          child: const Text('Passwort vergessen?'),
                        ),
                      ),
                    if (_error != null || widget.controller.error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _error ?? widget.controller.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (_info != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(_info!),
                      ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_register ? 'Konto erstellen' : 'Anmelden'),
                    ),
                    if (_register)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Text(
                          'Die Theaterleitung gibt dein Konto anschließend frei.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 18),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _register = !_register;
                              _error = null;
                              _info = null;
                              widget.controller.clearError();
                            }),
                      child: Text(
                        _register
                            ? 'Schon registriert? Anmelden'
                            : 'Noch kein Konto? Registrieren',
                      ),
                    ),
                    const PrivacyLinks(),
                    const PwaInstallCard(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
