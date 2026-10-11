import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/protected_image.dart';
import '../../../shared/widgets/state_pill.dart';
import 'gallery_editor_screen.dart';
import 'gallery_screen.dart';
import 'widgets/gallery_error.dart';

class GalleryListScreen extends StatefulWidget {
  const GalleryListScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<GalleryListScreen> createState() => _GalleryListScreenState();
}

class _GalleryListScreenState extends State<GalleryListScreen> {
  // Null in the demo: galleries live on the theatre's server only.
  Future<JsonMap>? _data;

  bool get _admin =>
      widget.controller.user?.isAdmin == true && !widget.controller.isDemo;

  @override
  void initState() {
    super.initState();
    if (!widget.controller.isDemo) _data = _fetch();
  }

  Future<JsonMap> _fetch() => widget.controller.remote('/galleries');

  Future<void> _refresh() async {
    if (!widget.controller.hasAccess || widget.controller.isDemo) return;
    final result = await _fetch();
    if (mounted && widget.controller.hasAccess) {
      setState(() {
        _data = Future.value(result);
      });
    }
  }

  /// Pull to refresh keeps the albums visible and reports a failure.
  Future<void> _pullToRefresh() async {
    try {
      await _refresh();
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  /// Refreshes quietly after returning from an album or the editor.
  Future<void> _quietRefresh() async {
    try {
      await _refresh();
    } catch (_) {}
  }

  Future<void> _edit([JsonMap? gallery]) async {
    final changed = await openPage<bool>(
      context,
      GalleryEditor(controller: widget.controller, gallery: gallery),
    );
    if (changed == true && mounted) await _quietRefresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Galerien')),
    floatingActionButton: _admin
        ? FloatingActionButton.extended(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Album anlegen'),
          )
        : null,
    body: _data == null
        ? const Center(
            child: SingleChildScrollView(
              child: EmptyState(
                icon: Icons.photo_library_outlined,
                title: 'Galerien nur mit Theaterkonto',
                message:
                    'Die Fotoalben liegen auf dem Server deines Theaters. In der Demo gibt es keine Bilder.',
              ),
            ),
          )
        : FutureBuilder<JsonMap>(
            future: _data,
            builder: (context, state) {
              if (state.hasError) {
                return GalleryError(
                  message: userMessage(state.error!),
                  retry: () async => setState(() {
                    _data = _fetch();
                  }),
                );
              }
              if (!state.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final galleries = jsonList(
                state.data!['galleries'],
              ).map(jsonMap).toList();
              return RefreshIndicator(
                onRefresh: _pullToRefresh,
                child: LayoutBuilder(
                  builder: (context, size) {
                    final width = size.maxWidth.clamp(0, 1150).toDouble();
                    final side = (size.maxWidth - width) / 2 + 22;
                    final cardWidth = width >= 800
                        ? (width - 44 - 22) / 2
                        : width - 44;
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        side,
                        18,
                        side,
                        _admin ? 96 : 18,
                      ),
                      children: [
                        Text(
                          'Alben',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 24),
                        if (galleries.isEmpty)
                          EmptyState(
                            icon: Icons.photo_library_outlined,
                            title: 'Noch keine Alben',
                            message: _admin
                                ? 'Lege ein Album an, um Bilder mit dem Ensemble zu teilen.'
                                : 'Hier erscheinen die freigegebenen Alben.',
                          ),
                        Wrap(
                          spacing: 22,
                          runSpacing: 22,
                          children: [
                            for (final gallery in galleries)
                              SizedBox(
                                width: cardWidth,
                                child: _GalleryCard(
                                  controller: widget.controller,
                                  gallery: gallery,
                                  onTap: () async {
                                    await openPage(
                                      context,
                                      GalleryScreen(
                                        controller: widget.controller,
                                        gallery: gallery,
                                      ),
                                    );
                                    if (mounted) await _quietRefresh();
                                  },
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              );
            },
          ),
  );
}

class _GalleryCard extends StatelessWidget {
  const _GalleryCard({
    required this.controller,
    required this.gallery,
    required this.onTap,
  });
  final AppController controller;
  final JsonMap gallery;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = intValue(gallery['count']);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1.9,
              child: gallery['coverPath'] != null
                  ? ProtectedImage(
                      controller: controller,
                      path: textValue(gallery['coverPath']),
                      decodeWidth: 1200,
                    )
                  : ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.photo_library_outlined, size: 48),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          textValue(gallery['title']),
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 5),
                        Text(count == 1 ? '1 Aufnahme' : '$count Aufnahmen'),
                        if (gallery['published'] == false)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: StatePill(
                              'Nur für Administration sichtbar',
                              color: StageTheme.violet,
                              icon: Icons.visibility_off_outlined,
                            ),
                          ),
                        if (gallery['sourceError'] != null)
                          Text(
                            'Fotoquelle zurzeit nicht erreichbar',
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
