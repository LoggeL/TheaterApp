import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../casting/ui/casting_screen.dart';
import '../../ensemble/admin/member_editor_screen.dart';
import '../domain/account_roster.dart';
import 'account_approval_screen.dart';

class AccountsAdminScreen extends StatefulWidget {
  const AccountsAdminScreen({
    super.key,
    required this.controller,
    this.initialView = 'people',
    this.initialFilter = 'all',
    this.initialQuery = '',
  });
  final AppController controller;
  final String initialView, initialFilter;

  /// Prefills the search, e.g. with a person's name from the member editor.
  final String initialQuery;
  @override
  State<AccountsAdminScreen> createState() => _AccountsAdminScreenState();
}

class _AccountsAdminScreenState extends State<AccountsAdminScreen> {
  // The last loaded roster stays visible while a reload runs.
  JsonMap? _data;
  Object? _loadError;
  bool _loading = false;
  late String _view = widget.initialView, _filter = widget.initialFilter;
  late String _query = widget.initialQuery;
  late final _search = TextEditingController(text: widget.initialQuery);
  final _reconsidering = <String>{};
  @override
  void initState() {
    super.initState();
    _loading = true;
    _fetch();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() {
    setState(() => _loading = true);
    return _fetch();
  }

  /// Loads the roster; a failure keeps the previous data and is reported.
  Future<void> _fetch() async {
    try {
      final data = await widget.controller.remote('/admin/accounts');
      if (!mounted) return;
      setState(() {
        _data = data;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_data != null) showProblem(context, e);
      setState(() => _loadError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _select(String view, [String filter = 'all']) {
    setState(() {
      _view = view;
      _filter = filter;
    });
  }

  Future<void> _refresh() async {
    await _load();
    if (mounted) await refreshWithFeedback(context, widget.controller);
  }

  Future<void> _approve(
    JsonMap a,
    AccountRoster roster, {
    int? personId,
  }) async {
    // The approval screen refreshes the selectable person list itself.
    await openPage(
      context,
      AccountApprovalScreen(
        controller: widget.controller,
        account: a,
        accounts: roster.accounts,
        initialPersonId: personId,
      ),
    );
    if (mounted) await _load();
  }

  /// Changes the account status; returns whether the server took it.
  Future<bool> _change(JsonMap a, String status) async {
    try {
      await widget.controller.performAction({
        'action': 'account.status',
        'uid': a['uid'],
        'version': a['version'],
        'status': status,
      });
      if (mounted) await _load();
      return true;
    } catch (e) {
      if (mounted) showProblem(context, e);
      return false;
    }
  }

  String _accountName(JsonMap a) =>
      textValue(a['name'], textValue(a['email'], 'dieses Konto'));

  Future<void> _suspend(JsonMap a) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Zugang sperren?',
      message:
          '${_accountName(a)} kann die App danach nicht mehr nutzen, bis du '
          'den Zugang wieder freigibst. Die Person im Ensemble bleibt erhalten.',
      confirmLabel: 'Sperren',
    );
    if (!confirmed || !mounted) return;
    if (!await _change(a, 'suspended') || !mounted) return;
    final uid = a['uid'];
    showDone(
      context,
      'Zugang von ${_accountName(a)} gesperrt.',
      actionLabel: 'Rückgängig',
      onAction: () {
        // The suspension raised the version; undo with the reloaded account.
        final fresh = jsonList(
          _data?['accounts'],
        ).map(jsonMap).where((x) => x['uid'] == uid).firstOrNull;
        if (fresh != null && mounted) _release(fresh);
      },
    );
  }

  Future<void> _release(JsonMap a) async {
    if (await _change(a, 'approved') && mounted) {
      showDone(context, 'Zugang von ${_accountName(a)} wieder freigegeben.');
    }
  }

  Future<void> _reconsider(JsonMap a) async {
    final uid = textValue(a['uid']);
    if (_reconsidering.contains(uid)) return;
    setState(() => _reconsidering.add(uid));
    try {
      await widget.controller.performAction({
        'action': 'account.reconsider',
        'uid': a['uid'],
        'version': a['version'],
      });
      if (!mounted) return;
      setState(() {
        _view = 'accounts';
        _filter = 'pending';
      });
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Erneute Prüfung vorgemerkt.')),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _reconsidering.remove(uid));
    }
  }

  Future<void> _chooseAccount(JsonMap m, AccountRoster roster) async {
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
                        ListTile(
                          title: Text(textValue(a['name'])),
                          subtitle: Text(textValue(a['email'])),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.pop(context, a),
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
    if (chosen != null && mounted) {
      await _approve(chosen, roster, personId: intValue(m['id']));
    }
  }

  Widget _status(JsonMap? a) => StatePill(
    accountStatus(a),
    color: a?['status'] == 'approved'
        ? Theme.of(context).colorScheme.secondary
        : a == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Theme.of(context).colorScheme.primary,
    icon: a?['status'] == 'approved'
        ? Icons.check
        : a == null
        ? Icons.link_off
        : Icons.info_outline,
  );
  Future<void> _delete(JsonMap a) async {
    final ok = await confirmDestructive(
      context,
      title: 'Konto löschen?',
      message:
          'Das Anmeldekonto ${textValue(a['email'], textValue(a['name']))} wird gelöscht. '
          'Die Person im Ensemble mit ihren Rückmeldungen und Besetzungen bleibt erhalten. '
          'Eine erneute Registrierung braucht wieder eine Freigabe.',
      confirmLabel: 'Löschen',
    );
    if (!ok || !mounted) return;
    try {
      await widget.controller.remote(
        '/admin/accounts/${Uri.encodeComponent(textValue(a['uid']))}',
        method: 'DELETE',
        body: {'version': a['version']},
      );
      if (!mounted) return;
      showDone(context, 'Konto gelöscht.');
      await _load();
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Widget _accountActions(JsonMap a, AccountRoster roster) {
    final primary = switch (a['status']) {
      'pending' => TextButton(
        onPressed: () => _approve(a, roster),
        child: const Text('Prüfen & verknüpfen'),
      ),
      'rejected' => TextButton.icon(
        onPressed: _reconsidering.contains(textValue(a['uid']))
            ? null
            : () => _reconsider(a),
        icon: const Icon(Icons.undo, size: 18),
        label: const Text('Erneut prüfen'),
      ),
      _ => null,
    };
    final menu = a['uid'] == widget.controller.user?.id
        ? null
        : PopupMenuButton<String>(
            tooltip: 'Zugang verwalten',
            onSelected: (s) => switch (s) {
              'delete' => _delete(a),
              'suspended' => _suspend(a),
              _ => _release(a),
            },
            itemBuilder: (_) => [
              if (a['status'] == 'approved')
                const PopupMenuItem(
                  value: 'suspended',
                  child: Text('Zugang sperren'),
                ),
              if (a['status'] == 'suspended')
                const PopupMenuItem(
                  value: 'approved',
                  child: Text('Wieder freigeben'),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Konto löschen'),
              ),
            ],
          );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [?primary, ?menu],
    );
  }

  /// Name, roles and activity live in the ensemble; edits show here after.
  Future<void> _editPerson(JsonMap m) async {
    await openPage(
      context,
      MemberEditorScreen(controller: widget.controller, member: m),
    );
    if (mounted) await _load();
  }

  Widget _person(JsonMap m, AccountRoster roster) {
    final a = roster.accountFor(intValue(m['id']));
    final roles = roster.rolesFor(intValue(m['id']));
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          textValue(m['name']),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (m['active'] == false)
          Text('Inaktiv', style: Theme.of(context).textTheme.bodySmall),
        if (jsonList(m['roleIds']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.controller.roleNames(
                jsonList(m['roleIds']).map((r) => r.toString()),
              ),
            ),
          ),
        if (textValue(m['roleName']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(textValue(m['roleName'])),
          ),
        for (final p in roster.productions.where(
          (p) => roles.any((r) => r['productionId'] == p['id']),
        ))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${textValue(p['title'])}\n${roles.where((r) => r['productionId'] == p['id']).map((r) => textValue(r['name'])).join(' · ')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
    final access = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _status(a),
        if (a != null) ...[
          const SizedBox(height: 10),
          SelectableText(textValue(a['email'], 'Keine E-Mail hinterlegt')),
          Text(
            '${a['role'] == 'admin' ? 'Admin' : 'Mitglied'} · ${textValue(a['provider']) == 'google.com'
                ? 'Google'
                : textValue(a['provider']) == 'password'
                ? 'E-Mail / Passwort'
                : textValue(a['provider'])}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          _accountActions(a, roster),
        ] else
          TextButton.icon(
            onPressed: m['active'] == false
                ? null
                : () => _chooseAccount(m, roster),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Konto verknüpfen'),
          ),
        TextButton.icon(
          key: ValueKey('account-person-edit-${m['id']}'),
          onPressed: () => _editPerson(m),
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('In Ensemble bearbeiten'),
        ),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, size) => size.maxWidth >= 620
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: details),
                    const SizedBox(width: 30),
                    Expanded(flex: 2, child: access),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [details, const SizedBox(height: 18), access],
                ),
        ),
      ),
    );
  }

  Widget _account(JsonMap a, AccountRoster roster) {
    final person = roster.memberFor(a['personId']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              textValue(a['name']),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            SelectableText(textValue(a['email'])),
            const SizedBox(height: 12),
            _status(a),
            const SizedBox(height: 8),
            Text(
              person == null
                  ? 'Noch keiner Person zugeordnet'
                  : 'Verknüpft mit ${textValue(person['name'])}',
            ),
            _accountActions(a, roster),
          ],
        ),
      ),
    );
  }

  Widget _role(JsonMap r, AccountRoster roster) {
    final person = roster.memberFor(r['personId']);
    final a = person == null ? null : roster.accountFor(intValue(person['id']));
    final production = roster.productions.firstWhere(
      (p) => p['id'] == r['productionId'],
    );
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 10,
        ),
        title: Text(textValue(r['name'])),
        subtitle: Text(
          '${textValue(r['productionTitle'])}\n${person == null
              ? textValue(r['actor']).isEmpty
                    ? 'Ohne Einzelbesetzung'
                    : 'Besetzung offen · Skript: ${textValue(r['actor'])}'
              : '${textValue(person['name'])}\n${a == null ? 'Kein Konto verknüpft' : '${textValue(a['email'])} · ${accountStatus(a)}'}'}',
        ),
        trailing: IconButton(
          tooltip: 'Besetzung bearbeiten',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () async {
            await openPage(
              context,
              CastingScreen(
                controller: widget.controller,
                productionId: textValue(production['id']),
              ),
            );
            if (mounted) await _load();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Konten & Verknüpfungen'),
        actions: [
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _loading && _data != null
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(minHeight: 3),
              )
            : null,
      ),
      body: widget.controller.user?.isAdmin != true
          ? const Center(child: Text('Admin-Zugang erforderlich.'))
          : Builder(
              builder: (context) {
                final data = _data;
                if (data == null && _loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (data == null) {
                  return EmptyState(
                    icon: Icons.cloud_off_outlined,
                    title: 'Konten nicht geladen',
                    message: userMessage(_loadError ?? 'unbekannt'),
                    action: OutlinedButton(
                      onPressed: _load,
                      child: const Text('Erneut versuchen'),
                    ),
                  );
                }
                final roster = AccountRoster(data);
                final people = roster.members
                    .where(
                      (m) =>
                          (_filter == 'all' ||
                              (roster.accountFor(intValue(m['id'])) != null) ==
                                  (_filter == 'linked')) &&
                          roster.personMatches(m, _query),
                    )
                    .toList();
                final accounts = roster.accounts
                    .where(
                      (a) =>
                          (_filter == 'all' || a['status'] == _filter) &&
                          roster.matches(_query, [
                            a['name'],
                            a['email'],
                            roster.memberFor(a['personId'])?['name'],
                          ]),
                    )
                    .toList();
                final roles = roster.roles
                    .where(
                      (r) =>
                          (_filter == 'all' ||
                              roster.memberFor(r['personId']) == null) &&
                          roster.matches(_query, [
                            r['name'],
                            r['actor'],
                            r['productionTitle'],
                            roster.memberFor(r['personId'])?['name'],
                            roster.accountFor(
                              intValue(r['personId']),
                            )?['email'],
                          ]),
                    )
                    .toList();
                final count = _view == 'people'
                    ? people.length
                    : _view == 'accounts'
                    ? accounts.length
                    : roles.length;
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1050),
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(22, 12, 22, 32),
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ActionChip(
                                label: Text('${roster.linkedCount} verknüpft'),
                                avatar: const Icon(Icons.link, size: 18),
                                onPressed: () => _select('people', 'linked'),
                              ),
                              ActionChip(
                                label: Text(
                                  '${roster.members.length - roster.linkedCount} ohne Konto',
                                ),
                                avatar: const Icon(Icons.link_off, size: 18),
                                onPressed: () => _select('people', 'unlinked'),
                              ),
                              ActionChip(
                                label: Text(
                                  '${roster.pendingCount} zur Freigabe',
                                ),
                                avatar: const Icon(
                                  Icons.person_add_outlined,
                                  size: 18,
                                ),
                                onPressed: () => _select('accounts', 'pending'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 22),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final entry in {
                                'people': 'Personen (${roster.members.length})',
                                'accounts':
                                    'Konten (${roster.accounts.length})',
                                'roles':
                                    'Drehbuchrollen (${roster.roles.length})',
                              }.entries)
                                ChoiceChip(
                                  label: Text(entry.value),
                                  selected: _view == entry.key,
                                  onSelected: (_) => _select(entry.key),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _search,
                            decoration: InputDecoration(
                              prefixIcon: const Icon(Icons.search),
                              hintText: 'Name, E-Mail oder Rolle suchen',
                              suffixIcon: _query.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Suche löschen',
                                      onPressed: () {
                                        _search.clear();
                                        setState(() => _query = '');
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                            ),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final entry
                                  in (_view == 'people'
                                          ? {
                                              'all': 'Alle Personen',
                                              'linked': 'Verknüpft',
                                              'unlinked': 'Ohne Konto',
                                            }
                                          : _view == 'accounts'
                                          ? {
                                              'all': 'Alle Konten',
                                              'pending': 'Ausstehend',
                                              'approved': 'Freigegeben',
                                              'suspended': 'Gesperrt',
                                              'rejected': 'Abgelehnt',
                                            }
                                          : {
                                              'all': 'Alle Drehbuchrollen',
                                              'unassigned': 'Ohne Besetzung',
                                            })
                                      .entries)
                                FilterChip(
                                  label: Text(entry.value),
                                  selected: _filter == entry.key,
                                  onSelected: (_) =>
                                      setState(() => _filter = entry.key),
                                ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text(switch (_view) {
                              'people' =>
                                count == 1 ? '1 Person' : '$count Personen',
                              'accounts' =>
                                count == 1 ? '1 Konto' : '$count Konten',
                              _ =>
                                count == 1
                                    ? '1 Drehbuchrolle'
                                    : '$count Drehbuchrollen',
                            }, style: Theme.of(context).textTheme.bodySmall),
                          ),
                          if (count == 0)
                            EmptyState(
                              icon: Icons.search_off,
                              title:
                                  _query.isEmpty &&
                                      _view == 'accounts' &&
                                      _filter == 'pending'
                                  ? 'Keine offenen Freigaben'
                                  : 'Keine Treffer',
                              message:
                                  _query.isEmpty &&
                                      _view == 'accounts' &&
                                      _filter == 'pending'
                                  ? 'Neue Registrierungen erscheinen hier.'
                                  : 'Passe die Suche oder den Filter an.',
                            ),
                          if (_view == 'people')
                            for (final m in people)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _person(m, roster),
                              ),
                          if (_view == 'accounts')
                            for (final a in accounts)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _account(a, roster),
                              ),
                          if (_view == 'roles')
                            for (final r in roles)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _role(r, roster),
                              ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    ),
  );
}
