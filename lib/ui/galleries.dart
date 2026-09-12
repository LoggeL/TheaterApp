import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_saver/file_saver.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import '../data/api_client.dart';
import 'profile.dart';
import 'theme.dart';

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
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GalleryEditor(controller: widget.controller, gallery: gallery),
      ),
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
          return _GalleryError(
            message: state.error.toString(),
            retry: _refresh,
          );
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
            builder: (context, constraints) => ListView(
              padding: EdgeInsets.symmetric(
                horizontal: constraints.maxWidth > 900
                    ? (constraints.maxWidth - 850) / 2
                    : 22,
                vertical: 18,
              ),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const Eyebrow('Auf und hinter der Bühne'),
                const SizedBox(height: 10),
                Text(
                  'Unsere Erinnerungen.',
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
                for (final gallery in galleries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 22),
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => GalleryScreen(
                                controller: widget.controller,
                                gallery: gallery,
                              ),
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
                                      path: textValue(gallery['coverPath']),
                                      decodeWidth: 1000,
                                    )
                                  : ColoredBox(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
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
                                          const Text('Nur Administration'),
                                        if (gallery['sourceError'] != null)
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
                if (widget.controller.user?.isAdmin == true)
                  OutlinedButton.icon(
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add),
                    label: const Text('Album freigeben'),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class GalleryEditor extends StatefulWidget {
  const GalleryEditor({super.key, required this.controller, this.gallery});
  final AppController controller;
  final JsonMap? gallery;
  @override
  State<GalleryEditor> createState() => _GalleryEditorState();
}

class _GalleryEditorState extends State<GalleryEditor> {
  late final TextEditingController _title, _description, _url;
  String? _production, _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    final g = widget.gallery ?? {};
    _title = TextEditingController(text: textValue(g['title']));
    _description = TextEditingController(text: textValue(g['description']));
    _url = TextEditingController(text: textValue(g['sourceUrl']));
    _production = g['productionId'] as String?;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Bitte einen Titel eingeben.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.remote(
        '/galleries',
        method: 'POST',
        body: {
          ...?widget.gallery,
          'title': _title.text,
          'description': _description.text,
          'sourceUrl': _url.text,
          'productionId': _production,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.gallery == null ? 'Album freigeben' : 'Album bearbeiten',
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _title,
          enabled: !_busy,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Albumtitel'),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _url,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Immich-Freigabelink',
            hintText: 'https://photo.rittmann.cloud/s/…',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Ohne Freigabelink kannst du eigene Bilder hochladen.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(
          initialValue:
              widget.controller.productions.any((p) => p.id == _production)
              ? _production
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Stück'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Ohne Zuordnung')),
            for (final p in widget.controller.productions)
              DropdownMenuItem(
                value: p.id,
                child: Text(p.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _busy
              ? null
              : (v) => _production = v?.isEmpty == true ? null : v,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _description,
          enabled: !_busy,
          minLines: 2,
          maxLines: 5,
          maxLength: 2000,
          decoration: const InputDecoration(labelText: 'Beschreibung'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(
            _busy
                ? 'Album wird geprüft …'
                : widget.gallery == null
                ? 'Für das Ensemble freigeben'
                : 'Speichern',
          ),
        ),
      ],
    ),
  );
}

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

  Future<void> _load({bool refresh = false}) async {
    if (_loading && !refresh || _next == null && !refresh) return;
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
      if (!mounted || generation != _loadGeneration) return;
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
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
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
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GalleryLightbox(
          controller: widget.controller,
          gallery: _gallery,
          assets: _assets,
          initialIndex: index,
          total: _total,
          loadMore: _load,
        ),
      ),
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
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GalleryEditor(
                      controller: widget.controller,
                      gallery: _gallery,
                    ),
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
                    ? _GalleryError(message: _error!, retry: _load)
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

class GalleryLightbox extends StatefulWidget {
  const GalleryLightbox({
    super.key,
    required this.controller,
    required this.gallery,
    required this.assets,
    required this.initialIndex,
    required this.total,
    required this.loadMore,
  });
  final AppController controller;
  final JsonMap gallery;
  final List<JsonMap> assets;
  final int initialIndex, total;
  final Future<void> Function() loadMore;
  @override
  State<GalleryLightbox> createState() => _GalleryLightboxState();
}

class _GalleryLightboxState extends State<GalleryLightbox> {
  late final PageController _pages;
  late int _index;
  bool _saving = false, _paging = false;
  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index);
    _more();
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _more() async {
    if (_paging ||
        _index < widget.assets.length - 8 ||
        widget.assets.length >= widget.total) {
      return;
    }
    _paging = true;
    try {
      await widget.loadMore();
    } finally {
      _paging = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _download(JsonMap asset) async {
    setState(() => _saving = true);
    try {
      final file = await widget.controller.mediaBytes(
        '${asset['path']}/original',
        cache: false,
      );
      if (!mounted) return;
      final extension =
          {
            'image/jpeg': 'jpg',
            'image/png': 'png',
            'image/webp': 'webp',
            'image/avif': 'avif',
            'image/heic': 'heic',
            'image/heif': 'heif',
            'image/tiff': 'tiff',
          }[file.mime] ??
          'img';
      final result = await FileSaver.instance.saveAs(
        name: 'Theater-${asset['id']}',
        bytes: file.bytes,
        fileExtension: extension,
        mimeType: MimeType.custom,
        customMimeType: file.mime,
      );
      if (mounted && result != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(kIsWeb ? 'Download gestartet.' : 'Bild gespeichert.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.assets[_index];
    final date = dateValue(asset['date']);
    final video = asset['type'] == 'VIDEO';
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: const Color(0xFF101311),
        appBar: AppBar(
          backgroundColor: const Color(0xFF101311),
          title: Text('${_index + 1} / ${widget.total}'),
          actions: [
            if (asset['canDownload'] == true && !video)
              IconButton(
                tooltip: textValue(asset['id']).startsWith('local-')
                    ? 'Bild herunterladen'
                    : 'Original herunterladen',
                onPressed: _saving ? null : () => _download(Map.of(asset)),
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
              ),
            if (widget.controller.user?.isAdmin == true &&
                textValue(asset['id']).startsWith('local-'))
              IconButton(
                tooltip: asset['hidden'] == true
                    ? 'Bild einblenden'
                    : 'Bild ausblenden',
                onPressed: () async {
                  try {
                    await widget.controller.remote(
                      '/media/${textValue(asset['id']).substring(6)}/visibility',
                      method: 'PUT',
                      body: {'hidden': asset['hidden'] != true},
                    );
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(e.toString())));
                    }
                  }
                },
                icon: Icon(
                  asset['hidden'] == true
                      ? Icons.visibility
                      : Icons.visibility_off_outlined,
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: widget.assets.length,
                onPageChanged: (value) {
                  setState(() => _index = value);
                  _more();
                },
                itemBuilder: (context, index) => InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: ProtectedImage(
                    controller: widget.controller,
                    path: textValue(widget.assets[index]['previewPath']),
                    fit: BoxFit.contain,
                    decodeWidth: 1800,
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
                child: Column(
                  children: [
                    if (video)
                      TextButton.icon(
                        onPressed: () async {
                          final url = Uri.tryParse(
                            textValue(widget.gallery['sourceUrl']),
                          );
                          if (url != null) {
                            try {
                              if (!await launchUrl(
                                url,
                                mode: LaunchMode.externalApplication,
                              )) {
                                throw StateError('unavailable');
                              }
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Das Originalalbum konnte nicht geöffnet werden.',
                                    ),
                                  ),
                                );
                              }
                            }
                          }
                        },
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('Video im Originalalbum öffnen'),
                      ),
                    if (textValue(asset['caption']).isNotEmpty)
                      Text(
                        textValue(asset['caption']),
                        textAlign: TextAlign.center,
                      ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Vorheriges Bild',
                          onPressed: _index > 0
                              ? () => _pages.previousPage(
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOut,
                                )
                              : null,
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Expanded(
                          child: Text(
                            date == null
                                ? ''
                                : DateFormat.yMMMd('de').format(date.toLocal()),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Nächstes Bild',
                          onPressed: _index + 1 < widget.assets.length
                              ? () => _pages.nextPage(
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOut,
                                )
                              : _index + 1 < widget.total
                              ? () async {
                                  await _more();
                                  if (mounted &&
                                      _index + 1 < widget.assets.length) {
                                    _pages.nextPage(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      curve: Curves.easeOut,
                                    );
                                  }
                                }
                              : null,
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GalleryError extends StatelessWidget {
  const _GalleryError({required this.message, required this.retry});
  final String message;
  final Future<void> Function() retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              try {
                await retry();
              } catch (_) {}
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Erneut laden'),
          ),
        ],
      ),
    ),
  );
}
