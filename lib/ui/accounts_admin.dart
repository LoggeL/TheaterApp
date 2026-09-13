import 'package:flutter/material.dart';
import '../core/account_roster.dart';
import '../core/app_controller.dart';
import '../core/identity.dart';
import '../core/models.dart';
import 'admin.dart';
import 'theme.dart';

class AccountsAdminScreen extends StatefulWidget {
  const AccountsAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<AccountsAdminScreen> createState() => _AccountsAdminScreenState();
}

class _AccountsAdminScreenState extends State<AccountsAdminScreen> {
  late Future<JsonMap> _data;
  String _view = 'people', _filter = 'all', _query = '';
  final _search = TextEditingController();
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _load() {
    _data = widget.controller.remote('/admin/accounts');
  }

  void _select(String view, [String filter = 'all']) {
    setState(() {
      _view = view;
      _filter = filter;
    });
  }

  Future<void> _refresh() async {
    setState(_load);
    await _data;
    await widget.controller.refresh();
  }

  Future<void> _approve(
    JsonMap a,
    AccountRoster roster, {
    int? personId,
  }) async {
    // Refresh the selectable person list as well as the admin-only account list.
    try {
      await widget.controller.refresh();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AccountApprovalScreen(
            controller: widget.controller,
            account: a,
            accounts: roster.accounts,
            initialPersonId: personId,
          ),
        ),
      );
      if (mounted) setState(_load);
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<void> _change(JsonMap a, String status) async {
    try {
      await widget.controller.performAction({
        'action': 'account.status',
        'uid': a['uid'],
        'version': a['version'],
        'status': status,
      });
      if (mounted) setState(_load);
    } catch (e) {
      if (mounted) showProblem(context, e);
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
  Widget _accountActions(JsonMap a, AccountRoster roster) {
    if (a['status'] == 'pending') {
      return TextButton(
        onPressed: () => _approve(a, roster),
        child: const Text('Prüfen & verknüpfen'),
      );
    }
    if (a['uid'] == widget.controller.user?.id ||
        !['approved', 'suspended'].contains(a['status'])) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<String>(
      tooltip: 'Zugang verwalten',
      onSelected: (s) => _change(a, s),
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
      ],
    );
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
        Text(
          '${textValue(m['group'])}${m['active'] == false ? ' · Inaktiv' : ''}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
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
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProductionEditorScreen(
                  controller: widget.controller,
                  production: production,
                ),
              ),
            );
            if (mounted) setState(_load);
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
            onPressed: () => _refresh().catchError((Object e) {
              if (context.mounted) showProblem(context, e);
            }),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: widget.controller.user?.isAdmin != true
          ? const Center(child: Text('Admin-Zugang erforderlich.'))
          : FutureBuilder<JsonMap>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return EmptyState(
                    icon: Icons.cloud_off_outlined,
                    title: 'Konten nicht geladen',
                    message: identityError(snapshot.error!),
                    action: OutlinedButton(
                      onPressed: () => setState(_load),
                      child: const Text('Erneut versuchen'),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final roster = AccountRoster(snapshot.data!);
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
                                'roles': 'Rollen (${roster.roles.length})',
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
                                              'all': 'Alle Rollen',
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
                            child: Text(
                              '$count ${_view == 'people'
                                  ? 'Personen'
                                  : _view == 'accounts'
                                  ? 'Konten'
                                  : 'Rollen'}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
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
