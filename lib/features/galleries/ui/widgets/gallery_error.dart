import 'package:flutter/material.dart';

class GalleryError extends StatelessWidget {
  const GalleryError({super.key, required this.message, required this.retry});
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
