import 'dart:async';

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
/// the session's controller changes, but not while another page covers them.
/// Without [animate] the page appears at once (a link opened at app start);
/// going back still animates, and the iOS back swipe works as usual.
Future<T?> openPage<T>(
  BuildContext context,
  Widget screen, {
  bool fullscreen = false,
  bool animate = true,
}) {
  Widget builder(BuildContext _) =>
      _RoutePage(screen: screen, fullscreen: fullscreen);
  final route = animate
      ? MaterialPageRoute<T>(builder: builder)
      : _InstantPageRoute<T>(builder: builder);
  PerfTelemetry.nameRoute(route, screen);
  return Navigator.push<T>(context, route);
}

/// A page route without an entrance transition. The way back keeps the
/// theme's transition ([MaterialPageRoute.reverseTransitionDuration]).
class _InstantPageRoute<T> extends MaterialPageRoute<T> {
  _InstantPageRoute({required super.builder});

  @override
  Duration get transitionDuration => Duration.zero;
}

/// Completes once the route around [context] has finished its entrance
/// transition, right away when it has none (any more). Work that would
/// otherwise stutter the transition, such as a sync or a large rebuild,
/// waits for this.
Future<void> routeTransitionDone(BuildContext context) {
  final animation = ModalRoute.of(context)?.animation;
  if (animation == null || animation.status != AnimationStatus.forward) {
    return Future.value();
  }
  final done = Completer<void>();
  void settled(AnimationStatus status) {
    if (status == AnimationStatus.forward) return;
    animation.removeStatusListener(settled);
    done.complete();
  }

  animation.addStatusListener(settled);
  return done.future;
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

  /// False while another page covers this one (its [TickerMode] is off).
  bool _visible = true;

  /// The controller changed while the page was covered.
  bool _missed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppNavigationScope.controllerOf(context);
    if (controller != _controller) {
      _controller?.removeListener(_changed);
      _controller = controller?..addListener(_changed);
    }
    _visible = TickerMode.valuesOf(context).enabled;
    if (_visible && _missed) {
      // Uncovered: one rebuild catches up on everything missed meanwhile.
      _missed = false;
      _markScreen();
    }
  }

  /// The screen is the same widget instance: mark it for a rebuild.
  void _markScreen() =>
      _page.currentContext?.visitChildElements((e) => e.markNeedsBuild());

  void _changed() {
    if (!_visible) {
      _missed = true;
      return;
    }
    void apply() {
      if (!mounted) return;
      setState(() {});
      _markScreen();
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
