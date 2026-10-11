import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/protected_image.dart';
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
  late Future<JsonMap> _data;
  @override
  void initState() {
    super.initState();
    _data = _fetch();
  }

  Future<JsonMap> _fetch() => widget.controller.remote('/galleries');
  Future<void> _refresh() async {
    if (!widget.controller.hasAccess || widget.controller.isDemo) return;
    final result = await _fetch();
    if (mounted && widget.controller.hasAccess) {
      setState(() => _data = Future.value(result));
    }
  }

  Future<void> _edit([JsonMap? gallery]) async {
    final changed = await openPage<bool>(
      context,
      GalleryEditor(controller: widget.controller, gallery: gallery),
    );
    if (changed == true && mounted) {
      try {
        await _refresh();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Galerien'),
      actions: [
        if (widget.controller.user?.isAdmin == true)
          IconButton(
            tooltip: 'Album freigeben',
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
          ),
      ],
    ),
    body: FutureBuilder<JsonMap>(
      future: _data,
      builder: (context, state) {
        if (state.hasError) {
          return GalleryError(message: state.error.toString(), retry: _refresh);
        }
        if (!state.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final galleries = jsonList(
          state.data!['galleries'],
        ).map(jsonMap).toList();
        return RefreshIndicator(
          onRefresh: _refresh,
          child: LayoutBuilder(
            builder: (context, size) {
              final width = size.maxWidth.clamp(0, 1150).toDouble();
              final side = (size.maxWidth - width) / 2 + 22;
              final cardWidth = width >= 800
                  ? (width - 44 - 22) / 2
                  : width - 44;
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: side, vertical: 18),
                children: [
                  Text(
                    'Alben',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  if (galleries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 60),
                      child: Text(
                        'Hier erscheinen die freigegebenen Alben.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  Wrap(
                    spacing: 22,
                    runSpacing: 22,
                    children: [
                      for (final gallery in galleries)
                        SizedBox(
                          width: cardWidth,
                          child: Card(
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () async {
                                await openPage(
                                  context,
                                  GalleryScreen(
                                    controller: widget.controller,
                                    gallery: gallery,
                                  ),
                                );
                                if (mounted && widget.controller.hasAccess) {
                                  try {
                                    await _refresh();
                                  } catch (_) {}
                                }
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AspectRatio(
                                    aspectRatio: 1.9,
                                    child: gallery['coverPath'] != null
                                        ? ProtectedImage(
                                            controller: widget.controller,
                                            path: textValue(
                                              gallery['coverPath'],
                                            ),
                                            decodeWidth: 1200,
                                          )
                                        : ColoredBox(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            child: const Icon(
                                              Icons.photo_library_outlined,
                                              size: 48,
                                            ),
                                          ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                textValue(gallery['title']),
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleLarge,
                                              ),
                                              const SizedBox(height: 5),
                                              Text(
                                                '${intValue(gallery['count'])} Aufnahmen',
                                              ),
                                              if (gallery['published'] == false)
                                                const Text(
                                                  'Nur Administration',
                                                ),
                                              if (gallery['sourceError'] !=
                                                  null)
                                                Text(
                                                  'Fotoquelle zurzeit nicht erreichbar',
                                                  style: TextStyle(
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.error,
                                                  ),
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
                          ),
                        ),
                    ],
                  ),
                  if (widget.controller.user?.isAdmin == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: OutlinedButton.icon(
                        onPressed: () => _edit(),
                        icon: const Icon(Icons.add),
                        label: const Text('Album freigeben'),
                      ),
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
