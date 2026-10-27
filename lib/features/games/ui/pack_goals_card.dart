import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../data/wardrobe_api.dart';
import 'wardrobe_cards.dart' show kmText;

/// The shared goals for released skin packs and the contributor's set crates.
class PackGoalsCard extends StatelessWidget {
  const PackGoalsCard({super.key, required this.goals, this.onOpen});

  final List<PackGoal> goals;
  final ValueChanged<PackGoal>? onOpen;

  @override
  Widget build(BuildContext context) {
    if (goals.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final current = [
      ...goals.where((goal) => goal.crates > 0),
      ...goals.where((goal) => !goal.reached && goal.crates == 0),
    ];
    final completed = goals
        .where((goal) => goal.reached && goal.crates == 0)
        .toList();
    return Card(
      key: const ValueKey('runner-pack-goals'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.checkroom, color: StageTheme.orange),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    current.isEmpty ? 'Skinpacks' : 'Neue Skinpacks',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            for (final (index, goal) in current.indexed) ...[
              if (index > 0) const Divider(height: 32),
              _goal(context, goal),
            ],
            if (completed.isNotEmpty) ...[
              if (current.isNotEmpty) const SizedBox(height: 12),
              ExpansionTile(
                key: const PageStorageKey('pack-completed-goals'),
                tilePadding: EdgeInsets.zero,
                title: const Text('Abgeschlossene Ziele'),
                subtitle: Text(
                  completed.length == 1
                      ? '1 Skinpack'
                      : '${completed.length} Skinpacks',
                ),
                children: [
                  for (final (index, goal) in completed.indexed) ...[
                    if (index > 0) const Divider(height: 32),
                    _goal(context, goal),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _goal(BuildContext context, PackGoal goal) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('pack-goal-${goal.releaseId}'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(goal.name, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: goal.fraction,
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
            semanticsLabel:
                '${goal.name}: ${kmText(goal.meters)} von ${kmText(goal.goalMeters)}',
            semanticsValue: '${(goal.fraction * 100).round()}%',
          ),
          const SizedBox(height: 8),
          Text(
            goal.reached
                ? 'Ensembleziel erreicht: ${kmText(goal.goalMeters)}'
                : '${kmText(goal.meters)} von ${kmText(goal.goalMeters)} gemeinsam',
          ),
          if (!goal.reached)
            Text('Noch ${kmText(goal.remaining)} bis zum Ziel.'),
          const SizedBox(height: 6),
          Text(
            'Dein Beitrag: ${kmText(goal.contributionMeters)} · '
            '${goal.contributors} ${goal.contributors == 1 ? 'Person' : 'Personen'} dabei',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            '${goal.crateCount} Set-Kisten für alle, die bis zum Erreichen des Ziels mitlaufen. '
            'Die Kisten enthalten nur Figuren aus diesem Skinpack.',
            style: theme.textTheme.bodySmall,
          ),
          if (goal.crates > 0) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: ValueKey('open-pack-${goal.releaseId}'),
              onPressed: onOpen == null ? null : () => onOpen!(goal),
              icon: const Icon(Icons.inventory_2_outlined),
              label: Text(
                goal.crates == 1
                    ? '1 Set-Kiste öffnen'
                    : '${goal.crates} Set-Kisten bereit',
              ),
            ),
          ] else if (goal.reached) ...[
            const SizedBox(height: 8),
            Text(
              goal.eligible
                  ? 'Deine Set-Kisten sind geöffnet.'
                  : goal.contributionMeters > 0
                  ? 'Für dieses abgeschlossene Ziel sind keine Set-Kisten verfügbar.'
                  : 'Für dieses abgeschlossene Ziel ist kein eigener Beitrag erfasst.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
