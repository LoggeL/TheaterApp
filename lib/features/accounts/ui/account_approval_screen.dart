import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../auth/ui/sign_in_providers.dart';
import '../../casting/domain/casting.dart';
import '../../ensemble/admin/member_editor_screen.dart';

/// Where an account's name comes from when the person did not supply one,
/// e.g. "Google-Konto"; "Anmeldekonto" for unknown providers and e-mail.
String accountNameSource(Object? provider) {
  final name = provider == 'password' ? null : providerNames[provider];
  return name == null ? 'Anmeldekonto' : '$name-Konto';
}

/// People who may be linked to [account], best name match first: the same
/// name, then a similar one, then everyone else alphabetically.
List<TheaterMember> rankApprovalCandidates(
  String accountName,
  Iterable<TheaterMember> people,
) {
  final scored = [
    for (final m in people)
      (member: m, score: nameMatchScore(accountName, m.name)),
  ];
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0
        ? byScore
        : normalizeName(a.member.name).compareTo(normalizeName(b.member.name));
  });
  return [for (final s in scored) s.member];
}

/// The only person carrying exactly [accountName], if there is one.
TheaterMember? uniqueExactMatch(
  String accountName,
  Iterable<TheaterMember> people,
) {
  final exact = people
      .where((m) => nameMatchScore(accountName, m.name) == 2)
      .toList();
  return exact.length == 1 ? exact.single : null;
}

class AccountApprovalScreen extends StatefulWidget {
  const AccountApprovalScreen({
    super.key,
    required this.controller,
    required this.account,
    required this.accounts,
    this.initialPersonId,
  });
  final AppController controller;
  final JsonMap account;
  final List<JsonMap> accounts;
  final int? initialPersonId;
  @override
  State<AccountApprovalScreen> createState() => _AccountApprovalScreenState();
}

class _AccountApprovalScreenState extends State<AccountApprovalScreen> {
  int? _person;
  String _search = '', _role = 'member';
  bool _busy = false;

  /// Set once the member list is current; the suggestion is chosen then.
  bool _suggested = false;
  @override
  void initState() {
    super.initState();
    _person = widget.initialPersonId;
    _suggested = _person != null;
    // Refreshing notifies listeners, which must not happen during build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshPeople());
  }

  String get _accountName => textValue(widget.account['name']);

  Set<int> get _linked => widget.accounts
      .where((x) => x['personId'] != null)
      .map((x) => intValue(x['personId']))
      .toSet();

  /// Loads the current person list, then preselects a unique exact match.
  Future<void> _refreshPeople() async {
    try {
      await widget.controller.refresh();
    } catch (_) {
      // The cached list stays usable; refresh errors show in the banner.
    }
    if (!mounted || _suggested) return;
    final match = _suggestion;
    setState(() {
      _suggested = true;
      _person ??= match?.id;
    });
  }

  TheaterMember? get _suggestion => uniqueExactMatch(
    _accountName,
    widget.controller.members.where((m) => m.active && !_linked.contains(m.id)),
  );

  Future<void> _createPerson() async {
    final id = await openPage<int>(
      context,
      MemberEditorScreen(
        controller: widget.controller,
        initialName: _accountName,
      ),
    );
    if (!mounted) return;
    setState(() {
      if (id != null) _person = id;
    });
  }

