import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/account_permissions.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../auth/ui/sign_in_providers.dart';
import '../../casting/ui/casting_screen.dart';
import '../../ensemble/admin/member_editor_screen.dart';
import '../data/accounts_api.dart';
import '../domain/account_roster.dart';
import 'access_widgets.dart';
import 'account_approval_screen.dart';

/// "Zugänge & Rechte": every person with their account and every account
/// without a person in one list, with status, rights and login details;
/// plus the script roles with their casting.
class AccountsAdminScreen extends StatefulWidget {
  const AccountsAdminScreen({
    super.key,
    required this.controller,
    this.initialView = 'access',
    this.initialFilter = 'all',
    this.initialStatus,
    this.initialRight,
    this.initialQuery = '',
    this.initialPersonId,
    this.initialUid,
  });
  final AppController controller;

  /// `access` or `roles`. The former views `people` and `accounts` (with
  /// their [initialFilter]) still open the access list.
  final String initialView, initialFilter;

  /// Status and rights filter of the access list; see
  /// [AccountRoster.hasStatus] and [AccountRoster.hasRight].
  final String? initialStatus, initialRight;

  /// Prefills the search; kept for older callers.
  final String initialQuery;

  /// Scrolls to and highlights this person's row, or without one the row of
  /// the account [initialUid] (e.g. from a registration push).
  final int? initialPersonId;
  final String? initialUid;
  @override
  State<AccountsAdminScreen> createState() => _AccountsAdminScreenState();
}

/// Status filters with their chip labels.
const _statusFilters = {
  'all': 'Alle',
  'approved': 'Freigegeben',
  'waiting': 'Wartet',
  'unverified': 'Unbestätigt',
  'suspended': 'Gesperrt',
  'rejected': 'Abgelehnt',
  'noAccount': 'Ohne Konto',
  'unassigned': 'Konto ohne Person',
  'inactive': 'Inaktiv',
};

class _AccountsAdminScreenState extends State<AccountsAdminScreen> {
  // The last loaded roster stays visible while a reload runs.
  JsonMap? _data;
  Object? _loadError;
  bool _loading = false;
  late String _view = widget.initialView == 'roles' ? 'roles' : 'access';
  late String _status = widget.initialStatus ?? _legacyStatus();
  late String _right = widget.initialRight ?? 'all';
  String? _roleId;
  late String _rolesFilter =
      widget.initialView == 'roles' && widget.initialFilter == 'unassigned'
      ? 'unassigned'
      : 'all';
  late String _query = widget.initialQuery;
  late final _search = TextEditingController(text: widget.initialQuery);
  final _reconsidering = <String>{};

  /// The highlighted row; it is scrolled into view once after loading.
  final _focusRow = GlobalKey();
  late bool _scrollPending =
      widget.initialPersonId != null || widget.initialUid != null;
  bool _scrollScheduled = false;

