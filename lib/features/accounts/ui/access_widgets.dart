import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/account_permissions.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/state_pill.dart';
import '../domain/account_roster.dart';

/// The access status of a person or account (see [accessStatusLabel]), with
/// the same colour and icon in every admin list.
class AccessStatusPill extends StatelessWidget {
  const AccessStatusPill(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (status) {
      'approved' => (scheme.secondary, Icons.check_circle),
      'inactive' => (scheme.onSurfaceVariant, Icons.pause_circle),
      'waiting' => (scheme.primary, Icons.hourglass_top),
      'unverified' => (scheme.onSurfaceVariant, Icons.mark_email_unread),
      'suspended' => (scheme.error, Icons.block),
      'rejected' => (scheme.error, Icons.cancel),
      'unassigned' => (scheme.primary, Icons.person_off),
      _ => (scheme.onSurfaceVariant, Icons.link_off),
    };
    return StatePill(accessStatusLabel(status), color: color, icon: icon);
  }
}

/// Short text of [rights], e.g. "Admin" or "Termine verwalten · Regie:
/// Sommerstück"; "Mitglied" for a plain account, empty without an account
/// and direction. The account's rights of a suspended account are marked
/// "(ruht)", like the pills.
String rightsSummary(AccessRights rights) {
  String resting(String label) => rights.resting ? '$label (ruht)' : label;
  return [
    if (rights.admin) resting('Admin'),
    for (final p in rights.permissions)
      resting(accountPermissionLabels[p]?.$1 ?? p),
    for (final title in rights.directorOf) 'Regie: $title',
    if (rights.memberOnly) resting('Mitglied'),
  ].join(' · ');
}

/// The rights of an entry as pills: "Admin", each granted right, "Regie:
/// Stück" and "Mitglied" when there is nothing else. Rights of a suspended
/// account are muted and marked as resting, since they return when it is
/// released. [compact] shows only the account's role and rights.
class RightsPills extends StatelessWidget {
  const RightsPills(this.rights, {super.key, this.compact = false});
  final AccessRights rights;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    String resting(String label) => rights.resting ? '$label · ruht' : label;
    final pills = [
      if (rights.admin)
        StatePill(
          resting('Admin'),
          color: rights.resting ? muted : StageTheme.violet,
          icon: Icons.admin_panel_settings_outlined,
        ),
      for (final p in rights.permissions)
        StatePill(
          resting(accountPermissionLabels[p]?.$1 ?? p),
          color: rights.resting ? muted : StageTheme.green,
          icon: Icons.edit_calendar_outlined,
        ),
      if (!compact) ...[
        for (final title in rights.directorOf)
          StatePill(
            'Regie: $title',
            color: StageTheme.orange,
            icon: Icons.theater_comedy_outlined,
          ),
        if (rights.memberOnly) StatePill(resting('Mitglied'), color: muted),
      ],
    ];
    if (pills.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 6, children: pills);
  }
}

