import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/app_controller.dart';
import '../core/device_services.dart';
import '../core/telemetry/perf_telemetry.dart';
import 'background_sync.dart';
import 'brand.dart';
import 'deep_links.dart';
import 'platform/app_update.dart';
import 'session_gate.dart';
import 'shell/app_navigation.dart';
import 'shell/app_section.dart';
import 'theme/stage_theme.dart';

class TheaterApp extends StatefulWidget {
  const TheaterApp({
    super.key,
    required this.controller,
    this.enableDeviceServices = true,
  });
  final AppController controller;
  final bool enableDeviceServices;
  @override
  State<TheaterApp> createState() => _TheaterAppState();
}

class _TheaterAppState extends State<TheaterApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _navigationTab = ValueNotifier<int>(0);

  /// What the root depends on: session identity and theme. Everything else
  /// rebuilds below it (the session gate and pages opened with `openPage`).
  late final _rootState = ValueNotifier<Object?>(_rootKey);
  late final DeviceServices _devices;
  late final DeepLinkRouter _deepLinks;
  late final BackgroundSync _sync;
  final _updates = AppUpdateCheck();
  final _perf = PerfTelemetry.instance;

  /// Stable, so the navigator never re-attaches the telemetry's observer.
  late final _navigatorObservers = [
    if (_perf.available) _perf.navigatorObserver,
  ];
  String? _identity;
  bool _starting = true, _devicesStarted = false;
  Object? _startupError;

  /// Completes when the startup update check has finished or does not apply.
  Future<void> _updateCheck = Future.value();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deepLinks = DeepLinkRouter(
      controller: widget.controller,
      navigator: _navigator,
      messenger: _messenger,
      isMounted: () => mounted,
    );
    _sync = BackgroundSync(widget.controller, isStarting: () => _starting);
    _devices = DeviceServices(
      widget.controller,
      onTarget: _deepLinks.handle,
      onForegroundMessage: (message) {
        _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
        // A waiting account learns about its approval by push.
        if (widget.controller.hasAccess) {
          widget.controller.refresh(silent: true);
        } else {
          unawaited(_sync.refresh());
        }
      },
    );
    _identity = _sessionIdentity;
    widget.controller.addListener(_accountChanged);
    _navigationTab.addListener(_perfRoot);
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.controller.init();
      if (mounted) {
        setState(() {
          _starting = false;
          _startupError = null;
        });
        _perf.markReady();
        // Links, notifications and push follow the first shell frame; they
        // never hold back the start.
        if (widget.enableDeviceServices && !_devicesStarted) {
          _devicesStarted = true;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => unawaited(_startDevices()),
          );
        }
        _sync.start();
        _updateCheck = _checkForUpdate();
        final target = _deepLinks.takePending();
        if (target != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _deepLinks.handle(target);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _startupError = e;
        });
      }
    }
  }

  Future<void> _startDevices() async {
    if (!mounted) return;
    try {
      await _devices.start();
    } catch (_) {
      /* Links and notification taps are optional; the app stays usable. */
    }
    if (mounted) await _devices.restorePush();
  }

  String? get _sessionIdentity => widget.controller.user == null
      ? null
      : '${widget.controller.apiBaseUrl}:${widget.controller.user!.id}:${widget.controller.user!.status}:${widget.controller.user!.role}:${widget.controller.isDemo}:${widget.controller.sessionEpoch}';

  Object? get _rootKey {
    final c = widget.controller;
    return (
      c.user?.id,
      c.user?.status,
      c.user?.role,
      c.hasAccess,
      c.user?.mustChangePassword,
      c.isDemo,
      c.sessionEpoch,
      c.preferences['themeMode'],
    );
  }

  /// The screen the telemetry attributes frames to below opened pages.
  void _perfRoot() => _perf.setRoot(
    widget.controller.hasAccess
        ? AppSection.values[_navigationTab.value].name
        : 'gate',
  );

  void _accountChanged() {
    _rootState.value = _rootKey;
    _perfRoot();
    final current = _sessionIdentity;
    if (current != _identity) {
      _identity = current;
      // The start restores push itself, after its first frame.
      final restorePush =
          current != null && !_starting && widget.enableDeviceServices;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _navigationTab.value = AppSection.today.index;
        _navigator.currentState?.popUntil((route) => route.isFirst);
        if (restorePush) unawaited(_devices.restorePush());
      });
    }
    if (widget.controller.hasAccess &&
        !widget.controller.user!.mustChangePassword &&
        _deepLinks.hasPending) {
      final target = _deepLinks.takePending()!;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _deepLinks.handle(target),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sync.start();
      unawaited(_sync.refresh());
      _updateCheck = _checkForUpdate();
    } else {
      _sync.stop();
    }
  }

  Future<void> _checkForUpdate() {
    if (!widget.enableDeviceServices || !AppUpdateCheck.supported) {
      return Future.value();
    }
    final done = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (mounted && _navigator.currentContext != null) {
          await _updates.run(() => _navigator.currentContext!);
        }
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  @override
  void dispose() {
    _sync.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_accountChanged);
    _navigationTab.removeListener(_perfRoot);
    _devices.dispose();
    _navigationTab.dispose();
    _rootState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Object?>(
    valueListenable: _rootState,
    builder: (context, _, _) {
      final controller = widget.controller;
      return AppNavigationScope(
        selection: _navigationTab,
        controller: controller,
        child: MaterialApp(
          title: Brand.name,
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigator,
          navigatorObservers: _navigatorObservers,
          scaffoldMessengerKey: _messenger,
          locale: const Locale('de'),
          supportedLocales: const [Locale('de')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: StageTheme.build(Brightness.light),
          darkTheme: StageTheme.build(Brightness.dark),
          themeMode: switch (controller.preferences['themeMode']) {
            'dark' => ThemeMode.dark,
            'light' => ThemeMode.light,
            _ => ThemeMode.system,
          },
          home: SessionGate(
            controller: controller,
            devices: _devices,
            starting: _starting,
            startupError: _startupError,
            onRetry: _start,
            promptForPush: widget.enableDeviceServices,
            beforePushPrompt: () => _updateCheck,
          ),
        ),
      );
    },
  );
}
