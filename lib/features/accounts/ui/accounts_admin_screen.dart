import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../../app/theme/stage_theme.dart';
import '../../../core/account_permissions.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../casting/ui/script_roles_screen.dart';
import '../../ensemble/admin/member_editor_screen.dart';
import '../data/accounts_api.dart';
import '../domain/account_roster.dart';
import 'access_actions.dart';
import 'access_widgets.dart';

/// "Personen & Zugänge": waiting registrations on top, then every person
/// with their account, status and rights, accounts without a person and
/// the inactive people at the end. A row opens the person editor, which
/// holds the whole app access of that person.
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

  /// Kept for older callers: `roles` (with [initialFilter] `unassigned`)
  /// opens the script roles, which now live in "Produktionen & Besetzung";
  /// the former views `people` and `accounts` map their [initialFilter]
  /// onto the status filter.
  final String initialView, initialFilter;

  /// Status and rights filter of the list; see [AccountRoster.hasStatus]
  /// and [AccountRoster.hasRight]. `waiting` shows the whole list, since
  /// waiting registrations always stand on top.
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

/// Status filters with their chip labels; waiting registrations have their
/// own block above the list.
const _statusFilters = {
  'all': 'Alle',
  'approved': 'Freigegeben',
  'unverified': 'Unbestätigt',
  'suspended': 'Gesperrt',
  'rejected': 'Abgelehnt',
  'noAccount': 'Ohne Konto',
  'unassigned': 'Konto ohne Person',
  'inactive': 'Inaktiv',
};

class _AccountsAdminScreenState extends State<AccountsAdminScreen> {
  // The last loaded roster stays visible while a reload runs.
  AccountRoster? _roster;
  Object? _loadError;
  bool _loading = false;
  late String _status = _initialStatus();
  late String _right = widget.initialRight ?? 'all';
  String? _roleId;
  late String _query = widget.initialQuery;
  late final _search = TextEditingController(text: widget.initialQuery);
  final _reconsidering = <String>{};

  /// The section of inactive people is collapsed unless opened or needed.
  bool _inactiveOpen = false;

  /// The highlighted row; it is scrolled into view once after loading.
  final _focusRow = GlobalKey();
  late bool _scrollPending =
      widget.initialPersonId != null || widget.initialUid != null;
  bool _scrollScheduled = false;

  bool get _scriptRoles => widget.initialView == 'roles';

  /// Maps the filters of the former "Personen" and "Konten" views; the
  /// former waiting filter is the block on top.
  String _initialStatus() {
    final status =
        widget.initialStatus ??
        switch ((widget.initialView, widget.initialFilter)) {
          ('accounts', 'approved' || 'suspended' || 'rejected') =>
            widget.initialFilter,
          ('people', 'linked') => 'approved',
          ('people', 'unlinked') => 'noAccount',
          _ => 'all',
        };
    return _statusFilters.containsKey(status) ? status : 'all';
  }