  /// Maps the filters of the former "Personen" and "Konten" views.
  String _legacyStatus() =>
      switch ((widget.initialView, widget.initialFilter)) {
        ('accounts', 'pending') => 'waiting',
        ('accounts', 'approved' || 'suspended' || 'rejected') =>
          widget.initialFilter,
        ('people', 'linked') => 'approved',
        ('people', 'unlinked') => 'noAccount',
        _ => 'all',
      };

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
      final roster = await fetchRoster(widget.controller);
      if (!mounted) return;
      setState(() {
        _data = {
          'members': roster.members,
          'accounts': roster.accounts,
          'productions': roster.productions,
        };
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

  /// Shows exactly the part of the summary that was tapped: every other
  /// filter and the search are cleared.
  void _filter({String status = 'all', String right = 'all'}) {
    setState(() {
      _view = 'access';
      _status = status;
      _right = right;
      _roleId = null;
      _query = '';
      _search.clear();
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

  /// Role and rights in one sheet; the list reloads afterwards, also after
  /// a refused change, so it shows the current rights.
  Future<void> _editRights(JsonMap a, AccessEntry e) async {
    final sent = await showAccountRightsSheet(
      context,
      controller: widget.controller,
      account: a,
      name: e.name,
    );
    if (sent && mounted) await _load();
  }

  /// Linked accounts whose rights can be edited here: approved ones (role
  /// and rights) and suspended members (their resting rights).
  bool _rightsEditable(JsonMap a) {
    if (a['personId'] == null) return false;
    final rights = widget.controller.supports('accountPermissions');
    return switch (a['status']) {
      'approved' =>
        widget.controller.supports('accountRole') ||
            (rights && a['role'] != 'admin'),
      'suspended' => rights && a['role'] != 'admin',
      _ => false,
    };
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
      _filter(status: 'waiting');
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

  /// Picks a waiting registration for [m]; unconfirmed ones show disabled,
  /// since they cannot be approved yet.
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
    if (chosen != null && mounted) {
      await _approve(chosen, roster, personId: intValue(m['id']));
    }
  }

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

  /// Name, roles and activity live in the ensemble; edits show here after.
  Future<void> _editPerson(JsonMap m) async {
    await openPage(
      context,
      MemberEditorScreen(controller: widget.controller, member: m),
    );
    if (mounted) await _load();
  }

  bool _isOwn(AccessEntry e) {
    final user = widget.controller.user;
    if (user == null) return false;
    return (e.account != null && e.uid == user.id) ||
        (e.personId != null && e.personId == user.personId);
  }

  Widget _actions(AccessEntry e, AccountRoster roster) {
    final a = e.account, m = e.member, own = _isOwn(e);
    final primary = switch (accessStatus(e)) {
      'waiting' => TextButton(
        onPressed: () => _approve(a!, roster),
        child: const Text('Prüfen & verknüpfen'),
      ),
      'rejected' => TextButton.icon(
        onPressed: _reconsidering.contains(e.uid)
            ? null
            : () => _reconsider(a!),
        icon: const Icon(Icons.undo, size: 18),
        label: const Text('Erneut prüfen'),
      ),
      'noAccount' => TextButton.icon(
        onPressed: e.inactive ? null : () => _chooseAccount(m!, roster),
        icon: const Icon(Icons.link, size: 18),
        label: const Text('Konto verknüpfen'),
      ),
      _ => null,
    };
    // The own access is changed by another admin; only the person remains.
    final items = <PopupMenuEntry<String>>[
      if (!own && a != null && _rightsEditable(a))
        const PopupMenuItem(value: 'rights', child: Text('Rechte bearbeiten…')),
      if (!own && a?['status'] == 'approved')
        const PopupMenuItem(value: 'suspended', child: Text('Zugang sperren')),
      // The server releases only linked accounts with a confirmed identity;
      // a suspended registration without a person would always be refused.
      if (!own &&
          a?['status'] == 'suspended' &&
          a?['personId'] != null &&
          a?['identityReady'] == true)
        const PopupMenuItem(value: 'approved', child: Text('Wieder freigeben')),
      if (m != null)
        PopupMenuItem(
          key: ValueKey('account-person-edit-${m['id']}'),
          value: 'edit',
          child: const Text('In Ensemble bearbeiten'),
        ),
      if (!own && a != null)
        const PopupMenuItem(value: 'delete', child: Text('Konto löschen')),
    ];
    final menu = items.isEmpty
        ? null
        : PopupMenuButton<String>(
            tooltip: 'Zugang verwalten',
            onSelected: (s) => switch (s) {
              'rights' => _editRights(a!, e),
              'suspended' => _suspend(a!),
              'approved' => _release(a!),
              'edit' => _editPerson(m!),
              _ => _delete(a!),
            },
            itemBuilder: (_) => items,
          );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [?primary, ?menu],
    );
  }

  static final _date = DateFormat('d.M.yyyy');
  String? _dateOf(Object? value) {
    final at = DateTime.tryParse(textValue(value));
    return at == null ? null : _date.format(at.toLocal());
  }

  /// "Google · bestätigt · zuletzt aktiv 3.10.2026 · freigegeben 1.9.2026".
  String _loginLine(JsonMap a) {
    final provider = textValue(a['provider']);
    final seen = _dateOf(a['lastSeenAt']), approved = _dateOf(a['approvedAt']);
    return [
      if (provider.isNotEmpty) providerNames[provider] ?? provider,
      if (a['emailVerified'] == true) 'bestätigt',
      if (a['emailVerified'] == false) 'unbestätigt',
      if (seen != null) 'zuletzt aktiv $seen',
      if (approved != null && a['status'] == 'approved')
        'freigegeben $approved',
    ].join(' · ');
  }

  Widget _entry(AccessEntry e, AccountRoster roster, {bool focused = false}) {
    final theme = Theme.of(context);
    final a = e.account, m = e.member, status = accessStatus(e);
    final roles = m == null ? const <JsonMap>[] : roster.rolesFor(e.personId!);
    final login = a == null ? '' : _loginLine(a);
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(e.name, style: theme.textTheme.titleMedium),
            if (_isOwn(e)) const StatePill('Du', icon: Icons.person_outline),
            if (e.inactive) const AccessStatusPill('inactive'),
          ],
        ),
        if (jsonList(m?['roleIds']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.controller.roleNames(
                jsonList(m!['roleIds']).map((r) => r.toString()),
              ),
            ),
          ),
        if (textValue(m?['roleName']).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(textValue(m!['roleName'])),
          ),
        for (final p in roster.productions.where(
          (p) => roles.any((r) => r['productionId'] == p['id']),
        ))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${textValue(p['title'])}\n${roles.where((r) => r['productionId'] == p['id']).map((r) => textValue(r['name'])).join(' · ')}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
    final access = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            AccessStatusPill(status),
            if (e.unassigned) const AccessStatusPill('unassigned'),
            if (a != null && (e.unassigned || status == 'waiting')) ...[
              if (withoutBotCheck(a))
                const StatePill(
                  'Ohne Botschutz',
                  color: StageTheme.amber,
                  icon: Icons.shield_outlined,
                ),
              if (caughtByBotTrap(a))
                const StatePill(
                  'Verdacht: Bot-Falle',
                  color: StageTheme.amber,
                  icon: Icons.smart_toy_outlined,
                ),
            ],
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: RightsPills(roster.rights(e)),
        ),
        if (a != null) ...[
          const SizedBox(height: 4),
          SelectableText(textValue(a['email'], 'Keine E-Mail hinterlegt')),
          if (login.isNotEmpty) Text(login, style: theme.textTheme.bodySmall),
        ],
        if (status == 'unverified')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Wartet auf E-Mail-Bestätigung',
              style: theme.textTheme.bodySmall,
            ),
          ),
        _actions(e, roster),
      ],
    );
    final shape = theme.cardTheme.shape;
    return Card(
      key: ValueKey('access-entry-${e.key}'),
      shape: focused && shape is RoundedRectangleBorder
          ? shape.copyWith(
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
            )
          : null,
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
              : '${textValue(person['name'])}\n${a == null ? 'Kein Konto' : '${textValue(a['email'])} · ${accountStatus(a)}'}'}',
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

  /// "48 Personen · 41 freigegeben · 7 ohne Konto · 2 warten · 3 Admins";
  /// each part sets the matching filter.
  Widget _summary(AccountRoster roster) {
    final events = roster.permissionCount(eventsPermission);
    final parts = [
      (
        roster.members.length == 1
            ? '1 Person'
            : '${roster.members.length} Personen',
        () => _filter(),
      ),
      if (roster.linkedCount > 0)
        (
          '${roster.linkedCount} freigegeben',
          () => _filter(status: 'approved'),
        ),
      if (roster.withoutAccountCount > 0)
        (
          '${roster.withoutAccountCount} ohne Konto',
          () => _filter(status: 'noAccount'),
        ),
      if (roster.waitingCount > 0)
        (
          roster.waitingCount == 1
              ? '1 wartet'
              : '${roster.waitingCount} warten',
          () => _filter(status: 'waiting'),
        ),
      if (roster.unverifiedCount > 0)
        (
          '${roster.unverifiedCount} unbestätigt',
          () => _filter(status: 'unverified'),
        ),
      if (roster.adminCount > 0)
        (
          roster.adminCount == 1 ? '1 Admin' : '${roster.adminCount} Admins',
          () => _filter(right: 'admin'),
        ),
      if (events > 0)
        (
          '$events ${accountPermissionLabels[eventsPermission]!.$1}',
          () => _filter(right: eventsPermission),
        ),
    ];
    final dot = Text(
      '·',
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
    return Wrap(
      key: const ValueKey('access-summary'),
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (i, (label, onTap)) in parts.indexed) ...[
          if (i > 0) dot,
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 40),
            ),
            onPressed: onTap,
            child: Text(label),
          ),
        ],
      ],
    );
  }

  /// One row of filter chips with counts; empty choices are left out unless
  /// selected.
  Widget _chips(
    String name,
    Map<String, String> labels,
    String selected,
    int Function(String) count,
    void Function(String) onSelected,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final MapEntry(:key, :value) in labels.entries)
        if (key == 'all' || key == selected || count(key) > 0)
          FilterChip(
            key: ValueKey('$name-$key'),
            label: Text('$value (${count(key)})'),
            selected: selected == key,
            onSelected: (_) => onSelected(key),
          ),
    ],
  );

  List<Widget> _accessFilters(AccountRoster roster) {
    final roles = widget.controller.personRoles;
    final roleId = roles.any((r) => r['id'] == _roleId) ? _roleId : null;
    final caption = Theme.of(context).textTheme.labelMedium;
    return [
      Text('Status', style: caption),
      const SizedBox(height: 6),
      _chips(
        'status',
        _statusFilters,
        _status,
        roster.statusCount,
        (key) => setState(() => _status = key),
      ),
      const SizedBox(height: 12),
      Text('Rechte', style: caption),
      const SizedBox(height: 6),
      _chips(
        'right',
        {
          'all': 'Alle',
          'admin': 'Admin',
          for (final MapEntry(:key, :value) in accountPermissionLabels.entries)
            key: value.$1,
          'director': 'Regie',
          'member': 'Nur Mitglied',
        },
        _right,
        roster.rightCount,
        (key) => setState(() => _right = key),
      ),
      if (roles.isNotEmpty) ...[
        const SizedBox(height: 12),
        DropdownButton<String?>(
          key: const ValueKey('access-role-filter'),
          value: roleId,
          isExpanded: true,
          onChanged: (id) => setState(() => _roleId = id),
          items: [
            const DropdownMenuItem(value: null, child: Text('Alle Rollen')),
            for (final r in roles)
              DropdownMenuItem(
                value: textValue(r['id']),
                child: Text(textValue(r['name'])),
              ),
          ],
        ),
      ],
    ];
  }

  /// Scrolls the highlighted row into view once it is built.
  void _scrollToFocus() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final row = _focusRow.currentContext;
      if (row != null) {
        await Scrollable.ensureVisible(
          row,
          alignment: .1,
          duration: const Duration(milliseconds: 250),
        );
      }
      if (mounted) setState(() => _scrollPending = false);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Zugänge & Rechte'),
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
                final roleId =
                    widget.controller.personRoles.any((r) => r['id'] == _roleId)
                    ? _roleId
                    : null;
                final entries = roster.accessEntries
                    .where(
                      (e) => roster.entryMatches(
                        e,
                        _query,
                        status: _status,
                        right: _right,
                        roleId: roleId,
                        roleNames: e.member == null
                            ? ''
                            : widget.controller.roleNames(
                                jsonList(
                                  e.member!['roleIds'],
                                ).map((r) => r.toString()),
                              ),
                      ),
                    )
                    .toList();
                final roles = roster.roles
                    .where(
                      (r) =>
                          (_rolesFilter == 'all' ||
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
                final focus = roster
                    .entryFor(
                      personId: widget.initialPersonId,
                      uid: widget.initialUid,
                    )
                    ?.key;
                final access = _view == 'access';
                final count = access ? entries.length : roles.length;
                if (_scrollPending) {
                  if (access && entries.any((e) => e.key == focus)) {
                    _scrollToFocus();
                  } else {
                    _scrollPending = false;
                  }
                }
                final waitingEmpty =
                    _query.isEmpty &&
                    access &&
                    _status == 'waiting' &&
                    _right == 'all' &&
                    _roleId == null;
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1050),
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        // Builds the rows down to the highlighted one, so it
                        // can be scrolled into view.
                        scrollCacheExtent: _scrollPending
                            ? const ScrollCacheExtent.pixels(100000)
                            : null,
                        padding: const EdgeInsets.fromLTRB(22, 12, 22, 32),
                        children: [
                          _summary(roster),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (key, label) in [
                                (
                                  'access',
                                  'Zugänge (${roster.accessEntries.length})',
                                ),
                                (
                                  'roles',
                                  'Drehbuchrollen (${roster.roles.length})',
                                ),
                              ])
                                ChoiceChip(
                                  label: Text(label),
                                  selected: _view == key,
                                  onSelected: (_) =>
                                      setState(() => _view = key),
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
                          if (access)
                            ..._accessFilters(roster)
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final MapEntry(:key, :value) in {
                                  'all': 'Alle Drehbuchrollen',
                                  'unassigned': 'Ohne Besetzung',
                                }.entries)
                                  FilterChip(
                                    label: Text(value),
                                    selected: _rolesFilter == key,
                                    onSelected: (_) =>
                                        setState(() => _rolesFilter = key),
                                  ),
                              ],
                            ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text(
                              access
                                  ? count == 1
                                        ? '1 Eintrag'
                                        : '$count Einträge'
                                  : count == 1
                                  ? '1 Drehbuchrolle'
                                  : '$count Drehbuchrollen',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          if (count == 0)
                            EmptyState(
                              icon: Icons.search_off,
                              title: waitingEmpty
                                  ? 'Keine offenen Freigaben'
                                  : 'Keine Treffer',
                              message: waitingEmpty
                                  ? 'Neue Registrierungen erscheinen hier.'
                                  : 'Passe die Suche oder den Filter an.',
                            ),
                          if (access)
                            for (final e in entries)
                              Padding(
                                key: e.key == focus ? _focusRow : null,
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _entry(
                                  e,
                                  roster,
                                  focused: e.key == focus,
                                ),
                              )
                          else
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
