import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../core/app_controller.dart';
import '../feedback.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({
    super.key,
    required this.controller,
    required this.title,
    required this.children,
    this.actions,
    this.scrollController,
    this.cacheExtent,
    this.floatingActionButton,
    this.onRefresh,
  });
  final AppController controller;
  final String title;
  final List<Widget> Function(BuildContext) children;
  final List<Widget>? actions;
  final ScrollController? scrollController;

  /// Builds children beyond the viewport, e.g. to scroll to one on open.
  final ScrollCacheExtent? cacheExtent;

  /// The page's create action, shown to admins only.
  final Widget? floatingActionButton;

  /// Pull to refresh; refreshes the snapshot when not set.
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      floatingActionButton: controller.user?.isAdmin == true
          ? floatingActionButton
          : null,
      body: controller.user?.isAdmin != true
          ? const Center(child: Text('Admin-Zugang erforderlich.'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: RefreshIndicator(
                  onRefresh:
                      onRefresh ??
                      () => refreshWithFeedback(context, controller),
                  child: ListView(
                    controller: scrollController,
                    scrollCacheExtent: cacheExtent,
                    physics: const AlwaysScrollableScrollPhysics(),
                    // Room below the last card for the create button.
                    padding: EdgeInsets.fromLTRB(
                      22,
                      14,
                      22,
                      floatingActionButton == null ? 32 : 96,
                    ),
                    children: children(context),
                  ),
                ),
              ),
            ),
    ),
  );
}
