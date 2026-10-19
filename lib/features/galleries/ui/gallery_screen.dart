import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';
import '../../../shared/feedback.dart';
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
    this.pickImages,
    this.wait,
  });
  final AppController controller;
  final JsonMap gallery;

  /// Chooses the images to upload; tests replace the system picker.
  final Future<List<XFile>> Function()? pickImages;

  /// Waits before another upload attempt; tests skip the real delay.
  final Future<void> Function(Duration)? wait;
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _scroll = ScrollController();
  final _assets = <JsonMap>[];

  /// Images of earlier uploads that did not reach the server yet.
  final _unsent = <XFile>[];
  Future<String?>? _loadTask;
  late JsonMap _gallery;
  int? _next = 0;
  int _total = 0, _loadGeneration = 0, _uploadDone = 0, _uploadTotal = 0;
  bool _loading = false, _uploading = false, _hidden = false;
  String? _error, _sourceError, _uploadNote;
  @override
  void initState() {
    super.initState();
    _gallery = widget.gallery;
    // After a failed page only "Erneut laden" (or pulling down) tries again,
    // so scrolling offline does not start one request after another.
    _scroll.addListener(() {
      if (_error == null && !_loading && _scroll.position.extentAfter < 900) {
        _load();
      }
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
        final message = userMessage(e);
        setState(() => _error = message);
        return message;
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
    return null;
  }

  bool get _admin => widget.controller.user?.isAdmin == true;

  Future<void> _upload() async {
    final List<XFile> picked;
    try {
      picked = (await (widget.pickImages ?? _pickFromDevice)())
          .take(20)
          .toList();
    } catch (e) {
      if (mounted) showProblem(context, e);
      return;
    }
    if (picked.isEmpty || !mounted) return;
    await _uploadFiles(picked);
  }

  Future<List<XFile>> _pickFromDevice() => ImagePicker().pickMultiImage(
    maxWidth: 2048,
    imageQuality: 85,
    requestFullMetadata: false,
    limit: 20,
  );

  Future<void> _uploadUnsent() async {
    final files = List.of(_unsent);
    setState(_unsent.clear);
    await _uploadFiles(files);
  }

  static const _uploadAttempts = 5, _maxUploadWait = Duration(seconds: 30);

  /// Uploads one by one. A file the server rejects (format, size) is
  /// counted and the next one follows; any other failure stops and keeps
  /// this and all later files for "Rest erneut hochladen".
  Future<void> _uploadFiles(List<XFile> files) async {
    setState(() {
      _uploading = true;
      _uploadDone = 0;
      _uploadTotal = files.length;
      _uploadNote = null;
    });
    var added = 0, skipped = 0, rejected = 0;
    final unsent = <XFile>[];
    Object? failure;
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      try {
        if (await file.length() > 8 * 1024 * 1024) {
          skipped++;
        } else {
          await _send(file);
          added++;
        }
      } on ApiException catch (e) {
        failure = e;
        if (e.statusCode == 400 || e.statusCode == 413) {
          rejected++;
        } else {
          unsent.addAll(files.skip(i));
          break;
        }
      } catch (e) {
        // The picked file itself could not be read.
        failure = e;
        rejected++;
      }
      if (mounted) setState(() => _uploadDone++);
    }
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _uploadNote = null;
      _unsent.addAll(unsent);
    });
    String count(int n, String one, String many) => n == 1 ? one : '$n $many';
    final summary = [
      count(added, '1 Bild hinzugefügt', 'Bilder hinzugefügt'),
      if (skipped > 0)
        count(
          skipped,
          '1 Bild über 8 MB übersprungen',
          'Bilder über 8 MB übersprungen',
        ),
      if (rejected > 0) count(rejected, '1 Bild abgelehnt', 'Bilder abgelehnt'),
      if (unsent.isNotEmpty)
        count(
          unsent.length,
          '1 Bild nicht hochgeladen',
          'Bilder nicht hochgeladen',
        ),
    ].join(' · ');
    // A new summary replaces the one of an earlier round.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            failure == null ? '$summary.' : '$summary. ${userMessage(failure)}',
          ),
          duration: Duration(seconds: failure == null && skipped == 0 ? 4 : 8),
        ),
      );
    if (added > 0) await _load(refresh: true);
  }

  /// Sends one image. "Busy" (429) and an unavailable server are tried again
  /// after the server's Retry-After or a growing pause. Lost connections are
  /// not, since the server may already have stored the image.
  Future<void> _send(XFile file) async {
    final body = {
      'kind': 'gallery',
      'galleryId': _gallery['id'],
      'content': base64Encode(await file.readAsBytes()),
    };
    for (var attempt = 1; ; attempt++) {
      try {
        await widget.controller.remote('/media', method: 'POST', body: body);
        if (mounted && _uploadNote != null) {
          setState(() => _uploadNote = null);
        }
        return;
      } on ApiException catch (e) {
        final temporary =
            (e.statusCode == 429 && e.code != 'upload_limit') ||
            const {502, 503, 504}.contains(e.statusCode);
        if (!temporary || attempt >= _uploadAttempts) rethrow;
        var pause = e.retryAfter ?? Duration(seconds: 1 << (attempt - 1));
        if (pause > _maxUploadWait) pause = _maxUploadWait;
        if (mounted) {
          setState(
            () => _uploadNote = e.statusCode == 429
                ? 'Der Server verarbeitet gerade andere Bilder. Neuer Versuch gleich …'
                : 'Der Server ist kurz nicht erreichbar. Neuer Versuch gleich …',
          );
        }
        await (widget.wait ?? Future<void>.delayed)(pause);
      }
    }
  }

  Future<void> _togglePublication() async {
    final publish = _gallery['published'] == false;
    if (!publish) {
      final confirmed = await confirmDestructive(
        context,
        title: 'Freigabe beenden?',
        message:
            'Das Ensemble sieht das Album danach nicht mehr. Nur die Administration kann es weiter öffnen.',
        confirmLabel: 'Freigabe beenden',
      );
      if (!confirmed || !mounted) return;
    }
    try {
      await widget.controller.remote(
        '/galleries/${_gallery['id']}/visibility',
        method: 'PUT',
        body: {'published': publish, 'version': _gallery['version']},
      );
      if (!mounted) return;
      showDone(
        context,
        publish
            ? 'Album für das Ensemble freigegeben.'
            : 'Freigabe beendet. Nur die Administration sieht das Album.',
      );
      await _load(refresh: true);
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<void> _pullToRefresh() async {
    try {
      await _load(refresh: true, reportError: true);
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  /// Takes over what the lightbox changed without reloading from page 0.
  /// Hidden images leave the grid unless hidden ones are shown.
  void _applyLightboxChanges() => setState(() {
    if (_hidden) return;
    final before = _assets.length;
    _assets.removeWhere((a) => a['hidden'] == true);
    final removed = before - _assets.length;
    _total = (_total - removed).clamp(0, _total);
    // The server no longer counts them, so later pages start earlier.
    if (_next != null) _next = (_next! - removed).clamp(0, _next!);
  });

  Future<void> _open(int index) async {
    final changed = await openPage<bool>(
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
    if (changed == true && mounted) _applyLightboxChanges();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(textValue(_gallery['title'])),
      actions: [
        if (_admin)
          PopupMenuButton<String>(
            tooltip: 'Album verwalten',
            onSelected: (value) async {
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
              if (value == 'publication') await _togglePublication();
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
    floatingActionButton: _admin
        ? FloatingActionButton.extended(
            onPressed: _uploading ? null : _upload,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
              _uploading
                  ? '$_uploadDone von $_uploadTotal …'
                  : 'Bilder hinzufügen',
            ),
          )
        : null,
    body: RefreshIndicator(
      onRefresh: _pullToRefresh,
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
                  if (_gallery['published'] == false)
                    _UnpublishedBanner(
                      onPublish: _admin ? _togglePublication : null,
                    ),
                  Text(
                    _total == 1 ? '1 Aufnahme' : '$_total Aufnahmen',
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
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        label:
                            '$_uploadDone von $_uploadTotal Bildern hochgeladen',
                        child: LinearProgressIndicator(
                          value: _uploadTotal == 0
                              ? null
                              : _uploadDone / _uploadTotal,
                        ),
                      ),
                    ),
                  if (_uploading && _uploadNote != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _uploadNote!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (!_uploading && _unsent.isNotEmpty && _admin)
                    _UnsentBanner(
                      count: _unsent.length,
                      onRetry: _uploadUnsent,
                      onDiscard: () => setState(_unsent.clear),
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
              padding: EdgeInsets.fromLTRB(24, 24, 24, _admin ? 96 : 24),
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
                        _assets.length == 1
                            ? '1 Aufnahme'
                            : '${_assets.length} Aufnahmen',
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

class _UnpublishedBanner extends StatelessWidget {
  const _UnpublishedBanner({this.onPublish});
  final VoidCallback? onPublish;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.visibility_off_outlined,
            size: 20,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Nur für Administration sichtbar',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onPublish != null)
            TextButton(onPressed: onPublish, child: const Text('Freigeben')),
        ],
      ),
    );
  }
}

class _UnsentBanner extends StatelessWidget {
  const _UnsentBanner({
    required this.count,
    required this.onRetry,
    required this.onDiscard,
  });
  final int count;
  final VoidCallback onRetry, onDiscard;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count == 1
                ? '1 Bild wurde nicht hochgeladen.'
                : '$count Bilder wurden nicht hochgeladen.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              TextButton(onPressed: onDiscard, child: const Text('Verwerfen')),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.upload),
                label: const Text('Rest erneut hochladen'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
