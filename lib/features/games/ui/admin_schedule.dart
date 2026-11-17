part of 'admin_skin_viewer.dart';

/// The entries of the catalog's [AdminSchedule] as a grid of numbered cards.
class AdminSchedulePage extends StatelessWidget {
  const AdminSchedulePage({
    super.key,
    required this.catalog,
    required this.art,
    required this.controller,
    required this.onOpen,
  });

  final AdminSkinCatalog catalog;
  final RunnerArt? art;
  final AppController controller;
  final void Function(BuildContext, AdminSkin) onOpen;

  @override
  Widget build(BuildContext context) => _adminView(controller, _page);

  Widget _page(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(catalog.schedule.title)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: LayoutBuilder(
              builder: (context, bounds) {
                final scaler = MediaQuery.textScalerOf(context);
                final minWidth = 154 * max(1.0, scaler.scale(14) / 14);
                final columns = (bounds.maxWidth / minWidth).floor().clamp(
                  1,
                  6,
                );
                final width =
                    (bounds.maxWidth - 32 - (columns - 1) * 10) / columns;
                final label = theme.textTheme.titleSmall;
                final metrics = TextPainter(
                  text: TextSpan(text: 'Ag', style: label),
                  textDirection: Directionality.of(context),
                  textScaler: scaler,
                );
                final caption = metrics.preferredLineHeight.ceilToDouble() * 3;
                metrics.dispose();
                return CustomScrollView(
                  key: const PageStorageKey('admin-schedule'),
                  slivers: [
                    if (catalog.schedule.heading.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
                        sliver: SliverToBoxAdapter(
                          child: Text(
                            catalog.schedule.heading,
                            style: theme.textTheme.headlineSmall,
                          ),
                        ),
                      )
                    else
                      const SliverPadding(padding: EdgeInsets.only(top: 16)),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          mainAxisExtent: width + caption + 20,
                        ),
                        itemCount: catalog.schedule.entries.length,
                        itemBuilder: (context, index) {
                          final entry = catalog.schedule.entries[index];
                          return Semantics(
                            button: true,
                            label:
                                '${catalog.schedule.unit} ${entry.day}, ${entry.title}',
                            child: Card(
                              key: ValueKey('schedule-entry-${entry.day}'),
                              margin: EdgeInsets.zero,
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => onOpen(context, entry.skin),
                                child: ExcludeSemantics(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      AspectRatio(
                                        aspectRatio: 1,
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            DecoratedBox(
                                              decoration: const BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                  colors: [
                                                    Color(0xFF573048),
                                                    Color(0xFF212025),
                                                  ],
                                                ),
                                              ),
                                              child: WardrobeItemArt(
                                                item: entry.skin.item,
                                                controller: controller,
                                                art: art,
                                                small: true,
                                              ),
                                            ),
                                            Positioned(
                                              left: 6,
                                              top: 6,
                                              child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFFFAE6BA,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 7,
                                                        vertical: 2,
                                                      ),
                                                  child: Text(
                                                    '${entry.day}',
                                                    style: theme
                                                        .textTheme
                                                        .titleSmall
                                                        ?.copyWith(
                                                          color: const Color(
                                                            0xFF3E1526,
                                                          ),
                                                          fontWeight:
                                                              FontWeight.w800,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Text(
                                          entry.title,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: label,
                                        ),
                                      ),
                                    ],
                                  ),
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
          ),
        ),
      ),
    );
  }
}
