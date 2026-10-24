import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app/shell/app_navigation.dart';
import '../core/app_controller.dart';
import '../core/telemetry/perf_telemetry.dart';

/// Opens [screen] as a new page on top of the current route.
///
/// On wide screens the page keeps the section rail (a [DesktopRouteFrame]
/// highlighting the section the member came from). [fullscreen] pages such
/// as the image lightbox cover the whole window instead. Pages rebuild when
/// the session's controller changes.
Future<T?> openPage<T>(
  BuildContext context,
  Widget screen, {
  bool fullscreen = false,
}) {
  final route = MaterialPageRoute<T>(
    builder: (_) => _RoutePage(screen: screen, fullscreen: fullscreen),
  );
  PerfTelemetry.nameRoute(route, screen);
  return Navigator.push<T>(context, route);
}

class _RoutePage extends StatefulWidget {
  const _RoutePage({required this.screen, required this.fullscreen});
  final Widget screen;
  final bool fullscreen;

  @override
  State<_RoutePage> createState() => _RoutePageState();
}

class _RoutePageState extends State<_RoutePage> {
  AppController? _controller;
  final _page = GlobalKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppNavigationScope.controllerOf(context);
    if (controller != _controller) {
      _controller?.removeListener(_changed);
      _controller = controller?..addListener(_changed);
    }
  }

  void _changed() {
    void apply() {
      if (!mounted) return;
      setState(() {});
      // The screen is the same widget instance: mark it for a rebuild.
      _page.currentContext?.visitChildElements((e) => e.markNeedsBuild());
    }

    // A change announced while widgets build is applied after the frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = KeyedSubtree(key: _page, child: widget.screen);
    final controller = _controller;
    final selection = AppNavigationScope.maybeOf(context);
    if (widget.fullscreen || controller == null || selection == null) {
      return page;
    }
    return DesktopRouteFrame(
      controller: controller,
      selectedIndex: selection.value,
      child: page,
    );
  }
}