/// Opens the rights editor of the linked [account] named [name]. Resolves
/// to true when a change was sent, also when the server refused it, so the
/// caller reloads the current rights.
Future<bool> showAccountRightsSheet(
  BuildContext context, {
  required AppController controller,
  required JsonMap account,
  required String name,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AccountRightsSheet(
        controller: controller,
        account: account,
        name: name,
      ),
    ) ==
    true;

/// Edits the role and rights of one account in one place: "Admin" holds
/// every right; below it each right of [accountPermissionLabels]. Saving
/// confirms once and then sends `account.role` (with the kept rights when
/// an admin becomes a member) if the role changed, else
/// `account.permissions`. It needs a connection and sends past the outbox:
/// offline, saving is disabled with a note in the sheet.
class AccountRightsSheet extends StatefulWidget {
  const AccountRightsSheet({
    super.key,
    required this.controller,
    required this.account,
    required this.name,
  });
  final AppController controller;
  final JsonMap account;
  final String name;
  @override
  State<AccountRightsSheet> createState() => _AccountRightsSheetState();
}

class _AccountRightsSheetState extends State<AccountRightsSheet> {
  late final bool _wasAdmin = widget.account['role'] == 'admin';
  late final Set<String> _before = {
    for (final p in jsonList(widget.account['permissions']))
      if (accountPermissionLabels.containsKey(p)) p.toString(),
  };
  late bool _admin = _wasAdmin;
  late final Set<String> _selected = {..._before};
  bool _busy = false;

  bool get _approved => widget.account['status'] == 'approved';

  /// Admin rights need an approved account and server support.
  bool get _roleEditable =>
      _approved && widget.controller.supports('accountRole');
  bool get _permissionsEditable =>
      widget.controller.supports('accountPermissions');

  bool get _changed =>
      _admin != _wasAdmin ||
      (!_admin &&
          (_selected.length != _before.length ||
              !_selected.containsAll(_before)));

  Future<bool> _confirm() {
    final name = widget.name;
    if (_admin && !_wasAdmin) {
      return confirmAction(
        context,
        title: 'Admin-Rechte geben?',
        message:
            '$name kann danach Termine, Mitteilungen, Produktionen, '
            'Personen und Konten verwalten und anderen Admin-Rechte geben '
            'oder entziehen. Die Änderung gilt in der App ab der nächsten '
            'Aktualisierung.',
        confirmLabel: 'Admin-Rechte geben',
      );
    }
    if (!_admin && _wasAdmin) {
      return confirmDestructive(
        context,
        title: 'Admin-Rechte entziehen?',
        message: _permissionsEditable && _selected.contains(eventsPermission)
            ? '$name behält den Zugang als Mitglied und verliert den '
                  'Admin-Bereich, kann aber weiterhin alle Termine '
                  'verwalten. Die Änderung gilt in der App ab der '
                  'nächsten Aktualisierung.'
            : '$name behält den Zugang als Mitglied, kann die Verwaltung '
                  'aber nicht mehr nutzen. Die Änderung gilt in der App ab '
                  'der nächsten Aktualisierung.',
        confirmLabel: 'Entziehen',
      );
    }
    final gained = _selected.difference(_before),
        lost = _before.difference(_selected);
    if (gained.length == 1 && lost.isEmpty && gained.single == 'events') {
      return confirmAction(
        context,
        title: 'Termine verwalten erlauben?',
        message:
            '$name kann danach alle Termine, Serien und Terminfinder '
            'verwalten und Rückmeldungen mit Absagegründen sehen.',
        confirmLabel: 'Erlauben',
      );
    }
    if (lost.length == 1 && gained.isEmpty && lost.single == 'events') {
      return confirmDestructive(
        context,
        title: 'Termine verwalten entziehen?',
        message:
            '$name kann danach keine Termine mehr anlegen oder ändern '
            'und sieht keine Rückmeldungen anderer mehr.',
        confirmLabel: 'Entziehen',
      );
    }
    String labels(Set<String> ps) =>
        ps.map((p) => '„${accountPermissionLabels[p]?.$1 ?? p}“').join(', ');
    return confirmAction(
      context,
      title: 'Rechte ändern?',
      message: [
        if (gained.isNotEmpty) '$name erhält ${labels(gained)}.',
        if (lost.isNotEmpty) '$name verliert ${labels(lost)}.',
      ].join(' '),
      confirmLabel: 'Speichern',
    );
  }

  String get _doneText {
    final name = widget.name;
    if (_admin != _wasAdmin) {
      return _admin ? '$name ist jetzt Admin.' : '$name ist jetzt Mitglied.';
    }
    if (_selected.contains(eventsPermission) &&
        !_before.contains(eventsPermission)) {
      return '$name darf jetzt Termine verwalten.';
    }
    if (!_selected.contains(eventsPermission) &&
        _before.contains(eventsPermission)) {
      return '$name verwaltet keine Termine mehr.';
    }
    return 'Rechte von $name gespeichert.';
  }

  Future<void> _save() async {
    if (_busy || !_changed || widget.controller.isOffline) return;
    if (!await _confirm() || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final a = widget.account;
    final permissions = [
      for (final p in accountPermissionLabels.keys)
        if (_selected.contains(p)) p,
    ];
    final body = _admin != _wasAdmin
        ? {
            'action': 'account.role',
            'uid': a['uid'],
            'version': a['version'],
            'role': _admin ? 'admin' : 'member',
            // Older servers without rights only know the role.
            if (!_admin && _permissionsEditable) 'permissions': permissions,
          }
        : {
            'action': 'account.permissions',
            'uid': a['uid'],
            'version': a['version'],
            'permissions': permissions,
          };
    String text;
    try {
      // Never through the outbox: a change waiting offline would apply
      // later unseen and carry this version into a second edit.
      await widget.controller.performActionOnline(body);
      text = _doneText;
    } catch (e) {
      text = e is ApiException && e.retryable
          // The request may have arrived before the connection broke.
          ? 'Keine Antwort vom Server – ob die Rechte geändert wurden, ist '
                'offen. Die Liste wurde neu geladen.'
          : userMessage(e);
    }
    // The caller reloads the list in every case, also after a refusal.
    if (mounted) Navigator.pop(context, true);
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suspended = widget.account['status'] == 'suspended';
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rechte von ${widget.name}',
                style: theme.textTheme.titleLarge,
              ),
              if (suspended)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Der Zugang ist gesperrt. Die Rechte ruhen und gelten nach '
                    'einer erneuten Freigabe wieder.',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const ValueKey('rights-admin'),
                contentPadding: EdgeInsets.zero,
                value: _admin,
                onChanged: _busy || !_roleEditable
                    ? null
                    : (v) => setState(() {
                        _admin = v;
                        // Leaving admin keeps the rights the switch showed;
                        // a former admin keeps managing events by default.
                        if (!v) {
                          _selected
                            ..clear()
                            ..addAll(
                              _wasAdmin && _permissionsEditable
                                  ? accountPermissionLabels.keys
                                  : _before,
                            );
                        }
                      }),
                title: const Text('Admin'),
                subtitle: Text(
                  _roleEditable
                      ? 'Alle Rechte, auch Konten, Mitteilungen, Produktionen '
                            'und Termine'
                      : 'Admin-Rechte gibt es nur für freigegebene Zugänge',
                ),
              ),
              if (_permissionsEditable)
                for (final MapEntry(key: p, value: (label, description))
                    in accountPermissionLabels.entries)
                  CheckboxListTile(
                    key: ValueKey('rights-permission-$p'),
                    contentPadding: EdgeInsets.zero,
                    value: _admin || _selected.contains(p),
                    onChanged: _busy || _admin
                        ? null
                        : (v) => setState(
                            () => v == true
                                ? _selected.add(p)
                                : _selected.remove(p),
                          ),
                    title: Text(label),
                    subtitle: Text(
                      _admin ? 'Admins haben alle Rechte' : description,
                    ),
                  ),
              // Inside the sheet: a SnackBar would show beneath it.
              ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final offline = widget.controller.isOffline;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (offline)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Nur mit Verbindung: Rechte lassen sich offline '
                            'nicht ändern.',
                            key: const ValueKey('rights-offline'),
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => Navigator.pop(context, false),
                            child: const Text('Abbrechen'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _busy || !_changed || offline
                                ? null
                                : _save,
                            child: const Text('Speichern'),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
