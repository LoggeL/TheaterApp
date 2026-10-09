import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/casting.dart';
import '../core/models.dart';
import 'admin.dart' show showProblem;
import 'profile.dart';
import 'theme.dart';

/// Common team functions offered as one-tap choices.
const teamFunctionChoices = [
  'Licht',
  'Ton',
  'Maske',
  'Kostüm',
  'Requisite',
  'Bühnenbau',
  'Souffleuse',
  'Inspizienz',
];

/// "Besetzung & Team": who plays which script role, who directs and who else
/// belongs to a production. Changes are sent one by one (`production.cast`),
/// so a single assignment never overwrites the rest of the production.
class CastingScreen extends StatefulWidget {
  const CastingScreen({
    super.key,
    required this.controller,
    required this.productionId,
  });
  final AppController controller;
  final String productionId;
  @override
  State<CastingScreen> createState() => _CastingScreenState();
}

class _CastingScreenState extends State<CastingScreen> {
  int _pending = 0;
  bool _onlyOpen = false;

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // The script's dialogue sorts the roles by size; without it they stay
    // alphabetical. Loading keeps it offline for the reader as well.
    final record = _record;
    if (record != null &&
        textValue(record['revision']).isNotEmpty &&
        jsonList(record['roles']).isNotEmpty &&
        !_controller.scripts.containsKey(widget.productionId)) {
      _controller.loadScript(widget.productionId);
    }
  }

  JsonMap? get _record => _controller.productionRecords
      .where((p) => p['id'] == widget.productionId)
      .firstOrNull;

  Future<void> _apply(List<JsonMap> changes, {String? done}) async {
    setState(() => _pending++);
    try {
      await _controller.performAction({
        'action': 'production.cast',
        'id': widget.productionId,
        'changes': changes,
      });
      if (mounted && done != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _pending--);
    }
  }

  TheaterMember? _member(int? id) =>
      _controller.members.where((m) => m.id == id).firstOrNull;

  String _name(int id) => _member(id)?.name ?? 'Unbekannte Person';

  Widget _avatar(int? id, {double radius = 20}) {
    final member = _member(id);
    return MemberAvatar(
      controller: _controller,
      avatarId: member?.avatarId,
      initials: member?.initials.isNotEmpty == true
          ? member!.initials
          : (member?.name.isNotEmpty == true ? member!.name[0] : '?'),
      radius: radius,
    );
  }

  Future<void> _castRole(
    ProductionCast cast,
    ScriptRole role,
    CastingSuggestion? suggestion,
  ) async {
    final current = cast.personFor(role.id);
    final choice = await _choosePerson(
      cast,
      title: 'Rolle „${role.name}“ besetzen',
      current: current,
      suggestion: suggestion,
      removeLabel: 'Besetzung entfernen',
    );
    if (choice == null || choice.personId == current) return;
    await _apply([
      {
        'kind': 'role',
        'roleId': role.id,
        'personId': choice.personId,
        'previous': current,
      },
    ]);
  }

  Future<_Choice?> _choosePerson(
    ProductionCast cast, {
    required String title,
    int? current,
    CastingSuggestion? suggestion,
    String? removeLabel,
    Set<int> exclude = const {},
  }) {
    var query = '';
    return showModalBottomSheet<_Choice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final needle = normalizeName(query);
          final people =
              _controller.members
                  .where(
                    (m) =>
                        (m.active || m.id == current) &&
                        !exclude.contains(m.id) &&
                        normalizeName(
                          '${m.name} ${_controller.roleNames(m.roleIds)}',
                        ).contains(needle),
                  )
                  .toList()
                ..sort((a, b) {
                  final first =
                      (b.id == suggestion?.personId ? 1 : 0) -
                      (a.id == suggestion?.personId ? 1 : 0);
                  return first != 0
                      ? first
                      : normalizeName(a.name).compareTo(normalizeName(b.name));
                });
          final theme = Theme.of(context);
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(title, style: theme.textTheme.titleLarge),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: TextField(
                      key: const ValueKey('casting-person-search'),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Person suchen',
                      ),
                      onChanged: (v) => setSheetState(() => query = v),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        if (current != null && removeLabel != null)
                          ListTile(
                            leading: const Icon(Icons.person_remove_outlined),
                            title: Text(removeLabel),
                            onTap: () =>
                                Navigator.pop(context, const _Choice(null)),
                          ),
                        for (final m in people)
                          ListTile(
                            key: ValueKey('casting-person-${m.id}'),
                            leading: _avatar(m.id),
                            title: Text(m.name),
                            subtitle: _personHint(cast, m, suggestion),
                            trailing: m.id == current
                                ? Icon(
                                    Icons.check_circle,
                                    color: theme.colorScheme.primary,
                                  )
                                : null,
                            onTap: () => Navigator.pop(context, _Choice(m.id)),
                          ),
                        if (people.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Keine passende Person gefunden.'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget? _personHint(
    ProductionCast cast,
    TheaterMember m,
    CastingSuggestion? suggestion,
  ) {
    final parts = [
      if (m.id == suggestion?.personId) 'Vorschlag: ${suggestion!.reason}',
      if (cast.dutiesOf(m.id).isNotEmpty)
        'Hier: ${cast.dutiesOf(m.id).join(', ')}',
      if (m.roleIds.isNotEmpty) _controller.roleNames(m.roleIds),
      if (!m.active) 'Nicht aktiv',
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }

  Future<String?> _editFunction(String name, String current) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _FunctionDialog(name: name, current: current),
    );
    return result?.trim();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final record = _record;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Besetzung & Team'),
          bottom: _pending > 0
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(3),
                  child: LinearProgressIndicator(minHeight: 3),
                )
              : null,
        ),
        body: _controller.user?.isAdmin != true
            ? const Center(child: Text('Admin-Zugang erforderlich.'))
            : record == null
            ? const Center(child: Text('Die Produktion ist nicht verfügbar.'))
            : _content(context, ProductionCast.fromRecord(record)),
      );
    },
  );

  Widget _content(BuildContext context, ProductionCast cast) {
    final counts = roleLineCounts(_controller.scripts[cast.id]);
    final roles = rolesByImportance(cast.roles, counts);
    final others = _controller.productionRecords
        .where((p) => p['id'] != cast.id)
        .map(ProductionCast.fromRecord)
        .toList();
    final suggestions = castingSuggestions(
      cast,
      _controller.members,
      others,
      order: roles,
    );
    final byRole = {for (final s in suggestions) s.role.id: s};
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final left = [
          _summary(context, cast),
          if (suggestions.isNotEmpty) _suggestions(context, cast, suggestions),
          ..._roles(context, cast, roles, counts, byRole),
        ];
        final right = [
          ..._directors(context, cast),
          ..._team(context, cast),
          ..._ensemble(context, cast),
        ];
        return RefreshIndicator(
          onRefresh: _controller.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: wide ? 1200 : 760),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: left,
                              ),
                            ),
                            const SizedBox(width: 28),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: right,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [...left, ...right],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _summary(BuildContext context, ProductionCast cast) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final total = cast.roles.length, done = cast.castCount;
    final open = total - done;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Eyebrow('Produktion'),
            const SizedBox(height: 8),
            Text(cast.title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 14),
            if (total == 0)
              Text(
                'Noch keine Rollen – sie erscheinen nach dem Drehbuchimport. '
                'Regie und Team lassen sich schon zuordnen.',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              Text(
                '$done von $total Rollen besetzt',
                key: const ValueKey('casting-progress'),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: done / total,
                  minHeight: 8,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (open > 0)
                  StatePill(
                    open == 1 ? '1 Rolle offen' : '$open Rollen offen',
                    color: scheme.error,
                    icon: Icons.error_outline,
                  ),
                StatePill(
                  'Ensemble: ${_people(cast.ensemble.length)}',
                  color: scheme.secondary,
                  icon: Icons.groups_outlined,
                ),
                StatePill(
                  'Regie: ${cast.directors.length}',
                  color: scheme.tertiary,
                  icon: Icons.campaign_outlined,
                ),
                StatePill(
                  'Team: ${cast.team.length}',
                  color: scheme.tertiary,
                  icon: Icons.handyman_outlined,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestions(
    BuildContext context,
    ProductionCast cast,
    List<CastingSuggestion> suggestions,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Card(
        key: const ValueKey('casting-suggestions'),
        color: StageTheme.green.withValues(alpha: .1),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The accept button sits beside the suggestion when there is room.
            final inline = constraints.maxWidth >= 480;
            Widget accept(CastingSuggestion s) => TextButton.icon(
              key: ValueKey('casting-accept-${s.role.id}'),
              onPressed: () => _apply([
                {
                  'kind': 'role',
                  'roleId': s.role.id,
                  'personId': s.personId,
                  'previous': null,
                },
              ], done: '${s.role.name}: ${_name(s.personId)}'),
              icon: const Icon(Icons.check),
              label: const Text('Übernehmen'),
            );
            return Padding(
              padding: EdgeInsets.fromLTRB(
                constraints.maxWidth < 360 ? 14 : 20,
                18,
                constraints.maxWidth < 360 ? 14 : 20,
                16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        const WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: EdgeInsetsDirectional.only(end: 8),
                            child: Icon(
                              Icons.auto_awesome_outlined,
                              color: StageTheme.green,
                            ),
                          ),
                        ),
                        const TextSpan(text: 'Automatische Vorschläge'),
                      ],
                    ),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Aus dem Drehbuch und früheren Besetzungen. '
                    'Bitte kurz prüfen, bevor du sie übernimmst.',
                    style: theme.textTheme.bodySmall,
                  ),
                  for (final s in suggestions) ...[
                    const Divider(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _avatar(s.personId, radius: 18),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${s.role.name}: ${_name(s.personId)}',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  height: 1.25,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(s.reason, style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                        if (inline) ...[const SizedBox(width: 8), accept(s)],
                      ],
                    ),
                    if (!inline)
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: accept(s),
                      ),
                  ],
                  if (suggestions.length > 1) ...[
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      key: const ValueKey('casting-accept-all'),
                      onPressed: () => _apply([
                        for (final s in suggestions)
                          {
                            'kind': 'role',
                            'roleId': s.role.id,
                            'personId': s.personId,
                            'previous': null,
                          },
                      ], done: '${suggestions.length} Rollen besetzt.'),
                      icon: const Icon(Icons.done_all),
                      label: Text(
                        'Alle Vorschläge übernehmen (${suggestions.length})',
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _roles(
    BuildContext context,
    ProductionCast cast,
    List<ScriptRole> roles,
    Map<String, int> counts,
    Map<String, CastingSuggestion> suggestions,
  ) {
    if (roles.isEmpty) return const [];
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final open = roles.where((r) => !cast.isCast(r.id)).length;
    final shown = _onlyOpen
        ? roles.where((r) => !cast.isCast(r.id)).toList()
        : roles;
    final sortedByLines = roles.any((r) => linesOf(r, counts) > 0);
    return [
      SectionTitle(
        'Rollen aus dem Drehbuch',
        trailing: FilterChip(
          key: const ValueKey('casting-only-open'),
          label: Text('Nur offene ($open)'),
          selected: _onlyOpen,
          onSelected: (on) => setState(() => _onlyOpen = on),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          sortedByLines
              ? 'Sortiert nach Textmenge. Tippe auf eine Rolle, um sie zu besetzen.'
              : 'Alphabetisch sortiert. Tippe auf eine Rolle, um sie zu besetzen.',
          style: theme.textTheme.bodySmall,
        ),
      ),
      if (shown.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Alle Rollen sind besetzt.'),
        ),
      for (final role in shown)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _roleTile(
            context,
            cast,
            role,
            linesOf(role, counts),
            suggestions[role.id],
            scheme,
          ),
        ),
    ];
  }

  Widget _roleTile(
    BuildContext context,
    ProductionCast cast,
    ScriptRole role,
    int lines,
    CastingSuggestion? suggestion,
    ColorScheme scheme,
  ) {
    final theme = Theme.of(context);
    final personId = cast.personFor(role.id);
    final open = personId == null;
    final details = [
      if (lines > 0) lines == 1 ? '1 Textstelle' : '$lines Textstellen',
      if (role.actor.isNotEmpty &&
          normalizeName(role.actor) != normalizeName(_name(personId ?? -1)))
        'Drehbuch: ${role.actor}',
    ];
    return Card(
      key: ValueKey('casting-role-${role.id}'),
      color: open ? scheme.errorContainer.withValues(alpha: .4) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: open
            ? BorderSide(color: scheme.error.withValues(alpha: .6))
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: open
            ? CircleAvatar(
                radius: 20,
                backgroundColor: scheme.error.withValues(alpha: .12),
                child: Icon(Icons.person_add_alt, color: scheme.error),
              )
            : _avatar(personId),
        title: Text(
          role.name,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              open ? 'Noch nicht besetzt' : _name(personId),
              style: open
                  ? TextStyle(color: scheme.error, fontWeight: FontWeight.w700)
                  : null,
            ),
            if (details.isNotEmpty)
              Text(details.join(' · '), style: theme.textTheme.bodySmall),
          ],
        ),
        trailing: Icon(
          open ? Icons.add_circle_outline : Icons.edit_outlined,
          color: open ? scheme.error : scheme.onSurfaceVariant,
        ),
        onTap: () => _castRole(cast, role, suggestion),
      ),
    );
  }

  Widget _personTile(
    BuildContext context, {
    required Key key,
    required int personId,
    required String subtitle,
    required String removeTooltip,
    required VoidCallback onRemove,
    VoidCallback? onTap,
  }) {
    final member = _member(personId);
    return ListTile(
      key: key,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: _avatar(personId),
      title: Text(_name(personId)),
      subtitle: Text(
        member?.active == false ? '$subtitle · Nicht aktiv' : subtitle,
      ),
      onTap: onTap,
      trailing: IconButton(
        tooltip: removeTooltip,
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: onRemove,
      ),
    );
  }

  Widget _group(List<Widget> tiles) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (final (i, tile) in tiles.indexed) ...[
          if (i > 0) const Divider(height: 1, indent: 72),
          tile,
        ],
      ],
    ),
  );

  List<Widget> _directors(BuildContext context, ProductionCast cast) => [
    const SectionTitle('Regie'),
    if (cast.directors.isNotEmpty)
      _group([
        for (final id in cast.directors)
          _personTile(
            context,
            key: ValueKey('casting-director-$id'),
            personId: id,
            subtitle: 'Darf den gemeinsamen Fokus im Drehbuch setzen',
            removeTooltip: '${_name(id)} aus der Regie entfernen',
            onRemove: () => _apply([
              {'kind': 'director', 'personId': id, 'on': false},
            ]),
          ),
      ]),
    Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          key: const ValueKey('casting-add-director'),
          onPressed: () async {
            final choice = await _choosePerson(
              cast,
              title: 'Regie hinzufügen',
              exclude: cast.directors.toSet(),
            );
            if (choice?.personId == null) return;
            await _apply([
              {'kind': 'director', 'personId': choice!.personId, 'on': true},
            ]);
          },
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Regie hinzufügen'),
        ),
      ),
    ),
  ];

  List<Widget> _team(BuildContext context, ProductionCast cast) => [
    const SectionTitle('Team & Mitwirkende'),
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        'Technik, Maske, Souffleuse … – Personen ohne Rolle im Drehbuch. '
        'Tippe auf eine Person, um ihre Funktion einzutragen.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
    if (cast.team.isNotEmpty)
      _group([
        for (final id in cast.team)
          _personTile(
            context,
            key: ValueKey('casting-team-$id'),
            personId: id,
            subtitle: cast.functions[id] ?? 'Funktion ergänzen',
            removeTooltip: '${_name(id)} aus dem Team entfernen',
            onRemove: () => _apply([
              {'kind': 'member', 'personId': id, 'on': false},
            ]),
            onTap: () async {
              final label = await _editFunction(
                _name(id),
                cast.functions[id] ?? '',
              );
              if (label == null || label == (cast.functions[id] ?? '')) return;
              await _apply([
                {'kind': 'member', 'personId': id, 'function': label},
              ]);
            },
          ),
      ]),
    Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          key: const ValueKey('casting-add-team'),
          onPressed: () async {
            final choice = await _choosePerson(
              cast,
              title: 'Person zum Team hinzufügen',
              exclude: cast.team.toSet(),
            );
            if (choice?.personId == null) return;
            await _apply([
              {'kind': 'member', 'personId': choice!.personId, 'on': true},
            ]);
          },
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Person hinzufügen'),
        ),
      ),
    ),
  ];

  List<Widget> _ensemble(BuildContext context, ProductionCast cast) {
    final theme = Theme.of(context);
    final people = cast.ensemble.toList()
      ..sort(
        (a, b) => normalizeName(_name(a)).compareTo(normalizeName(_name(b))),
      );
    return [
      SectionTitle('Ensemble (${people.length})'),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          'Besetzung, Regie und Team. Das Ensemble lässt sich bei Terminen, '
          'Push und Mitteilungen als Empfänger wählen.',
          style: theme.textTheme.bodySmall,
        ),
      ),
      if (people.isEmpty)
        const Text('Noch niemand zugeordnet.')
      else
        _group([
          for (final id in people)
            ListTile(
              key: ValueKey('casting-ensemble-$id'),
              leading: _avatar(id, radius: 18),
              title: Text(_name(id)),
              subtitle: Text(cast.dutiesOf(id).join(' · ')),
            ),
        ]),
    ];
  }
}

