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
              'Lege unter Administration Rollen an, um gezielt Gruppen anzusprechen.',
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
  });
  final AppController controller;
  final List<String> roleIds;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        roleIds.isEmpty ? Icons.groups_outlined : Icons.group_outlined,
        size: 16,
        color: Theme.of(context).colorScheme.outline,
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          controller.audienceLabel(roleIds),
          style: Theme.of(context).textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}
