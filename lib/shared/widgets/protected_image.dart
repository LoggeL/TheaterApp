import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../data/api_client.dart';

class ProtectedImage extends StatefulWidget {
  const ProtectedImage({
    super.key,
    required this.controller,
    required this.path,
    this.fit = BoxFit.cover,
    this.decodeWidth = 480,
    this.fallback,
  });
  final AppController controller;
  final String path;
  final BoxFit fit;
  final int decodeWidth;
  final Widget? fallback;
  @override
  State<ProtectedImage> createState() => _ProtectedImageState();
}

class _ProtectedImageState extends State<ProtectedImage> {
  late Future<MediaData> _image;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _image = widget.controller.mediaBytes(widget.path);
  }

  @override
  void didUpdateWidget(ProtectedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.controller != widget.controller) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MediaData>(
    future: _image,
    builder: (context, state) {
      final placeholder =
          widget.fallback ??
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(child: Icon(Icons.photo_outlined)),
          );
      if (state.hasError) {
        return widget.fallback ??
            InkWell(
              onTap: () => setState(_load),
              child: const Center(
                child: Tooltip(
                  message: 'Bild erneut laden',
                  child: Icon(Icons.refresh),
                ),
              ),
            );
      }
      if (!state.hasData) return placeholder;
      return Image.memory(
        state.data!.bytes,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: widget.decodeWidth,
        gaplessPlayback: false,
        errorBuilder: (_, _, _) => placeholder,
      );
    },
  );
}
