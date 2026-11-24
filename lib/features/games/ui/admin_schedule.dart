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
                final entries = catalog.schedule.entries;
                final total = entries.length;
                final withoutPic = entries
                    .where((e) => _withoutPicture(e.skin.item))
                    .length;
                final disabled = entries.where((e) => e.skin.disabled).length;
                final ready = entries
                    .where(
                      (e) => !e.skin.disabled && !_withoutPicture(e.skin.item),
                    )
                    .length;
                final summary = [
                  '$ready/$total bereit',
                  if (withoutPic > 0) '$withoutPic ohne Bild',
                  if (disabled > 0) '$disabled deaktiviert',
                ].join(' · ');
                return CustomScrollView(
                  key: const PageStorageKey('admin-schedule'),
                  scrollCacheExtent: kIsWeb
                      ? const ScrollCacheExtent.pixels(300)
                      : null,
                  slivers: [
                    if (catalog.schedule.heading.isNotEmpty || total > 0)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (catalog.schedule.heading.isNotEmpty)
                                Text(
                                  catalog.schedule.heading,
                                  style: theme.textTheme.headlineSmall,
                                ),
                              if (total > 0) ...[
                                if (catalog.schedule.heading.isNotEmpty)
                                  const SizedBox(height: 4),
                                Text(
                                  summary,
                                  key: const ValueKey('schedule-summary'),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
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
                          mainAxisExtent: width + caption + 24,
                        ),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          final item = entry.skin.item;
                          final placeholder = _placeholderOf(entry.skin);
                          final noPic = _withoutPicture(item);
                          final colors = rarityColors(catalog.catalog, item);
                          return Semantics(
                            button: true,
                            label:
                                '${catalog.schedule.unit} ${entry.day}, ${entry.title}, ${statusText(entry.skin)}',
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
                                              child: placeholder
                                                  ? _PicturePlaceholder(
                                                      item: item,
                                                    )
                                                  : WardrobeItemArt(
                                                      item: item,
                                                      controller: controller,
                                                      art: art,
                                                      antique: catalog.catalog
                                                          .rarityOf(item)
                                                          .antique,
                                                      small: true,
                                                    ),
                                            ),
                                            Positioned(
                                              left: 6,
                                              top: 6,
                                              right: 6,
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  DecoratedBox(
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                        0xFFFAE6BA,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            6,
                                                          ),
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
                                                              color:
                                                                  const Color(
                                                                    0xFF3E1526,
                                                                  ),
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Expanded(
                                                    child: Align(
                                                      alignment:
                                                          Alignment.topRight,
                                                      child: _StatusBadge(
                                                        entry.skin,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (noPic && !placeholder)
                                              const Positioned(
                                                right: 6,
                                                bottom: 6,
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    color: Color(0xCC000000),
                                                    borderRadius:
                                                        BorderRadius.all(
                                                          Radius.circular(6),
                                                        ),
                                                  ),
                                                  child: Padding(
                                                    padding:
                                                        EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 2,
                                                        ),
                                                    child: Text(
                                                      'ohne Bild',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 10.5,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        height: 4,
                                        decoration: BoxDecoration(
                                          gradient: item.unique
                                              ? holoGradient
                                              : rarityGradient(colors),
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
