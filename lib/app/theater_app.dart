import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/app_controller.dart';
import '../core/device_services.dart';
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
  late final DeviceServices _devices;
  late final DeepLinkRouter _deepLinks;
  late final BackgroundSync _sync;
  final _updates = AppUpdateCheck();
  String? _identity;
  bool _starting = true;
  String? _startupError;
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
        widget.controller.refresh();
      },
    );
    _identity = _sessionIdentity;
    widget.controller.addListener(_accountChanged);
    _start();
  }

  Future<void> _start() async {
    try {
      await widget.controller.init();
      if (widget.enableDeviceServices) {
        await _devices.start();
        await _devices.restorePush();
      }
      if (mounted) {
        setState(() {
          _starting = false;
          _startupError = null;
        });
        _sync.start();
        _checkForUpdate();
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
          _startupError =
              'Die lokalen App-Daten konnten nicht geöffnet werden. $e';
        });
      }
    }
  }

  String? get _sessionIdentity => widget.controller.user == null
      ? null
      : '${widget.controller.apiBaseUrl}:${widget.controller.user!.id}:${widget.controller.user!.status}:${widget.controller.user!.role}:${widget.controller.isDemo}:${widget.controller.sessionEpoch}';

  void _accountChanged() {
    final current = _sessionIdentity;
    if (current != _identity) {
      _identity = current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _navigationTab.value = AppSection.today.index;
        _navigator.currentState?.popUntil((route) => route.isFirst);
        if (current != null) {
          if (widget.enableDeviceServices) _devices.restorePush();
        }
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
      _checkForUpdate();
    } else {
      _sync.stop();
    }
  }

  void _checkForUpdate() {
    if (!widget.enableDeviceServices || !AppUpdateCheck.supported) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _navigator.currentContext != null) {
        unawaited(_updates.run(() => _navigator.currentContext!));
      }
    });
  }

  @override
  void dispose() {
    _sync.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_accountChanged);
    _devices.dispose();
    _navigationTab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      return AppNavigationScope(
        selection: _navigationTab,
        child: MaterialApp(
          title: Brand.name,
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigator,
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
          ),
        ),
      );
    },
  );
}
