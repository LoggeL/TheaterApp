import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';
import '../../../shared/widgets/protected_image.dart';

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
  String? _pageError;
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
                              : _index + 1 < widget.total && !_paging
                              ? () async {
                                  final requestedIndex = _index;
                                  await _more(retry: true);
                                  if (mounted &&
                                      _index == requestedIndex &&
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
