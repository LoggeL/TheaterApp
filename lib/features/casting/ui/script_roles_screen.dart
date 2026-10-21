import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';
import '../domain/casting.dart';
import 'casting_screen.dart';

/// "Drehbuchrollen": every script role of the current productions with its
/// casting, so roles nobody plays yet stand out. Each row opens the
/// production's casting.
class ScriptRolesScreen extends StatefulWidget {
  const ScriptRolesScreen({
    super.key,
    required this.controller,
    this.initialFilter = 'all',
  });
  final AppController controller;

  /// `all` or `unassigned` (roles without a cast person).
  final String initialFilter;
  @override
  State<ScriptRolesScreen> createState() => _ScriptRolesScreenState();
}

class _ScriptRolesScreenState extends State<ScriptRolesScreen> {
  late String _filter = widget.initialFilter == 'unassigned'
      ? 'unassigned'
      : 'all';
  String _query = '';

  bool _matches(Iterable<String> values) {
    final haystack = values.join(' ').toLowerCase();
    return _query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .every(haystack.contains);
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Drehbuchrollen',
    children: (context) {
      final names = {
        for (final m in widget.controller.memberRecords)
          intValue(m['id']): textValue(m['name']),
      };
      final casts = widget.controller.productionRecords
          .where((p) => p['archived'] != true)
          .map(ProductionCast.fromRecord)
          .toList();
      final all = [
        for (final p in casts)
          for (final r in p.roles) (production: p, role: r),
      ];
      final open = all.where((x) => !x.production.isCast(x.role.id)).length;
      final shown = all.where((x) {
        final person = x.production.personFor(x.role.id);
        if (_filter == 'unassigned' && person != null) return false;
        return _matches([
          x.role.name,
          x.role.actor,
          x.production.title,
          if (person != null) names[person] ?? '',
        ]);
      }).toList();
      return [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Rolle, Stück oder Person suchen',
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (key, label) in [
              ('all', 'Alle Drehbuchrollen (${all.length})'),
              ('unassigned', 'Ohne Besetzung ($open)'),
            ])
              FilterChip(
                key: ValueKey('script-roles-$key'),
                label: Text(label),
                selected: _filter == key,
                onSelected: (_) => setState(() => _filter = key),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Text(
            shown.length == 1
                ? '1 Drehbuchrolle'
                : '${shown.length} Drehbuchrollen',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (shown.isEmpty)
          EmptyState(
            icon: Icons.search_off,
            title: all.isEmpty
                ? 'Noch keine Drehbuchrollen'
                : _filter == 'unassigned' && _query.trim().isEmpty
                ? 'Alle Rollen besetzt'
                : 'Keine Treffer',
            message: all.isEmpty
                ? 'Rollen kommen mit dem Drehbuch einer Produktion.'
                : 'Passe die Suche oder den Filter an.',
          ),
        for (final (:production, :role) in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                title: Text(role.name),
                subtitle: Text(
                  '${production.title}\n${switch (production.personFor(role.id)) {
                    final id? => names[id] ?? 'Unbekannte Person',
                    null when role.actor.isEmpty => 'Ohne Einzelbesetzung',
                    null => 'Besetzung offen · Skript: ${role.actor}',
                  }}',
                ),
                trailing: IconButton(
                  tooltip: 'Besetzung bearbeiten',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => openPage(
                    context,
                    CastingScreen(
                      controller: widget.controller,
                      productionId: production.id,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ];
    },
  );
}
