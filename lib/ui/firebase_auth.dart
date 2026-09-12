import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../core/brand.dart';
import '../core/identity.dart';
import 'theme.dart';

const providerNames = {
  'google.com': 'Google',
  'apple.com': 'Apple',
  'microsoft.com': 'Microsoft',
  'facebook.com': 'Facebook',
  'github.com': 'GitHub',
  'twitter.com': 'X',
  'yahoo.com': 'Yahoo',
  'password': 'E-Mail & Passwort',
};
IconData providerIcon(String provider) => switch (provider) {
  'google.com' => Icons.g_mobiledata,
  'apple.com' => Icons.apple,
  'microsoft.com' => Icons.window,
  'facebook.com' => Icons.facebook,
  _ => Icons.login,
};

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
                        Icon(
                          Icons.theater_comedy_outlined,
                          color: StageTheme.orange,
                          size: 32,
                        ),
                        SizedBox(width: 12),
                        Text(
                          Brand.name,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
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
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 18),
                              child: Text('oder per E-Mail'),
                            ),
                            Expanded(child: Divider()),
                          ],
                        ),
                      ),
                    if (_register) ...[
                      TextFormField(
                        controller: _name,
                        autofillHints: const [AutofillHints.name],
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(labelText: 'Name'),
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

class ApprovalPendingScreen extends StatefulWidget {
  const ApprovalPendingScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ApprovalPendingScreen> createState() => _ApprovalPendingScreenState();
}

class _ApprovalPendingScreenState extends State<ApprovalPendingScreen> {
  bool _busy = false;
  String? _error, _info;
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = identityError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, user = widget.controller.user!;
    final blocked = ['suspended', 'rejected'].contains(user.status);
    final verify = !user.identityReady;
    final title = blocked
        ? 'Zugang nicht freigegeben'
        : verify
        ? 'E-Mail bestätigen'
        : 'Freigabe ausstehend';
    return Scaffold(
      appBar: AppBar(title: const Text(Brand.name)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(28),
              children: [
                const SizedBox(height: 32),
                CircleAvatar(
                  radius: 42,
                  backgroundColor: const Color(0xFFFFECCE),
                  child: Icon(
                    blocked
                        ? Icons.lock_outline
                        : verify
                        ? Icons.mark_email_unread_outlined
                        : Icons.schedule,
                    color: const Color(0xFFA25B06),
                    size: 42,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                Text(
                  blocked
                      ? 'Bitte wende dich an die Theaterleitung.'
                      : verify
                      ? 'Öffne den Link in deiner E-Mail. Danach kann die Theaterleitung deinen Zugang freigeben.'
                      : 'Dein Konto ist erstellt. Die Theaterleitung ordnet dich einer Person zu und gibt deinen Zugang frei.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(user.email),
                        const SizedBox(height: 12),
                        StatePill(
                          user.emailVerified
                              ? 'E-Mail bestätigt'
                              : verify
                              ? 'Bestätigung ausstehend'
                              : 'Konto erstellt',
                          icon: user.emailVerified
                              ? Icons.check
                              : Icons.schedule,
                          color: user.emailVerified
                              ? StageTheme.green
                              : const Color(0xFFA25B06),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_info != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(_info!),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await c.identity!.reload();
                          await c.refreshAccess();
                        }),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Status aktualisieren'),
                ),
                if (verify)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await c.identity!.verifyEmail();
                            if (mounted) {
                              setState(
                                () => _info =
                                    'Die Bestätigungs-E-Mail wurde erneut angefordert.',
                              );
                            }
                          }),
                    child: const Text('E-Mail erneut senden'),
                  ),
                const SizedBox(height: 14),
                TextButton(
                  onPressed: _busy ? null : () => _run(c.logout),
                  child: const Text('Abmelden'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
