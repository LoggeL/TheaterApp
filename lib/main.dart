import 'ui/app_navigation.dart';
import 'ui/admin.dart';
import 'ui/accounts_admin.dart';
import 'ui/responsive.dart';
import 'ui/push_prompt.dart';
import 'ui/brand_logo.dart';
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
import 'ui/app_update.dart';
import 'ui/events.dart';
import 'ui/more.dart';
import 'ui/reader.dart';
import 'ui/slots.dart';
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
  final _navigationTab = ValueNotifier<int>(0);
  late final DeviceServices _devices;
  final _updates = AppUpdateCheck();
  AppTarget? _pendingTarget;
  String? _identity;
  bool _starting = true;
  String? _startupError;
  Timer? _syncTimer;
  Future<void>? _automaticRefresh;
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
        _checkForUpdate();
        final target = _pendingTarget;
        if (target != null) {
          _pendingTarget = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _handleTarget(target);
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

  void _startTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(_refreshSession());
    });
  }

  Future<void> _refreshSession() async {
    final controller = widget.controller;
    if (_starting ||
        controller.user == null ||
        controller.isDemo ||
        controller.busy ||
        _automaticRefresh != null) {
      return;
    }
    final task = controller.usesFirebase && !controller.hasAccess
        ? controller.refreshIdentityAccess()
        : controller.refresh();
    _automaticRefresh = task;
    try {
      await task;
    } catch (_) {
      // Retain the current screen when an automatic status check is offline.
      // The next check or the manual refresh can retry it.
    } finally {
      if (identical(_automaticRefresh, task)) _automaticRefresh = null;
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
        _navigationTab.value = 0;
        _navigator.currentState?.popUntil((route) => route.isFirst);
        if (current != null) {
          if (widget.enableDeviceServices) _devices.restorePush();
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
    if (target.attendance != null && target.recipientUid != null) {
      unawaited(_respondToTarget(target));
    }
    if (target.kind == 'events') {
      _navigator.currentState!.push(
        MaterialPageRoute(
          builder: (_) => EventDetailScreen(
            controller: widget.controller,
            eventId: target.id,
          ),
        ),
      );
    } else if (target.kind == 'accounts') {
      // New registrations: only admins can act on them.
      if (widget.controller.user?.isAdmin != true) return;
      _navigator.currentState!.push(
        MaterialPageRoute(
          builder: (_) => AccountsAdminScreen(
            controller: widget.controller,
            initialView: 'accounts',
            initialFilter: 'pending',
          ),
        ),
      );
    } else if (target.kind == 'slots') {
      _navigator.currentState!.push(
        MaterialPageRoute(
          builder: (_) =>
              SlotPoolScreen(controller: widget.controller, poolId: target.id),
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

  Future<void> _respondToTarget(AppTarget target) async {
    String message;
    try {
      message = await widget.controller.respondFromNotification(
        target.id,
        target.attendance!,
        target.recipientUid!,
      );
    } catch (error) {
      message = error.toString();
    }
    if (mounted) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      unawaited(_refreshSession());
      _checkForUpdate();
    } else {
      _syncTimer?.cancel();
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
    _syncTimer?.cancel();
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
              : AppShell(
                  controller: controller,
                  devices: _devices,
                  promptForPush: widget.enableDeviceServices,
                ),
        ),
      );
    },
  );
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    required this.devices,
    this.promptForPush = true,
  });
  final AppController controller;
  final DeviceServices devices;
  final bool promptForPush;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.promptForPush) {
        requestPushOnOpen(context, widget.controller, widget.devices);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final admin = c.user?.isAdmin == true;
    final destinations = appNavigationDestinations(c);
    final unread = c.messages
        .where((message) => message['read'] != true)
        .length;
    final navigation = AppNavigationScope.maybeOf(context);
    final selectedTab = (navigation?.value ?? _tab).clamp(
      0,
      destinations.length - 1,
    );
    void selectTab(int index) {
      if (navigation != null) {
        navigation.value = index;
      } else {
        setState(() => _tab = index);
      }
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 65,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(size: 32),
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
            tooltip: unread == 0
                ? 'Mitteilungen'
                : '$unread ungelesene Mitteilungen',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => MessagesScreen(controller: c)),
            ),
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
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
      body: Row(
        children: [
          if (wide) ...[
            AppNavigationRail(
              controller: c,
              selectedIndex: selectedTab,
              onSelected: selectTab,
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: Column(
              children: [
                if (c.isDemo)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 7,
                    ),
                    color: Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: .12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.science_outlined,
                          size: 15,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        const SizedBox(width: 6),
                        const Flexible(
                          child: Text(
                            'DEMO · Beispieldaten, lokal auf deinem Gerät',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!c.isDemo && (c.isOffline || c.failedCount > 0))
                  Material(
                    // Offline is a normal state; only failed changes alarm.
                    color: c.failedCount > 0
                        ? Theme.of(context).colorScheme.errorContainer
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: InkWell(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SyncScreen(controller: c),
                        ),
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
                if (c.busy && !c.isDemo)
                  const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: IndexedStack(
                    index: selectedTab,
                    children: [
                      ContentWidth(
                        maxWidth: 1360,
                        child: TodayScreen(
                          controller: c,
                          onPlan: () => selectTab(1),
                          onScripts: () => selectTab(2),
                        ),
                      ),
                      ContentWidth(
                        maxWidth: 1360,
                        child: ScheduleScreen(controller: c),
                      ),
                      ContentWidth(
                        maxWidth: 1050,
                        child: ProductionsScreen(controller: c),
                      ),
                      ContentWidth(
                        maxWidth: 1100,
                        child: MoreScreen(
                          controller: c,
                          devices: widget.devices,
                        ),
                      ),
                      if (admin)
                        ManagementScreen(controller: c, embedded: true),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: selectedTab,
              onDestinationSelected: selectTab,
              destinations: destinations,
            ),
    );
  }
}
