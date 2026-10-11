import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/models.dart';
import 'audience_pickers.dart';

/// Who a message or push goes to: everyone, or roles, production ensembles
/// and single people combined.
class Recipients {
  const Recipients({
    this.everyone = true,
    this.roleIds = const {},
    this.personIds = const {},
    this.productionIds = const {},
  });
  final bool everyone;
  final Set<String> roleIds, productionIds;
  final Set<int> personIds;

  bool get chosen =>
      everyone ||
      roleIds.isNotEmpty ||
      personIds.isNotEmpty ||
      productionIds.isNotEmpty;

  Recipients copyWith({
    bool? everyone,
    Set<String>? roleIds,
    Set<int>? personIds,
    Set<String>? productionIds,
  }) => Recipients(
    everyone: everyone ?? this.everyone,
    roleIds: roleIds ?? this.roleIds,
    personIds: personIds ?? this.personIds,
    productionIds: productionIds ?? this.productionIds,
  );

  List<TheaterMember> members(AppController controller) => controller
      .recipientsOf(roleIds, personIds, productionIds, everyone: everyone);

  JsonMap toJson() => {
    'audience': everyone ? 'all' : 'selected',
    'roleIds': everyone ? <String>[] : roleIds.toList(),
    'recipientPersonIds': everyone ? <int>[] : personIds.toList(),
    'productionIds': everyone ? <String>[] : productionIds.toList(),
  };
}

/// Chooses [Recipients] and shows how many people they reach.
class RecipientSelector extends StatelessWidget {
  const RecipientSelector({
    super.key,
    required this.controller,
    required this.value,
    required this.onChanged,
  });
  final AppController controller;
  final Recipients value;
  final ValueChanged<Recipients> onChanged;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reached = value.chosen ? value.members(controller).length : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: true,
              label: Text('Alle'),
              icon: Icon(Icons.groups_outlined),
            ),
            ButtonSegment(
              value: false,
              label: Text('Auswahl'),
              icon: Icon(Icons.tune),
            ),
          ],
          selected: {value.everyone},
          onSelectionChanged: (s) =>
              onChanged(value.copyWith(everyone: s.single)),
        ),
        if (!value.everyone) ...[
          const SizedBox(height: 18),
          AudiencePicker(
            controller: controller,
            label: 'An alle mit diesen Rollen',
            allowEveryone: false,
            selected: value.roleIds,
            onChanged: (ids) => onChanged(value.copyWith(roleIds: ids)),
          ),
          const SizedBox(height: 16),
          ProductionAudiencePicker(
            controller: controller,
            selected: value.productionIds,
            onChanged: (ids) => onChanged(value.copyWith(productionIds: ids)),
          ),
          const SizedBox(height: 16),
          PersonPicker(
            controller: controller,
            selected: value.personIds,
            onChanged: (ids) => onChanged(value.copyWith(personIds: ids)),
          ),
        ],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                value.chosen ? Icons.people_alt_outlined : Icons.info_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  !value.chosen
                      ? 'Bitte Rollen, Stücke und/oder Personen auswählen.'
                      : value.everyone
                      ? 'Erreicht alle $reached aktiven Personen.'
                      : 'Erreicht $reached ${reached == 1 ? 'Person' : 'Personen'}: '
                            '${controller.audienceLabel(value.roleIds, value.personIds, value.productionIds)}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