String _people(int count) => count == 1 ? '1 Person' : '$count Personen';

/// Edits a team member's function; owns its text field controller so the
/// closing animation never sees a disposed one.
class _FunctionDialog extends StatefulWidget {
  const _FunctionDialog({required this.name, required this.current});
  final String name, current;
  @override
  State<_FunctionDialog> createState() => _FunctionDialogState();
}

class _FunctionDialogState extends State<_FunctionDialog> {
  late final _text = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Funktion von ${widget.name}'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('casting-function-field'),
            controller: _text,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Funktion',
              hintText: 'z. B. Licht oder Souffleuse',
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final choice in teamFunctionChoices)
                ActionChip(
                  label: Text(choice),
                  onPressed: () => Navigator.pop(context, choice),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text),
        child: const Text('Übernehmen'),
      ),
    ],
  );
}

class _Choice {
  const _Choice(this.personId);
  final int? personId;
}

/// Read-only list of a person's productions and duties, e.g. in the person
/// editor; each entry opens the production's casting.
class PersonProductions extends StatelessWidget {
  const PersonProductions({
    super.key,
    required this.controller,
    required this.personId,
  });
  final AppController controller;
  final int personId;
  @override
  Widget build(BuildContext context) {
    final credits = creditsOf(
      controller.productionRecords.map(ProductionCast.fromRecord),
      personId,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Produktionen'),
        if (credits.isEmpty)
          Text(
            'Noch in keiner Produktion besetzt.',
            style: Theme.of(context).textTheme.bodyMedium,
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, credit) in credits.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    key: ValueKey('person-production-${credit.production.id}'),
                    leading: const Icon(Icons.theater_comedy_outlined),
                    title: Text(credit.production.title),
                    subtitle: Text(credit.duties.join(' · ')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => CastingScreen(
                          controller: controller,
                          productionId: credit.production.id,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
