import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/widgets/page_header.dart';
import '../data/accounts_api.dart';
import '../domain/account_roster.dart';
import 'access_actions.dart';
import 'access_widgets.dart';

/// "App-Zugang" of the person editor: status, rights and login of the
/// person's account with every access action, or "Konto verknüpfen" when
/// the person has none. Loads the account list itself; admins only.
class PersonAccessSection extends StatefulWidget {
  const PersonAccessSection({
    super.key,
    required this.controller,
    required this.member,
  });
  final AppController controller;
  final JsonMap member;
  @override
  State<PersonAccessSection> createState() => _PersonAccessSectionState();
}

class _PersonAccessSectionState extends State<PersonAccessSection> {
  /// The last loaded account list; it stays while a reload runs.
  AccountRoster? _roster;
  bool _loading = true;

  int get _personId => intValue(widget.member['id']);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final roster = await fetchRoster(widget.controller);
      if (mounted) setState(() => _roster = roster);
    } catch (_) {
      // Without the list the section offers to try again.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Runs [action] and reloads when it changed something.
  Future<void> _run(Future<bool> Function() action) async {
    if (await action() && mounted) await _load();
  }

  Widget _body(BuildContext context, AccountRoster roster) {
    final theme = Theme.of(context);
    final c = widget.controller;
    final entry = AccessEntry(
      member: roster.memberFor(_personId) ?? widget.member,
      account: roster.accountFor(_personId),
    );
    final a = entry.account, status = accessStatus(entry);
    final own = isOwnAccess(c, entry);
    final login = a == null ? '' : accountLoginLine(a);
    final actions = <Widget>[
      if (status == 'noAccount' && !entry.inactive)
        FilledButton.tonalIcon(
          key: const ValueKey('access-link'),
          onPressed: () =>
              _run(() => linkAccountTo(context, c, entry.member!, roster)),
          icon: const Icon(Icons.link),
          label: const Text('Konto verknüpfen'),
        ),
      if (status == 'waiting')
        FilledButton.tonal(
          key: const ValueKey('access-approve'),
          onPressed: () => _run(() async {
            await openAccountApproval(context, c, a!, roster);
            return true;
          }),
          child: const Text('Prüfen & verknüpfen'),
        ),
      if (!own && a != null && accountRightsEditable(c, a))
        OutlinedButton.icon(
          key: const ValueKey('access-rights'),
          onPressed: () => _run(
            () => showAccountRightsSheet(
              context,
              controller: c,
              account: a,
              name: entry.name,
            ),
          ),
          icon: const Icon(Icons.admin_panel_settings_outlined),
          label: const Text('Rechte bearbeiten…'),
        ),
      if (!own && a?['status'] == 'approved')
        OutlinedButton.icon(
          key: const ValueKey('access-suspend'),
          onPressed: () => _run(
            () => suspendAccount(
              context,
              c,
              a!,
              onUndone: () {
                if (mounted) _load();
              },
            ),
          ),
          icon: const Icon(Icons.block),
          label: const Text('Zugang sperren'),
        ),
      if (!own && a != null && accountReleasable(a))
        OutlinedButton.icon(
          key: const ValueKey('access-release'),
          onPressed: () => _run(() => releaseAccount(context, c, a)),
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Wieder freigeben'),
        ),
      if (!own && a != null)
        TextButton.icon(
          key: const ValueKey('access-delete'),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          onPressed: () => _run(() => deleteAccount(context, c, a)),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Konto löschen'),
        ),
    ];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            AccessStatusPill(status),
            // The server denies an inactive person any access, whatever the
            // account says.
            if (entry.inactive) const AccessStatusPill('inactive'),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: RightsPills(roster.rights(entry)),
        ),
        const SizedBox(height: 10),
        if (a == null)
          Text(
            entry.inactive
                ? 'Kein App-Konto verknüpft. Aktiviere die Person, um ein '
                      'Konto zu verknüpfen.'
                : 'Kein App-Konto verknüpft. Sobald sich die Person '
                      'registriert, verknüpfst du ihr Konto hier.',
            style: muted,
          )
        else ...[
          SelectableText(textValue(a['email'], 'Keine E-Mail hinterlegt')),
          if (login.isNotEmpty) Text(login, style: muted),
          if (status == 'unverified')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Wartet auf E-Mail-Bestätigung', style: muted),
            ),
        ],
        if (own)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Deinen eigenen Zugang kann nur ein anderer Admin ändern.',
              style: muted,
            ),
          ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final roster = _roster;
    return Column(
      key: const ValueKey('member-editor-account'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'App-Zugang',
          trailing: _loading && roster != null
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        if (roster != null)
          _body(context, roster)
        else if (_loading)
          const LinearProgressIndicator()
        else
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                'Der App-Zugang lässt sich gerade nicht laden.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              TextButton(
                onPressed: _load,
                child: const Text('Erneut versuchen'),
              ),
            ],
          ),
      ],
    );
  }
}