  @override
  void initState() {
    super.initState();
    if (_scriptRoles) return;
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
        _roster = roster;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_roster != null) showProblem(context, e);
      setState(() => _loadError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Reloads after [action] changed something.
  Future<void> _run(Future<bool> Function() action) async {
    if (await action() && mounted) await _load();
  }

  /// Shows exactly the part of the summary that was tapped: every other
  /// filter and the search are cleared.
  void _filter({String status = 'all', String right = 'all'}) {
    setState(() {
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

  Future<void> _approve(JsonMap a, AccountRoster roster) => _run(() async {
    await openAccountApproval(context, widget.controller, a, roster);
    return true;
  });

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
      // The registration waits again and shows in the block on top.
      _filter();
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

  /// Creates or edits a person; the list shows the changes after.
  Future<void> _editPerson(JsonMap? m) async {
    await openPage(
      context,
      MemberEditorScreen(controller: widget.controller, member: m),
    );
    if (mounted) await _load();
  }

  Widget _actions(AccessEntry e, AccountRoster roster) {
    final c = widget.controller;
    final a = e.account, m = e.member, own = isOwnAccess(c, e);
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
        onPressed: e.inactive
            ? null
            : () => _run(() => linkAccountTo(context, c, m!, roster)),
        icon: const Icon(Icons.link, size: 18),
        label: const Text('Konto verknüpfen'),
      ),
      _ => null,
    };
    // The own access is changed by another admin; only the person remains.
    final items = <PopupMenuEntry<String>>[
      if (!own && a != null && accountRightsEditable(c, a))
        const PopupMenuItem(value: 'rights', child: Text('Rechte bearbeiten…')),
      if (!own && a?['status'] == 'approved')
        const PopupMenuItem(value: 'suspended', child: Text('Zugang sperren')),
      if (!own && a != null && accountReleasable(a))
        const PopupMenuItem(value: 'approved', child: Text('Wieder freigeben')),
      if (m != null)
        PopupMenuItem(
          key: ValueKey('account-person-edit-${m['id']}'),
          value: 'edit',
          child: const Text('Person bearbeiten'),
        ),
      if (!own && a != null)
        const PopupMenuItem(value: 'delete', child: Text('Konto löschen')),
    ];
    final menu = items.isEmpty
        ? null
        : PopupMenuButton<String>(
            tooltip: 'Zugang verwalten',
            onSelected: (s) => switch (s) {
              'rights' => _run(
                () => showAccountRightsSheet(
                  context,
                  controller: c,
                  account: a!,
                  name: e.name,
                ),
              ),
              'suspended' => _run(
                () => suspendAccount(
                  context,
                  c,
                  a!,
                  onUndone: () {
                    if (mounted) _load();
                  },
                ),
              ),
              'approved' => _run(() => releaseAccount(context, c, a!)),
              'edit' => _editPerson(m),
              _ => _run(() => deleteAccount(context, c, a!)),
            },
            itemBuilder: (_) => items,
          );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [?primary, ?menu],
    );
  }

  /// One row; without [accessKnown] (the account list did not load) only
  /// the person shows.
  Widget _entry(
    AccessEntry e,
    AccountRoster roster, {
    bool focused = false,
    bool accessKnown = true,
  }) {
    final theme = Theme.of(context);
    final a = e.account, m = e.member, status = accessStatus(e);
    final roles = m == null ? const <JsonMap>[] : roster.rolesFor(e.personId!);
    // Registrations have no person to open: their login details show here.
    final login = a == null || m != null ? '' : accountLoginLine(a);
    final avatar = m == null
        ? CircleAvatar(
            radius: 22,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.person_add_alt,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        : MemberAvatar(
            controller: widget.controller,
            avatarId: m['avatarId'] as String?,
            initials: textValue(m['initials']),
          );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(e.name, style: theme.textTheme.titleMedium),
            if (isOwnAccess(widget.controller, e))
              const StatePill('Du', icon: Icons.person_outline),
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
          // A tap on a person row opens the editor, so only registrations
          // offer their address for copying.
          if (m == null)
            SelectableText(textValue(a['email'], 'Keine E-Mail hinterlegt'))
          else
            Text(
              textValue(a['email'], 'Keine E-Mail hinterlegt'),
              style: theme.textTheme.bodySmall,
            ),
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
      clipBehavior: Clip.antiAlias,
      shape: focused && shape is RoundedRectangleBorder
          ? shape.copyWith(
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: m == null ? null : () => _editPerson(m),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(
            builder: (context, size) {
              final wide = size.maxWidth >= 620;
              final content = wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: details),
                        if (accessKnown) ...[
                          const SizedBox(width: 30),
                          Expanded(flex: 2, child: access),
                        ],
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        details,
                        if (accessKnown) ...[
                          const SizedBox(height: 14),
                          access,
                        ],
                      ],
                    );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatar,
                  SizedBox(width: wide ? 18 : 14),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// "48 Personen · 41 freigegeben · 7 ohne Konto · 3 Admins"; each part
  /// sets the matching filter.
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

  /// The filters count the list below the waiting block.
  List<Widget> _filters(
    AccountRoster roster,
    List<AccessEntry> listed, {
    required bool accessKnown,
  }) {
    final roles = widget.controller.personRoles;
    final roleId = roles.any((r) => r['id'] == _roleId) ? _roleId : null;
    final caption = Theme.of(context).textTheme.labelMedium;
    return [
      if (accessKnown) ...[
        Text('Status', style: caption),
        const SizedBox(height: 6),
        _chips(
          'status',
          _statusFilters,
          _status,
          (key) => listed.where((e) => roster.hasStatus(e, key)).length,
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
            for (final MapEntry(:key, :value)
                in accountPermissionLabels.entries)
              key: value.$1,
            'director': 'Regie',
            'member': 'Nur Mitglied',
          },
          _right,
          (key) => listed.where((e) => roster.hasRight(e, key)).length,
          (key) => setState(() => _right = key),
        ),
      ],
      if (roles.isNotEmpty) ...[
        if (accessKnown) const SizedBox(height: 12),
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

  /// The page below the app bar. Without [accessKnown] the people come from
  /// the app's own data, e.g. offline, so they can still be edited.
  List<Widget> _content(AccountRoster roster, {required bool accessKnown}) {
    final theme = Theme.of(context);
    final roleId = widget.controller.personRoles.any((r) => r['id'] == _roleId)
        ? _roleId
        : null;
    // Waiting registrations never get lost among the people: they stand
    // on top, whatever the search and filters below say.
    final waiting = [
      for (final e in roster.accessEntries)
        if (accessStatus(e) == 'waiting') e,
    ];
    final listed = [
      for (final e in roster.accessEntries)
        if (accessStatus(e) != 'waiting') e,
    ];
    final found = listed
        .where(
          (e) => roster.entryMatches(
            e,
            _query,
            // The hidden filters cannot apply without the account list.
            status: accessKnown ? _status : 'all',
            right: accessKnown ? _right : 'all',
            roleId: roleId,
            roleNames: e.member == null
                ? ''
                : widget.controller.roleNames(
                    jsonList(e.member!['roleIds']).map((r) => r.toString()),
                  ),
          ),
        )
        .toList();
    final people = found.where((e) => !e.unassigned && !e.inactive).toList();
    final unassigned = found.where((e) => e.unassigned).toList();
    final inactive = found.where((e) => e.inactive).toList();
    final focus = roster
        .entryFor(personId: widget.initialPersonId, uid: widget.initialUid)
        ?.key;
    if (_scrollPending && inactive.any((e) => e.key == focus)) {
      _inactiveOpen = true;
    }
    final filtered =
        _query.isNotEmpty ||
        (accessKnown && (_status != 'all' || _right != 'all')) ||
        roleId != null;
    // Collapsed by default; a search or filter shows every match.
    final inactiveOpen = _inactiveOpen || filtered;
    if (_scrollPending) {
      final shown = [
        ...waiting,
        ...people,
        ...unassigned,
        if (inactiveOpen) ...inactive,
      ];
      if (shown.any((e) => e.key == focus)) {
        _scrollToFocus();
      } else {
        _scrollPending = false;
      }
    }
    Widget row(AccessEntry e) => Padding(
      key: e.key == focus ? _focusRow : null,
      padding: const EdgeInsets.only(bottom: 12),
      child: _entry(
        e,
        roster,
        focused: e.key == focus,
        accessKnown: accessKnown,
      ),
    );
    return [
      if (!accessKnown)
        Card(
          key: const ValueKey('access-not-loaded'),
          margin: const EdgeInsets.only(bottom: 16),
          child: ListTile(
            leading: const Icon(Icons.cloud_off_outlined),
            title: const Text('Zugänge nicht geladen'),
            subtitle: Text(
              '${userMessage(_loadError ?? 'unbekannt')}\n'
              'Personen lassen sich trotzdem bearbeiten.',
            ),
            trailing: TextButton(
              onPressed: _loading ? null : _load,
              child: const Text('Erneut versuchen'),
            ),
          ),
        ),
      if (waiting.isNotEmpty)
        Container(
          key: const ValueKey('access-waiting'),
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: .35),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 18, bottom: 4),
                child: Text(
                  'Wartet auf Zuordnung (${waiting.length})',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  waiting.length == 1
                      ? 'Eine neue Registrierung: prüfen und mit einer Person '
                            'verknüpfen.'
                      : 'Neue Registrierungen: prüfen und mit einer Person '
                            'verknüpfen.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              for (final e in waiting) row(e),
            ],
          ),
        ),
      if (accessKnown) ...[_summary(roster), const SizedBox(height: 16)],
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
      ..._filters(roster, listed, accessKnown: accessKnown),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          found.length == 1 ? '1 Eintrag' : '${found.length} Einträge',
          style: theme.textTheme.bodySmall,
        ),
      ),
      if (found.isEmpty)
        filtered
            ? const EmptyState(
                icon: Icons.search_off,
                title: 'Keine Treffer',
                message: 'Passe die Suche oder den Filter an.',
              )
            : const EmptyState(
                icon: Icons.group_add_outlined,
                title: 'Noch keine Personen',
                message: 'Lege die erste Person an.',
              ),
      for (final e in people) row(e),
      if (unassigned.isNotEmpty) ...[
        SectionTitle('Konten ohne Person (${unassigned.length})'),
        for (final e in unassigned) row(e),
      ],
      if (inactive.isNotEmpty) ...[
        InkWell(
          key: const ValueKey('access-inactive-toggle'),
          borderRadius: BorderRadius.circular(12),
          onTap: filtered
              ? null
              : () => setState(() => _inactiveOpen = !_inactiveOpen),
          child: SectionTitle(
            'Nicht aktiv (${inactive.length})',
            trailing: filtered
                ? null
                : Icon(inactiveOpen ? Icons.expand_less : Icons.expand_more),
          ),
        ),
        if (inactiveOpen)
          for (final e in inactive) row(e),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_scriptRoles) {
      return ScriptRolesScreen(
        controller: widget.controller,
        initialFilter: widget.initialFilter,
      );
    }
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final admin = widget.controller.user?.isAdmin == true;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Personen & Zugänge'),
            actions: [
              IconButton(
                tooltip: 'Aktualisieren',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
            bottom: _loading && _roster != null
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(3),
                    child: LinearProgressIndicator(minHeight: 3),
                  )
                : null,
          ),
          floatingActionButton: admin
              ? FloatingActionButton.extended(
                  onPressed: () => _editPerson(null),
                  icon: const Icon(Icons.person_add_outlined),
                  label: const Text('Person anlegen'),
                )
              : null,
          body: !admin
              ? const Center(child: Text('Admin-Zugang erforderlich.'))
              : Builder(
                  builder: (context) {
                    if (_roster == null && _loadError == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final children = _content(
                      _roster ??
                          AccountRoster({
                            'members': widget.controller.memberRecords,
                            'productions': widget.controller.productionRecords,
                          }),
                      accessKnown: _roster != null,
                    );
                    return Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1050),
                        child: RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            // Builds the rows down to the highlighted one, so
                            // it can be scrolled into view.
                            scrollCacheExtent: _scrollPending
                                ? const ScrollCacheExtent.pixels(100000)
                                : null,
                            // Room below the last row for the create button.
                            padding: const EdgeInsets.fromLTRB(22, 12, 22, 96),
                            children: children,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
