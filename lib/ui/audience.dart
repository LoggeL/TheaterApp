import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../core/models.dart';

/// Picks the person roles that may see an item. No selection means everyone.
class AudiencePicker extends StatelessWidget {
  const AudiencePicker({
    super.key,
    required this.controller,
    required this.selected,
    required this.onChanged,
    this.label = 'Sichtbar für',
    this.allowEveryone = true,
  });
  final AppController controller;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final String label;
  final bool allowEveryone;
  @override
  Widget build(BuildContext context) {
    final roles = controller.personRoles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (allowEveryone)
              FilterChip(
                label: const Text('Alle'),
                selected: selected.isEmpty,
                onSelected: (_) => onChanged({}),
              ),
            for (final role in roles)
              FilterChip(
                label: Text(textValue(role['name'])),
                selected: selected.contains(role['id']),
                onSelected: (on) => onChanged(
                  on
                      ? {...selected, textValue(role['id'])}
                      : ({...selected}..remove(role['id'])),
                ),
              ),
          ],
        ),
        if (roles.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Lege unter Administration Rollen an, um gezielt Personen mit einer Rolle anzusprechen.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// Small label showing who an item is addressed to.
class AudienceBadge extends StatelessWidget {
  const AudienceBadge({
    super.key,
    required this.controller,
    required this.roleIds,
    this.personIds = const [],
  });
  final AppController controller;
  final List<String> roleIds;
  final List<int> personIds;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        roleIds.isEmpty && personIds.isEmpty
            ? Icons.groups_outlined
            : Icons.group_outlined,
        size: 16,
        color: Theme.of(context).colorScheme.outline,
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          controller.audienceLabel(roleIds, personIds),
          style: Theme.of(context).textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

/// Picks single people, e.g. invited to an event in addition to roles.
class PersonPicker extends StatelessWidget {
  const PersonPicker({
    super.key,
    required this.controller,
    required this.selected,
    required this.onChanged,
    this.label = 'Einzelne Personen',
  });
  final AppController controller;
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;
  final String label;

  Future<void> _choose(BuildContext context) async {
    final chosen = {...selected};
    var query = '';
    final result = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final people = controller.members
              .where(
                (m) =>
                    (m.active || chosen.contains(m.id)) &&
                    '${m.name} ${controller.roleNames(m.roleIds)}'
                        .toLowerCase()
                        .contains(query.toLowerCase()),
              )
              .toList();
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .7,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: TextField(
                      autofocus: true,
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
                        for (final m in people)
                          CheckboxListTile(
                            value: chosen.contains(m.id),
                            title: Text(m.name),
                            subtitle: m.roleIds.isEmpty
                                ? null
                                : Text(controller.roleNames(m.roleIds)),
                            onChanged: (v) => setSheetState(
                              () => v == true
                                  ? chosen.add(m.id)
                                  : chosen.remove(m.id),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, chosen),
                        child: Text('${chosen.length} übernehmen'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final m in controller.members.where(
            (m) => selected.contains(m.id),
          ))
            InputChip(
              label: Text(m.name),
              onDeleted: () => onChanged({...selected}..remove(m.id)),
              deleteButtonTooltipMessage: '${m.name} entfernen',
            ),
          ActionChip(
            avatar: const Icon(Icons.person_add_alt, size: 18),
            label: const Text('Person hinzufügen'),
            onPressed: () => _choose(context),
          ),
        ],
      ),
    ],
  );
}
