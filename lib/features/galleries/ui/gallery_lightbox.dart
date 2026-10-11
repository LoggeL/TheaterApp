import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/protected_image.dart';

const _stageBlack = Color(0xFF101311);
const _pageTurn = Duration(milliseconds: 180);

/// Full-screen image viewer. Pops with `true` when it changed an asset in
/// [assets] (for example hid an image), so the grid can take that over.
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
  bool _saving = false, _paging = false, _changed = false;
  String? _pageError;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoBar;
  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _more();
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _more({bool retry = false}) async {
    if (_paging ||
        !mounted ||
        (_pageError != null && !retry) ||
        (!retry && _index < widget.assets.length - 8) ||
        widget.assets.length >= widget.total) {
      return;
    }
    setState(() {
      _paging = true;
      _pageError = null;
    });
    try {
      await widget.loadMore();
    } catch (e) {
      if (mounted) {
        setState(() {
          _pageError = e is ApiException
              ? e.message
              : 'Weitere Bilder konnten nicht geladen werden.';
        });
      }
    } finally {
      if (mounted) setState(() => _paging = false);
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
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Hides or shows one uploaded image in place; the lightbox stays open.
  Future<void> _setHidden(int index, bool hidden, {bool undo = true}) async {
    final asset = widget.assets[index];
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.remote(
        '/media/${textValue(asset['id']).substring(6)}/visibility',
        method: 'PUT',
        body: {'hidden': hidden},
      );
      if (!mounted) return;
      setState(() {
        widget.assets[index] = {...asset, 'hidden': hidden};
        _changed = true;
      });
      _undoBar?.close();
      _undoBar = messenger.showSnackBar(
        SnackBar(
          content: Text(hidden ? 'Bild ausgeblendet' : 'Bild eingeblendet'),
          action: undo
              ? SnackBarAction(
                  label: 'Rückgängig',
                  onPressed: () {
                    if (mounted) _setHidden(index, !hidden, undo: false);
                  },
                )
              : null,
        ),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  void _previous() {
    if (_index > 0) {
      _pages.previousPage(duration: _pageTurn, curve: Curves.easeOut);
    }
  }

  /// Turns the page, loading the next batch first at the end of the list.
  VoidCallback? get _nextAction {
    if (_index + 1 < widget.assets.length) {
      return () => _pages.nextPage(duration: _pageTurn, curve: Curves.easeOut);
    }
    if (_index + 1 >= widget.total || _paging) return null;
    return () async {
      final requestedIndex = _index;
      await _more(retry: true);
      if (mounted &&
          _index == requestedIndex &&
          _index + 1 < widget.assets.length) {
        _pages.nextPage(duration: _pageTurn, curve: Curves.easeOut);
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.assets[_index];
    final next = _nextAction;
    return PopScope<bool>(
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _undoBar?.close();
          return;
        }
        Navigator.pop(context, true);
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): _previous,
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              next?.call(),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(context),
        },
        child: Focus(autofocus: true, child: _viewer(context, asset, next)),
      ),
    );
  }

  Widget _viewer(BuildContext context, JsonMap asset, VoidCallback? next) {
    final date = dateValue(asset['date']);
    final video = asset['type'] == 'VIDEO';
    return Theme(
      data: StageTheme.build(Brightness.dark),
      child: Scaffold(
        backgroundColor: _stageBlack,
        appBar: AppBar(
          backgroundColor: _stageBlack,
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
                onPressed: () => _setHidden(_index, asset['hidden'] != true),
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
                    if (_paging)
                      Semantics(
                        liveRegion: true,
                        child: const Column(
                          children: [
                            LinearProgressIndicator(),
                            SizedBox(height: 8),
                            Text('Weitere Bilder werden geladen …'),
                          ],
                        ),
                      ),
                    if (_pageError != null)
                      Semantics(
                        liveRegion: true,
                        child: Column(
                          children: [
                            Text(_pageError!, textAlign: TextAlign.center),
                            TextButton.icon(
                              onPressed: () => _more(retry: true),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Erneut versuchen'),
                            ),
                          ],
                        ),
                      ),
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
                          onPressed: _index > 0 ? _previous : null,
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
                          onPressed: next,
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
