import 'brand_logo.dart';
import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/brand.dart';
import '../data/api_client.dart';
import 'theme.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _form = GlobalKey<FormState>();
  late final _server = TextEditingController(
    text: widget.controller.apiBaseUrl.isNotEmpty
        ? widget.controller.apiBaseUrl
        : Brand.apiUrl,
  );
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true, _working = false, _showLogin = false;
  String? _error;
  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.login(
        email: _email.text.trim(),
        password: _password.text,
        baseUrl: _server.text.trim(),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _demo() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.controller.startDemo();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(26, 28, 26, 32),
            children: [
              const Row(
                children: [
                  BrandLogo(size: 35),
                  SizedBox(width: 12),
                  Expanded(child: Eyebrow('Kolpingtheater Ramsen')),
                ],
              ),
              const SizedBox(height: 28),
              Container(
                height: _showLogin ? 120 : 240,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: StageTheme.ink,
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _SpotlightPainter()),
                    ),
                    Positioned(
                      left: 24,
                      bottom: 24,
                      right: 24,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _showLogin ? 'Anmelden' : 'Kolpingtheater\nRamsen',
                            style: TextStyle(
                              fontSize: _showLogin ? 24 : 38,
                              height: 1.08,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Text(
                Brand.name,
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              Text(
                _showLogin
                    ? 'Melde dich mit deinem bestehenden Theaterkonto an.'
                    : 'Termine, Drehbücher und Mitteilungen.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 26),
              if (_showLogin)
                Form(
                  key: _form,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _server,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Adresse eures Servers',
                          hintText: 'https://proben.example.de',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                        validator: (value) {
                          try {
                            ApiClient.normalizeBaseUrl(value ?? '');
                            return null;
                          } on ApiException catch (e) {
                            return e.message;
                          }
                        },
                      ),
                      const SizedBox(height: 14),
                      AutofillGroup(
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [
                                AutofillHints.username,
                                AutofillHints.email,
                              ],
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'E-Mail',
                                prefixIcon: Icon(Icons.alternate_email),
                              ),
                              validator: (v) => v != null && v.contains('@')
                                  ? null
                                  : 'Bitte deine E-Mail eingeben.',
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _password,
                              obscureText: _obscure,
                              autofillHints: const [AutofillHints.password],
                              onFieldSubmitted: (_) =>
                                  _working ? null : _login(),
                              decoration: InputDecoration(
                                labelText: 'Passwort',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: _obscure
                                      ? 'Passwort anzeigen'
                                      : 'Passwort verbergen',
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: (v) => v == null || v.isEmpty
                                  ? 'Bitte dein Passwort eingeben.'
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _working ? null : _login,
                          child: Text(
                            _working ? 'Anmeldung läuft …' : 'Anmelden',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Dein Konto legt die Theaterverwaltung an. Wende dich bei einem vergessenen Passwort an eure Administration.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => setState(() => _showLogin = true),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Mit Theaterkonto anmelden'),
                  ),
                ),
              if (_error != null || widget.controller.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    _error ?? widget.controller.error ?? '',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _working ? null : _demo,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('App mit Beispieldaten ausprobieren'),
              ),
              const SizedBox(height: 14),
              Text(
                'Die Demo arbeitet lokal mit erfundenen Terminen und Texten.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SpotlightPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    p.color = const Color(0xFF8C492E).withValues(alpha: .38);
    canvas.drawPath(
      Path()
        ..moveTo(size.width * .73, -20)
        ..lineTo(size.width * .16, size.height)
        ..lineTo(size.width * 1.2, size.height)
        ..close(),
      p,
    );
    p.color = const Color(0xFFFFB57D).withValues(alpha: .13);
    canvas.drawPath(
      Path()
        ..moveTo(size.width * .76, -20)
        ..lineTo(size.width * .4, size.height)
        ..lineTo(size.width * 1.03, size.height)
        ..close(),
      p,
    );
    p.color = const Color(0xFFFFBF87);
    canvas.drawCircle(Offset(size.width * .75, 25), 12, p);
    p.color = Colors.white.withValues(alpha: .05);
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
