import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../auth/ui/sign_in_providers.dart';
import '../data/accounts_api.dart';
import '../domain/account_roster.dart';
import 'account_approval_screen.dart';

// The access actions of one account, shared by "Personen & Zugänge" and the
// person editor. Each one that changes something resolves to true, so the
// caller reloads its roster.

String _accountName(JsonMap a) =>
    textValue(a['name'], textValue(a['email'], 'dieses Konto'));

/// Linked accounts whose rights can be edited: approved ones (role and
/// rights) and suspended members (their resting rights).
bool accountRightsEditable(AppController c, JsonMap a) {
  if (a['personId'] == null) return false;
  final rights = c.supports('accountPermissions');
  return switch (a['status']) {
    'approved' => c.supports('accountRole') || (rights && a['role'] != 'admin'),
    'suspended' => rights && a['role'] != 'admin',
    _ => false,
  };
}

/// The server releases only linked accounts with a confirmed identity; a
/// suspended registration without a person would always be refused.
bool accountReleasable(JsonMap a) =>
    a['status'] == 'suspended' &&
    a['personId'] != null &&
    a['identityReady'] == true;

/// Whether [e] is the signed-in admin's own person or account; its access
/// is changed by another admin.
bool isOwnAccess(AppController c, AccessEntry e) {
  final user = c.user;
  if (user == null) return false;
  return (e.account != null && e.uid == user.id) ||
      (e.personId != null && e.personId == user.personId);
}

final _date = DateFormat('d.M.yyyy');
String? _dateOf(Object? value) {
  final at = DateTime.tryParse(textValue(value));
  return at == null ? null : _date.format(at.toLocal());
}

/// "Google · bestätigt · zuletzt aktiv 3.10.2026 · freigegeben 1.9.2026".
String accountLoginLine(JsonMap a) {
  final provider = textValue(a['provider']);
  final seen = _dateOf(a['lastSeenAt']), approved = _dateOf(a['approvedAt']);
  return [
    if (provider.isNotEmpty) providerNames[provider] ?? provider,
    if (a['emailVerified'] == true) 'bestätigt',
    if (a['emailVerified'] == false) 'unbestätigt',
    if (seen != null) 'zuletzt aktiv $seen',
    if (approved != null && a['status'] == 'approved') 'freigegeben $approved',
  ].join(' · ');
}

/// Opens the approval of the registration [a], optionally for [personId].
/// The approval screen refreshes the selectable person list itself.
Future<void> openAccountApproval(
  BuildContext context,
  AppController c,
  JsonMap a,
  AccountRoster roster, {
  int? personId,
}) => openPage(
  context,
  AccountApprovalScreen(
    controller: c,
    account: a,
    accounts: roster.accounts,
    initialPersonId: personId,
  ),
);

/// Picks a waiting registration for [m] and opens its approval for them;
/// unconfirmed ones show disabled, since they cannot be approved yet.
/// Resolves to true when an approval was opened.
Future<bool> linkAccountTo(
  BuildContext context,
  AppController c,
  JsonMap m,
  AccountRoster roster,
) async {
  final pending = roster.accounts
      .where((a) => a['status'] == 'pending' && a['personId'] == null)
      .toList();
  final chosen = await showModalBottomSheet<JsonMap>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Konto für ${textValue(m['name'])}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              if (pending.isEmpty)
                const Text(
                  'Es liegt keine Registrierung vor. Die Person kann sich mit ihrer eigenen E-Mail-Adresse oder Google anmelden.',
                ),
              Expanded(
                child: ListView(
                  children: [
                    for (final a in pending)
                      a['identityReady'] == true
                          ? ListTile(
                              title: Text(textValue(a['name'])),
                              subtitle: Text(textValue(a['email'])),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => Navigator.pop(context, a),
                            )
                          : ListTile(
                              enabled: false,
                              title: Text(textValue(a['name'])),
                              subtitle: Text(
                                '${textValue(a['email'])} · E-Mail unbestätigt',
                              ),
                            ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (chosen == null || !context.mounted) return false;
  await openAccountApproval(
    context,
    c,
    chosen,
    roster,
    personId: intValue(m['id']),
  );
  return true;
}

/// Changes the account status; returns whether the server took it.
Future<bool> _changeStatus(
  ScaffoldMessengerState messenger,
  AppController c,
  JsonMap a,
  String status,
) async {
  try {
    await c.performAction({
      'action': 'account.status',
      'uid': a['uid'],
      'version': a['version'],
      'status': status,
    });
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(userMessage(e))));
    return false;
  }
}

/// Suspends [a] after a confirmation. The SnackBar offers to undo it with
/// the reloaded account, since the suspension raised its version; [onUndone]
/// lets the caller reload once more.
Future<bool> suspendAccount(
  BuildContext context,
  AppController c,
  JsonMap a, {
  required VoidCallback onUndone,
}) async {
  final confirmed = await confirmDestructive(
    context,
    title: 'Zugang sperren?',
    message:
        '${_accountName(a)} kann die App danach nicht mehr nutzen, bis du '
        'den Zugang wieder freigibst. Die Person im Ensemble bleibt erhalten.',
    confirmLabel: 'Sperren',
  );
  if (!confirmed || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  if (!await _changeStatus(messenger, c, a, 'suspended')) return false;
  final uid = a['uid'];
  messenger.showSnackBar(
    SnackBar(
      content: Text('Zugang von ${_accountName(a)} gesperrt.'),
      action: SnackBarAction(
        label: 'Rückgängig',
        onPressed: () async {
          try {
            final fresh = (await fetchRoster(
              c,
            )).accounts.where((x) => x['uid'] == uid).firstOrNull;
            if (fresh != null && await _release(messenger, c, fresh)) {
              onUndone();
            }
          } catch (e) {
            messenger.showSnackBar(SnackBar(content: Text(userMessage(e))));
          }
        },
      ),
    ),
  );
  return true;
}

Future<bool> _release(
  ScaffoldMessengerState messenger,
  AppController c,
  JsonMap a,
) async {
  if (!await _changeStatus(messenger, c, a, 'approved')) return false;
  messenger.showSnackBar(
    SnackBar(
      content: Text('Zugang von ${_accountName(a)} wieder freigegeben.'),
    ),
  );
  return true;
}

/// Releases the suspended account [a] again.
Future<bool> releaseAccount(BuildContext context, AppController c, JsonMap a) =>
    _release(ScaffoldMessenger.of(context), c, a);

/// Deletes the login [a] after a confirmation; the person stays.
Future<bool> deleteAccount(
  BuildContext context,
  AppController c,
  JsonMap a,
) async {
  final ok = await confirmDestructive(
    context,
    title: 'Konto löschen?',
    message:
        'Das Anmeldekonto ${textValue(a['email'], textValue(a['name']))} wird gelöscht. '
        'Die Person im Ensemble mit ihren Rückmeldungen und Besetzungen bleibt erhalten. '
        'Eine erneute Registrierung braucht wieder eine Freigabe.',
    confirmLabel: 'Löschen',
  );
  if (!ok || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await c.remote(
      '/admin/accounts/${Uri.encodeComponent(textValue(a['uid']))}',
      method: 'DELETE',
      body: {'version': a['version']},
    );
    messenger.showSnackBar(const SnackBar(content: Text('Konto gelöscht.')));
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(userMessage(e))));
    return false;
  }
}
