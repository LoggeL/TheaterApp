import 'package:flutter/material.dart';

import '../../domain/script_document.dart';

/// The heading that opens a scene in the reader list.
class SceneHeading extends StatelessWidget {
  const SceneHeading({super.key, required this.scene});
  final ScriptScene scene;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 28, 16, 28),
    child: Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SZENE ${scene.id}',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            scene.title,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    ),
  );
}
