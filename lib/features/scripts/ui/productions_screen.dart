import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/breakpoints.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../domain/script_roles.dart';
import 'production_card.dart';
import 'script_reader_screen.dart';

class ProductionsScreen extends StatelessWidget {
  const ProductionsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final productions = controller.activeProductions;
      final archived = controller.archivedProductions;
      final failed =
          productions.isEmpty && archived.isEmpty && controller.error != null;
      Future<void> refresh() => refreshWithFeedback(context, controller);
      return RefreshIndicator(
        onRefresh: refresh,
        child: CustomScrollView(
          key: const PageStorageKey('productions'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const PageHeader(
                      'Drehbücher.',
                      eyebrow: 'Deine Bühne',
                      subtitle: 'Aktuelle Produktionen',
                    ),
                    if (!failed)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          StatePill(
                            '${productions.length} ${productions.length == 1 ? 'Produktion' : 'Produktionen'}',
                            icon: Icons.menu_book_rounded,
                            color: StageTheme.violet,
                          ),
                          StatePill(
                            '${productions.where((p) => controller.scripts.containsKey(p.id)).length} offline verfügbar',
                            icon: Icons.offline_pin_outlined,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            if (failed)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: EmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Drehbücher konnten nicht geladen werden.',
                    message: controller.error!,
                    action: FilledButton.icon(
                      onPressed: refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Erneut versuchen'),
                    ),
                  ),
                ),
              )
            else if (productions.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: EmptyState(
                    icon: Icons.theater_comedy_outlined,
                    title: 'Kein aktuelles Stück.',
                    message: archived.isNotEmpty
                        ? 'Ältere Drehbücher findest du im Archiv.'
                        : 'Sobald eine Produktion freigegeben ist, findest du hier dein Drehbuch.',
                    action: archived.isEmpty
                        ? null
                        : ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: _ArchiveLink(
                              controller: controller,
                              count: archived.length,
                            ),
                          ),
                  ),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    Widget card(int index) {
                      final production = productions[index];
                      return ProductionCard(
                        key: ValueKey('production.${production.id}'),
                        production: production,
                        number: index + 1,
                        cached: controller.scripts.containsKey(production.id),
                        roles: cardRoleNames(
                          production,
                          controller.preferences,
                          controller.user?.personId,
                        ),
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
                        constraints.crossAxisExtent >=
                                Breakpoints.productionsTwoColumn &&
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (var c = 0; c < columns; c++) ...[
                                      if (c > 0) const SizedBox(width: 16),
                                      Expanded(
                                        child:
                                            row * columns + c <
                                                productions.length
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
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 110),
                sliver: SliverToBoxAdapter(
                  child: archived.isEmpty
                      ? const SizedBox.shrink()
                      : _ArchiveLink(
                          controller: controller,
                          count: archived.length,
                        ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// The entry to older, archived scripts.
class _ArchiveLink extends StatelessWidget {
  const _ArchiveLink({required this.controller, required this.count});
  final AppController controller;
  final int count;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: const ValueKey('production-archive-link'),
      leading: const Icon(Icons.inventory_2_outlined),
      title: const Text('Drehbucharchiv'),
      subtitle: Text(
        '$count ${count == 1 ? 'älteres Stück' : 'ältere Stücke'}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () =>
          openPage(context, ProductionArchiveScreen(controller: controller)),
    ),
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
                child: Center(
                  child: EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'Das Archiv ist leer.',
                    message: 'Archivierte Drehbücher erscheinen hier.',
                  ),
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
                        roles: cardRoleNames(
                          production,
                          controller.preferences,
                          controller.user?.personId,
                        ),
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
