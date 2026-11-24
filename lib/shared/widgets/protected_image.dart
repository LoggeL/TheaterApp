import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../data/api_client.dart';

class ProtectedImage extends StatefulWidget {
  const ProtectedImage({
    super.key,
    required this.controller,
    required this.path,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.decodeWidth = 480,
    this.fallback,
  });
  final AppController controller;
  final String path;
  final BoxFit fit;

  /// Which part stays visible when [fit] crops, e.g. the face of a portrait.
  final Alignment alignment;
  final int decodeWidth;
  final Widget? fallback;
  @override
  State<ProtectedImage> createState() => _ProtectedImageState();
}

class _ProtectedImageState extends State<ProtectedImage> {
  Future<MediaData>? _image;
  MediaData? _cached;

  @override
  void initState() {
    super.initState();
    _syncOrLoad();
  }

  void _syncOrLoad() {
    final hit = widget.controller.cachedMedia(widget.path);
    _cached = hit;
    _image = hit == null ? widget.controller.mediaBytes(widget.path) : null;
  }

  void _reload() {
    _cached = null;
    _image = widget.controller.mediaBytes(widget.path);
  }

  @override
  void didUpdateWidget(ProtectedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.controller != widget.controller) {
      _syncOrLoad();
    }
  }

  Widget _placeholder(BuildContext context) =>
      widget.fallback ??
      ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.photo_outlined)),
      );

  Widget _buildImage(BuildContext context, MediaData data) => Image.memory(
    data.bytes,
    fit: widget.fit,
    alignment: widget.alignment,
    width: double.infinity,
    height: double.infinity,
    cacheWidth: widget.decodeWidth,
    filterQuality: FilterQuality.low,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => _placeholder(context),
  );

  @override
  Widget build(BuildContext context) {
    final cached = _cached ?? widget.controller.cachedMedia(widget.path);
    if (cached != null) {
      _cached = cached;
      return _buildImage(context, cached);
    }
    return FutureBuilder<MediaData>(
      future: _image,
      builder: (context, state) {
        if (state.hasError) {
          return widget.fallback ??
              InkWell(
                onTap: () => setState(_reload),
                child: const Center(
                  child: Tooltip(
                    message: 'Bild erneut laden',
                    child: Icon(Icons.refresh),
                  ),
                ),
              );
        }
        final data = state.data;
        if (data == null) return _placeholder(context);
        _cached = data;
        return _buildImage(context, data);
      },
    );
  }
}
