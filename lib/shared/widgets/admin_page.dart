import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../core/app_controller.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({
    super.key,
    required this.controller,
    required this.title,
    required this.children,
    this.actions,
    this.scrollController,
    this.cacheExtent,
  });
  final AppController controller;
  final String title;
  final List<Widget> Function(BuildContext) children;
  final List<Widget>? actions;
  final ScrollController? scrollController;

  /// Builds children beyond the viewport, e.g. to scroll to one on open.
  final ScrollCacheExtent? cacheExtent;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: controller.user?.isAdmin != true
          ? const Center(child: Text('Admin-Zugang erforderlich.'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: RefreshIndicator(
                  onRefresh: controller.refresh,
                  child: ListView(
                    controller: scrollController,
                    scrollCacheExtent: cacheExtent,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(22, 14, 22, 32),
                    children: children(context),
                  ),
                ),
              ),
            ),
    ),
  );
}
