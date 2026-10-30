import 'package:flutter/material.dart';

import '../../core/app_controller.dart';

/// Stands in for [child], the note that something is unavailable, while the
/// first sync of a cache-first start runs: what the stored data lacks may
/// simply be new, as for a notification about it that started the app.
class FirstSyncPlaceholder extends StatelessWidget {
  const FirstSyncPlaceholder({
    super.key,
    required this.controller,
    required this.child,
  });
  final AppController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.firstSyncPending,
    child: child,
    builder: (context, pending, child) =>
        pending ? const Center(child: CircularProgressIndicator()) : child!,
  );
}
