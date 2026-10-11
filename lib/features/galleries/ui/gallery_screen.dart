import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/protected_image.dart';
import 'gallery_editor_screen.dart';
import 'gallery_lightbox.dart';
import 'widgets/gallery_error.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    super.key,
    required this.controller,
    required this.gallery,
  });
  final AppController controller;
  final JsonMap gallery;
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _scroll = ScrollController();
  final _assets = <JsonMap>[];
  Future<String?>? _loadTask;
  late JsonMap _gallery;
  int? _next = 0;
  int _total = 0, _loadGeneration = 0;
  bool _loading = false, _uploading = false, _hidden = false;
  String? _error, _sourceError;
  @override
  void initState() {
    super.initState();
    _gallery = widget.gallery;
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 900) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false, bool reportError = false}) async {
    if (_next == null && !refresh && !_loading) return;
    final task = _loading && !refresh
        ? _loadTask!
        : _loadTask = _fetchPage(refresh: refresh);
    final error = await task;
    if (reportError && error != null) throw ApiException(error);
  }

  Future<String?> _fetchPage({required bool refresh}) async {
    if (refresh) {
      _next = 0;
      _loadGeneration++;
    }
    final generation = _loadGeneration, offset = _next!;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.controller.remote(
        '/galleries/${_gallery['id']}?offset=$offset&limit=60&includeHidden=$_hidden',
      );
      if (!mounted || generation != _loadGeneration) return null;
      setState(() {
        if (refresh) _assets.clear();
        final ids = _assets.map((a) => a['id']).toSet();
        _assets.addAll(
          jsonList(page['assets']).map(jsonMap).where((a) => ids.add(a['id'])),
        );
        _next = page['nextOffset'] == null
            ? null
            : intValue(page['nextOffset']);
        _total = intValue(page['total']);
        _gallery = jsonMap(page['gallery']);
        _sourceError = page['sourceError'] as String?;
      });
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = e.toString());
        return e.toString();
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
    return null;
  }

  Future<void> _upload() async {
    setState(() => _uploading = true);
    var count = 0;
    try {
      final files = await ImagePicker().pickMultiImage(
        maxWidth: 2048,
        imageQuality: 85,
        requestFullMetadata: false,
        limit: 20,
      );
      for (final file in files.take(20)) {
        if (await file.length() > 8 * 1024 * 1024) {
          throw const ApiException('Ein Bild ist größer als 8 MB.');
        }
        await widget.controller.remote(
          '/media',
          method: 'POST',
          body: {
            'kind': 'gallery',
            'galleryId': _gallery['id'],
            'content': base64Encode(await file.readAsBytes()),
          },
        );
        count++;
      }
      if (mounted && count > 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$count Bilder hinzugefügt.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count Bilder hinzugefügt. $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
        await _load(refresh: true);
      }
    }
  }

  Future<void> _open(int index) async {
    await openPage(
      context,
      GalleryLightbox(
        controller: widget.controller,
        gallery: _gallery,
        assets: _assets,
        initialIndex: index,
        total: _total,
        loadMore: () => _load(reportError: true),
      ),
      fullscreen: true,
    );
    if (mounted) await _load(refresh: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(textValue(_gallery['title'])),
      actions: [
        if (widget.controller.user?.isAdmin == true)
          PopupMenuButton<String>(
            tooltip: 'Album verwalten',
            onSelected: (value) async {
              if (value == 'upload') {
                await _upload();
              }
              if (value == 'edit' && context.mounted) {
                await openPage(
                  context,
                  GalleryEditor(
                    controller: widget.controller,
                    gallery: _gallery,
                  ),
                );
                if (mounted) await _load(refresh: true);
              }
              if (value == 'publication') {
                try {
                  await widget.controller.remote(
                    '/galleries/${_gallery['id']}/visibility',
                    method: 'PUT',
                    body: {
                      'published': _gallery['published'] == false,
                      'version': _gallery['version'],
                    },
                  );
                  if (mounted) await _load(refresh: true);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              }
              if (value == 'hidden') {
                setState(() => _hidden = !_hidden);
                await _load(refresh: true);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'publication',
                child: Text(
                  _gallery['published'] == false
                      ? 'Für Ensemble freigeben'
                      : 'Freigabe beenden',
                ),
              ),
              const PopupMenuItem(
                value: 'edit',
                child: Text('Album bearbeiten'),
              ),
              PopupMenuItem(
                value: 'upload',
                enabled: !_uploading,
                child: const Text('Bilder hinzufügen'),
              ),
              PopupMenuItem(
                value: 'hidden',
                child: Text(
                  _hidden
                      ? 'Ausgeblendete verbergen'
                      : 'Ausgeblendete anzeigen',
                ),
              ),
            ],
          ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 22),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$_total Aufnahmen',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (textValue(_gallery['description']).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(textValue(_gallery['description'])),
                    ),
                  if (_sourceError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _sourceError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_uploading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) => SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: (constraints.crossAxisExtent / 170)
                      .floor()
                      .clamp(2, 6),
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemCount: _assets.length,
                itemBuilder: (context, index) {
                  final asset = _assets[index];
                  return Semantics(
                    button: true,
                    label: 'Aufnahme ${index + 1} öffnen',
                    child: InkWell(
                      onTap: () => _open(index),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ProtectedImage(
                              controller: widget.controller,
                              path: textValue(asset['path']),
                            ),
                            if (asset['type'] == 'VIDEO')
                              const Center(
                                child: Icon(
                                  Icons.play_circle_fill,
                                  color: Colors.white,
                                  size: 38,
                                ),
                              ),
                            if (asset['hidden'] == true)
                              const Align(
                                alignment: Alignment.topRight,
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.visibility_off,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: _error != null
                    ? GalleryError(message: _error!, retry: _load)
                    : _loading
                    ? const CircularProgressIndicator()
                    : _next != null
                    ? OutlinedButton(
                        onPressed: _load,
                        child: const Text('Weitere Bilder laden'),
                      )
                    : _assets.isEmpty
                    ? const Text('In diesem Album sind noch keine Bilder.')
                    : Text(
                        '${_assets.length} Aufnahmen',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
