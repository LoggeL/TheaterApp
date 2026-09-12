import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/app_controller.dart';
import 'core/brand.dart';
import 'core/device_services.dart';
import 'core/identity.dart';
import 'ui/firebase_auth.dart';
import 'ui/messages.dart';
import 'ui/auth.dart';
import 'ui/events.dart';
import 'ui/more.dart';
import 'ui/reader.dart';
import 'ui/theme.dart';

SemanticsHandle? _webSemantics;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) _webSemantics ??= SemanticsBinding.instance.ensureSemantics();
  await initializeDateFormatting('de');
  runApp(TheaterApp(controller: AppController(identity: FirebaseIdentity())));
}

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
  late final DeviceServices _devices;
  AppTarget? _pendingTarget;
  String? _identity;
  bool _starting = true;
  String? _startupError;
  Timer? _syncTimer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _devices = DeviceServices(
      widget.controller,
      onTarget: _handleTarget,
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
        _startTimer();
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

  void _startTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (widget.controller.user != null &&
          !widget.controller.isDemo &&
          !widget.controller.busy) {
        widget.controller.refresh();
      }
    });
  }

  String? get _sessionIdentity => widget.controller.user == null
      ? null
      : '${widget.controller.apiBaseUrl}:${widget.controller.user!.id}:${widget.controller.user!.status}:${widget.controller.user!.role}:${widget.controller.isDemo}:${widget.controller.sessionEpoch}';

  void _accountChanged() {
    final current = _sessionIdentity;
    if (current != _identity) {
      _identity = current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigator.currentState?.popUntil((route) => route.isFirst);
        if (current != null) {
          if (widget.enableDeviceServices) _devices.restorePush();
          final target = _pendingTarget;
          if (target != null) _handleTarget(target);
        }
      });
    }
    if (widget.controller.hasAccess &&
        !widget.controller.user!.mustChangePassword &&
        _pendingTarget != null) {
      final target = _pendingTarget!;
      _pendingTarget = null;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _handleTarget(target),
      );
    }
  }

  void _handleTarget(AppTarget target) {
    if (!widget.controller.hasAccess ||
        widget.controller.user!.mustChangePassword ||
        _navigator.currentState == null) {
      _pendingTarget = target;
      return;
    }
    _pendingTarget = null;
    if (target.kind == 'events') {
      _navigator.currentState!.push(
        MaterialPageRoute(
          builder: (_) => EventDetailScreen(
            controller: widget.controller,
            eventId: target.id,
          ),
        ),
      );
    } else if (target.kind == 'messages') {
      _navigator.currentState!.push(
        MaterialPageRoute(
          builder: (_) => MessageTargetScreen(
            controller: widget.controller,
            messageId: target.id,
          ),
        ),
      );
    } else {
      _navigator.currentState!.push(
        MaterialPageRoute(
          builder: (_) => ScriptReaderScreen(
            controller: widget.controller,
            productionId: target.id,
          ),
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      if (widget.controller.user != null) widget.controller.refresh();
    } else {
      _syncTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_accountChanged);
    _devices.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      return MaterialApp(
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
        home: _starting
            ? const Scaffold(
                body: Center(child: CircularProgressIndicator.adaptive()),
              )
            : _startupError != null
            ? Scaffold(
                body: SafeArea(
                  child: EmptyState(
                    icon: Icons.storage_outlined,
                    title: 'Start gerade nicht möglich',
                    message: _startupError!,
                    action: FilledButton(
                      onPressed: _start,
                      child: const Text('Erneut versuchen'),
                    ),
                  ),
                ),
              )
            : controller.user == null
            ? controller.usesFirebase
                  ? FirebaseWelcomeScreen(controller: controller)
                  : WelcomeScreen(controller: controller)
            : !controller.hasAccess
            ? ApprovalPendingScreen(controller: controller)
            : controller.user!.mustChangePassword
            ? PasswordScreen(controller: controller, requiredChange: true)
            : AppShell(controller: controller, devices: _devices),
      );
    },
  );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller, required this.devices});
  final AppController controller;
  final DeviceServices devices;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 65,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.theater_comedy_outlined,
              color: StageTheme.orange,
              size: 27,
            ),
            const SizedBox(width: 10),
            Text(
              Brand.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -.5,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Mitteilungen',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => MessagesScreen(controller: c)),
            ),
            icon: Badge(
              isLabelVisible: c.messages.any((m) => m['read'] != true),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          IconButton(
            tooltip: 'Synchronisierung',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SyncScreen(controller: c)),
            ),
            icon: Badge(
              isLabelVisible: c.pendingCount + c.failedCount > 0,
              label: Text('${c.pendingCount + c.failedCount}'),
              child: Icon(
                c.isOffline
                    ? Icons.cloud_off_outlined
                    : Icons.cloud_done_outlined,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Column(
        children: [
          if (c.isDemo)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
              color: const Color(0xFFEEE6DA),
              child: const Text(
                'DEMO · Beispieldaten, lokal auf deinem Gerät',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: StageTheme.ink,
                ),
              ),
            ),
          if (!c.isDemo && (c.isOffline || c.failedCount > 0))
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SyncScreen(controller: c)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        c.failedCount > 0
                            ? Icons.error_outline
                            : Icons.cloud_off,
                        size: 17,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          c.failedCount > 0
                              ? '${c.failedCount} Änderung(en) benötigen deine Prüfung'
                              : 'Offline · Du siehst zuletzt gespeicherte Inhalte',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 17),
                    ],
                  ),
                ),
              ),
            ),
          if (c.busy && !c.isDemo) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                TodayScreen(
                  controller: c,
                  onPlan: () => setState(() => _tab = 1),
                  onScripts: () => setState(() => _tab = 2),
                ),
                ScheduleScreen(controller: c),
                ProductionsScreen(controller: c),
                MoreScreen(controller: c, devices: widget.devices),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.wb_sunny_outlined),
            selectedIcon: Icon(Icons.wb_sunny),
            label: 'Heute',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Termine',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: 'Drehbücher',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Mein Bereich',
          ),
        ],
      ),
    );
  }
}
