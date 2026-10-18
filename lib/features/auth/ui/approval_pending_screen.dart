import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/device_services.dart';
import '../../../core/identity.dart';
import '../../../shared/widgets/privacy_links.dart';
import '../../../shared/widgets/state_pill.dart';
import '../domain/app_user.dart';

class ApprovalPendingScreen extends StatefulWidget {
  const ApprovalPendingScreen({
    super.key,
    required this.controller,
    this.devices,
  });
  final AppController controller;

  /// Lets a waiting account turn on push, so the approval reaches it.
  final DeviceServices? devices;
  @override
  State<ApprovalPendingScreen> createState() => _ApprovalPendingScreenState();
}

enum _Step { blocked, name, verify, waiting }

class _ApprovalPendingScreenState extends State<ApprovalPendingScreen> {
  final _nameForm = GlobalKey<FormState>();
  late final TextEditingController _name;
  bool _busy = false, _editName = false;
  String? _error, _info;
  DateTime? _checkedAt;
  @override
  void initState() {
    super.initState();
    final user = widget.controller.user!;
    _name = TextEditingController(
      text: user.needsRegistrationName ? '' : user.name,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    if (!_nameForm.currentState!.validate()) return;
    await _run(() async {
      await widget.controller.saveRegistrationName(_name.text);
      if (mounted) {
        setState(() {
          _editName = false;
          _info = 'Dein Name zur Zuordnung ist gespeichert.';
        });
      }
    });
  }

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

  Future<void> _enablePush() => _run(() async {
    final message = await widget.devices!.enablePush();
    if (!mounted) return;
    setState(() {
      if (widget.controller.preferences['pushEnabled'] != true) {
        _info = message;
      }
    });
  });

  /// Offered until push is on; afterwards it confirms that the approval will
  /// arrive as a notification.
  Widget _pushNotice(BuildContext context) {
    final on = widget.controller.preferences['pushEnabled'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  on
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_none,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    on
                        ? 'Benachrichtigungen sind an'
                        : 'Bei Freigabe benachrichtigen',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              on
                  ? 'Du bekommst eine Nachricht, sobald dein Zugang '
                        'freigegeben ist, und danach Erinnerungen zu deinen '
                        'Terminen.'
                  : 'Aktiviere Benachrichtigungen schon jetzt. Dann erfährst '
                        'du sofort, wenn dein Zugang freigegeben ist, und '
                        'bekommst danach Erinnerungen zu deinen Terminen.',
            ),
            if (!on) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _busy ? null : _enablePush,
                icon: const Icon(Icons.notifications_outlined),
                label: const Text('Benachrichtigungen aktivieren'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Checks the e-mail confirmation and approval again and says when.
  Future<void> _check({bool confirmed = false}) => _run(() async {
    await widget.controller.refreshIdentityAccess();
    if (!mounted) return;
    final user = widget.controller.user;
    setState(() {
      _checkedAt = widget.controller.now;
      if (confirmed && user != null && !user.identityReady) {
        _info =
            'Die Bestätigung ist noch nicht angekommen. Bitte öffne den Link '
            'in der E-Mail und versuche es dann noch einmal.';
      }
    });
  });

  _Step _step(AppUser user) => ['suspended', 'rejected'].contains(user.status)
      ? _Step.blocked
      : user.needsRegistrationName
      ? _Step.name
      : !user.identityReady
      ? _Step.verify
      : _Step.waiting;

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _nameField() => Form(
    key: _nameForm,
    child: TextFormField(
      controller: _name,
      enabled: !_busy,
      maxLength: 120,
      autofillHints: const [AutofillHints.name],
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        labelText: 'Name zur Zuordnung',
        hintText: 'Vor- und Nachname',
        helperText:
            'Nur zur Zuordnung deines Kontos zur richtigen Person im Ensemble.',
        helperMaxLines: 5,
        counterText: '',
      ),
      validator: (value) => value?.trim().isNotEmpty == true
          ? null
          : 'Bitte deinen Namen eingeben.',
      onFieldSubmitted: (_) {
        if (!_busy) _saveName();
      },
    ),
  );

  /// The main action of each step, plus its secondary actions.
  List<Widget> _actions(_Step step, AppController c) => switch (step) {
    _Step.name => [
      _nameField(),
      const SizedBox(height: 14),
      FilledButton(
        onPressed: _busy ? null : _saveName,
        child: const Text('Namen speichern'),
      ),
    ],
    _Step.verify => [
      FilledButton.icon(
        onPressed: _busy ? null : () => _check(confirmed: true),
        icon: const Icon(Icons.mark_email_read_outlined),
        label: const Text('Ich habe bestätigt – prüfen'),
      ),
      const SizedBox(height: 8),
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
    ],
    _Step.waiting => [
      FilledButton.icon(
        onPressed: _busy ? null : _check,
        icon: const Icon(Icons.refresh),
        label: const Text('Status aktualisieren'),
      ),
      if (_checkedAt != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Noch nicht freigegeben · zuletzt geprüft ${_time(_checkedAt!)} Uhr',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      const SizedBox(height: 8),
      if (_editName) ...[
        _nameField(),
        const SizedBox(height: 14),
        OutlinedButton(
          onPressed: _busy ? null : _saveName,
          child: const Text('Namen speichern'),
        ),
      ] else
        TextButton(
          onPressed: _busy ? null : () => setState(() => _editName = true),
          child: const Text('Namen zur Zuordnung ändern'),
        ),
    ],
    _Step.blocked => [
      OutlinedButton.icon(
        onPressed: _busy ? null : _check,
        icon: const Icon(Icons.refresh),
        label: const Text('Status aktualisieren'),
      ),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, user = widget.controller.user!;
    final scheme = Theme.of(context).colorScheme;
    final step = _step(user);
    final title = switch (step) {
      _Step.blocked =>
        user.status == 'suspended' ? 'Zugang gesperrt' : 'Anfrage abgelehnt',
      _Step.name => 'Namen angeben',
      _Step.verify => 'E-Mail bestätigen',
      _Step.waiting => 'Freigabe ausstehend',
    };
    final message = switch (step) {
      _Step.blocked when user.status == 'suspended' =>
        'Die Theaterleitung hat deinen Zugang gesperrt. Wenn das ein '
            'Versehen ist, sprich sie bitte direkt an.',
      _Step.blocked =>
        'Die Theaterleitung hat deine Anfrage nicht freigegeben. Wenn du zum '
            'Ensemble gehörst, sprich sie bitte direkt an – sie kann deine '
            'Anfrage erneut prüfen.',
      _Step.name =>
        'Bitte gib deinen Namen an, damit die Theaterleitung dein Konto der richtigen Person im Ensemble zuordnen kann.',
      _Step.verify =>
        'Öffne den Link in deiner E-Mail und kehre zur App zurück. Die Bestätigung wird automatisch geprüft. Danach kann die Theaterleitung deinen Zugang freigeben.',
      _Step.waiting =>
        'Dein Konto ist erstellt. Die Theaterleitung ordnet dich einer Person zu und gibt deinen Zugang frei.',
    };
    final blocked = step == _Step.blocked;
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
                  backgroundColor: blocked
                      ? scheme.errorContainer
                      : scheme.tertiaryContainer,
                  child: Icon(
                    switch (step) {
                      _Step.blocked => Icons.lock_outline,
                      _Step.name => Icons.badge_outlined,
                      _Step.verify => Icons.mark_email_unread_outlined,
                      _Step.waiting => Icons.schedule,
                    },
                    color: blocked
                        ? scheme.onErrorContainer
                        : scheme.onTertiaryContainer,
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
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.needsRegistrationName ? 'Dein Konto' : user.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (!user.needsRegistrationName &&
                            user.status == 'pending') ...[
                          const SizedBox(height: 4),
                          const Text('Name zur Zuordnung'),
                        ],
                        const SizedBox(height: 6),
                        Text(user.email),
                        const SizedBox(height: 12),
                        StatePill(
                          user.emailVerified
                              ? 'E-Mail bestätigt'
                              : step == _Step.verify
                              ? 'Bestätigung ausstehend'
                              : 'Konto erstellt',
                          icon: user.emailVerified
                              ? Icons.check
                              : Icons.schedule,
                          color: user.emailVerified
                              ? StageTheme.green
                              : scheme.tertiary,
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.devices != null &&
                    Brand.pushEnabled &&
                    !c.isDemo &&
                    user.status == 'pending') ...[
                  const SizedBox(height: 12),
                  _pushNotice(context),
                ],
                const SizedBox(height: 20),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ),
                if (_info != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Semantics(liveRegion: true, child: Text(_info!)),
                  ),
                ..._actions(step, c),
                const SizedBox(height: 14),
                TextButton(
                  onPressed: _busy ? null : () => _run(c.logout),
                  child: const Text('Abmelden'),
                ),
                const PrivacyLinks(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
