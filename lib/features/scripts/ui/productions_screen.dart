import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../shared/navigation.dart';
import 'production_card.dart';
import 'script_reader_screen.dart';
import 'widgets/reader_style.dart';

class ProductionsScreen extends StatelessWidget {
  const ProductionsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final productions = controller.activeProductions;
      final archived = controller.archivedProductions;
      return CustomScrollView(
        key: const PageStorageKey('productions'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'DEINE BÜHNE',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      letterSpacing: 2.4,
                      color: readerAccent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Drehbücher',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.08,
                      letterSpacing: -1.3,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Aktuelle Produktionen',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ReaderPill(
                        icon: Icons.menu_book_rounded,
                        label:
                            '${productions.length} ${productions.length == 1 ? 'Produktion' : 'Produktionen'}',
                      ),
                      ReaderPill(
                        icon: Icons.offline_pin_outlined,
                        label:
                            '${productions.where((p) => controller.scripts.containsKey(p.id)).length} offline verfügbar',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (archived.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              sliver: SliverToBoxAdapter(
                child: Card(
                  child: ListTile(
                    key: const ValueKey('production-archive-link'),
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: const Text('Drehbucharchiv'),
                    subtitle: Text(
                      '${archived.length} ${archived.length == 1 ? 'älteres Stück' : 'ältere Stücke'}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openPage(
                      context,
                      ProductionArchiveScreen(controller: controller),
                    ),
                  ),
                ),
              ),
            ),
          if (productions.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: ReaderEmpty(
                icon: Icons.theater_comedy_outlined,
                title: 'Kein aktuelles Stück.',
                message:
                    controller.error ??
                    (archived.isNotEmpty
                        ? 'Ältere Drehbücher findest du im Archiv.'
                        : 'Sobald eine Produktion freigegeben ist, findest du hier dein Drehbuch.'),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  Widget card(int index) {
                    final production = productions[index];
                    final cached = controller.scripts.containsKey(
                      production.id,
                    );
                    final role =
                        controller.preferences['reader.${production.id}.role']
                            as String?;
                    return ProductionCard(
                      key: ValueKey('production.${production.id}'),
                      production: production,
                      number: index + 1,
                      cached: cached,
                      role: role,
                      onTap: () => openPage(
                        context,
                        ScriptReaderScreen(
                          controller: controller,
                          productionId: production.id,
                        ),
                      ),
                    );
                  }

                  // Two equal-height cards per row on wide screens.
                  final columns =
                      constraints.crossAxisExtent >= 820 &&
                          MediaQuery.textScalerOf(context).scale(14) <= 21
                      ? 2
                      : 1;
                  return SliverList.builder(
                    itemCount: (productions.length / columns).ceil(),
                    itemBuilder: (context, row) => Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: columns == 1
                          ? card(row)
                          : IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var c = 0; c < columns; c++) ...[
                                    if (c > 0) const SizedBox(width: 16),
                                    Expanded(
                                      child:
                                          row * columns + c < productions.length
                                          ? card(row * columns + c)
                                          : const SizedBox.shrink(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                    ),
                  );
                },
              ),
            ),
        ],
      );
    },
  );
}

class ProductionArchiveScreen extends StatelessWidget {
  const ProductionArchiveScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Drehbucharchiv')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final productions = controller.archivedProductions;
        return CustomScrollView(
          slivers: [
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(24, 22, 24, 24),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'Hier findest du die Drehbücher älterer Stücke. Deine Rollen und Markierungen bleiben erhalten.',
                ),
              ),
            ),
            if (productions.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: ReaderEmpty(
                  icon: Icons.inventory_2_outlined,
                  title: 'Das Archiv ist leer.',
                  message: 'Archivierte Drehbücher erscheinen hier.',
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                sliver: SliverList.builder(
                  itemCount: productions.length,
                  itemBuilder: (context, index) {
                    final production = productions[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: ProductionCard(
                        key: ValueKey('production.${production.id}'),
                        production: production,
                        number: index + 1,
                        highlightLatest: false,
                        cached: controller.scripts.containsKey(production.id),
                        role:
                            controller
                                    .preferences['reader.${production.id}.role']
                                as String?,
                        onTap: () => openPage(
                          context,
                          ScriptReaderScreen(
                            controller: controller,
                            productionId: production.id,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    ),
  );
}
