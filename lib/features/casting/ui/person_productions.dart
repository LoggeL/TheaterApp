import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/page_header.dart';
import '../domain/casting.dart';
import 'casting_screen.dart';

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
                    onTap: () => openPage(
                      context,
                      CastingScreen(
                        controller: controller,
                        productionId: credit.production.id,
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