  Future<void> _save(bool approve) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!approve) {
        final confirmed = await confirmDestructive(
          context,
          title: 'Anfrage ablehnen?',
          message:
              'Die Anfrage von ${textValue(widget.account['name'])} '
              '(${textValue(widget.account['email'])}) wird abgelehnt. '
              'Das Konto erhält keinen Zugang. Du kannst es später in der '
              'Kontenverwaltung erneut prüfen.',
          confirmLabel: 'Ablehnen',
          scrollable: true,
        );
        if (!confirmed || !mounted) return;
      }
      // The route pops before the confirmation shows.
      final messenger = ScaffoldMessenger.of(context);
      final outcome = await widget.controller.performAction(
        approve
            ? {
                'action': 'account.approve',
                'uid': widget.account['uid'],
                'version': widget.account['version'],
                'personId': _person,
                'role': _role,
              }
            : {
                'action': 'account.status',
                'uid': widget.account['uid'],
                'version': widget.account['version'],
                'status': 'rejected',
              },
      );
      if (!mounted) return;
      Navigator.pop(context);
      final done = approve
          ? 'Konto von $_accountName freigegeben.'
          : 'Anfrage von $_accountName abgelehnt.';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            outcomeText(
              outcome,
              done: done,
              queued: '$done Wird bei Verbindung gesendet.',
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Hint and roles of an assignable person; null when both are empty, so
  /// the tile has no blank second line.
  Widget? _subtitle(TheaterMember m) {
    final text = [
      if (nameMatchScore(_accountName, m.name) == 1) 'Ähnlicher Name',
      widget.controller.roleNames(m.roleIds),
    ].where((s) => s.isNotEmpty).join(' · ');
    return text.isEmpty ? null : Text(text);
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Konto freigeben',
    children: (context) {
      final a = widget.account;
      final linked = _linked;
      final needle = normalizeName(_search);
      final ranked = rankApprovalCandidates(
        _accountName,
        widget.controller.members.where(
          (m) => m.active && normalizeName(m.name).contains(needle),
        ),
      );
      final free = ranked.where((m) => !linked.contains(m.id)).toList();
      final taken = ranked.where((m) => linked.contains(m.id)).toList();
      final suggestion = _suggestion;
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  textValue(a['name']),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  a['nameProvided'] == false
                      ? 'Name laut ${accountNameSource(a['provider'])}'
                      : 'Name zur Zuordnung des Kontos',
                ),
                const SizedBox(height: 8),
                Text(textValue(a['email'])),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatePill(
                      a['emailVerified'] == true
                          ? 'E-Mail bestätigt'
                          : 'Identität prüfen',
                      icon: a['emailVerified'] == true
                          ? Icons.check
                          : Icons.info_outline,
                    ),
                    const StatePill(
                      'Ausstehend',
                      color: Color(0xFFA25B06),
                      icon: Icons.schedule,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('Person zuordnen'),
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Person suchen',
          ),
          onChanged: (s) => setState(() => _search = s),
        ),
        const SizedBox(height: 14),
        if (free.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Keine freie Person gefunden.'),
          ),
        RadioGroup<int>(
          groupValue: _person,
          onChanged: (id) {
            if (!_busy) setState(() => _person = id);
          },
          child: Column(
            children: [
              for (final m in free)
                Card(
                  child: RadioListTile<int>(
                    value: m.id,
                    title: Text(m.name),
                    subtitle: _subtitle(m),
                    secondary: m.id == suggestion?.id
                        ? const StatePill('Vorschlag', icon: Icons.auto_awesome)
                        : null,
                  ),
                ),
            ],
          ),
        ),
        if (taken.isNotEmpty)
          ExpansionTile(
            key: const ValueKey('approval-linked-people'),
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text('Bereits verknüpft (${taken.length})'),
            children: [
              for (final m in taken)
                ListTile(
                  enabled: false,
                  leading: const Icon(Icons.link),
                  title: Text(m.name),
                  subtitle: const Text('Bereits mit einem Konto verknüpft'),
                ),
            ],
          ),
        TextButton.icon(
          onPressed: _busy ? null : _createPerson,
          icon: const Icon(Icons.person_add_outlined),
          label: const Text('Person anlegen'),
        ),
        const SectionTitle('Zugriff'),
        DropdownButtonFormField<String>(
          initialValue: _role,
          decoration: const InputDecoration(labelText: 'Berechtigung'),
          items: const [
            DropdownMenuItem(value: 'member', child: Text('Mitglied')),
            DropdownMenuItem(value: 'admin', child: Text('Admin')),
          ],
          onChanged: (s) => setState(() => _role = s!),
        ),
        const SizedBox(height: 28),
        if (a['identityReady'] != true)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('Die E-Mail-Adresse muss zuerst bestätigt werden.'),
          ),
        if (a['nameProvided'] == false)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              'Der Name stammt vom ${accountNameSource(a['provider'])} und '
              'wurde nicht selbst angegeben. Bitte prüfe die Zuordnung '
              'anhand der E-Mail-Adresse.',
            ),
          ),
        FilledButton(
          onPressed: _busy || _person == null || a['identityReady'] != true
              ? null
              : () => _save(true),
          child: const Text('Verknüpfen & freigeben'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _busy ? null : () => _save(false),
          child: const Text('Anfrage ablehnen'),
        ),
      ];
    },
  );
}
