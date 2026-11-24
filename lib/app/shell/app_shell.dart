import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/device_services.dart';
import '../../features/admin/ui/management_screen.dart';
import '../../features/events/ui/schedule_screen.dart';
import '../../features/games/games.dart';
import '../../features/games/ui/weekly_result_popup.dart';
import '../../features/me/ui/my_area_screen.dart';
import '../../features/messages/ui/communication_screen.dart';
import '../../features/scripts/ui/productions_screen.dart';
import '../../features/today/ui/today_screen.dart';
import '../../shared/layout/breakpoints.dart';
import '../../shared/layout/content_width.dart';
import '../../shared/navigation.dart';
import '../../shared/widgets/visible_listenable_builder.dart';
import '../brand.dart';
import '../platform/push_prompt.dart';
import 'app_navigation.dart';
import 'app_section.dart';
import 'status_banners.dart';

/// The Mitteilungen tab's selected segment (`true`: polls), shared per
/// controller between [AppShell] and [DeepLinkRouter].
final _pollsSegmentByController = Expando<ValueNotifier<bool>>(
  'communicationPollsSegment',
);

/// Returns the notifier controlling whether the Mitteilungen tab shows
/// polls (`true`) or messages (`false`) for [controller].
ValueNotifier<bool> communicationPollsSegment(AppController controller) =>
    _pollsSegmentByController[controller] ??= ValueNotifier<bool>(false);

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    required this.devices,
    this.promptForPush = true,
    this.beforePushPrompt,
  });
  final AppController controller;
  final DeviceServices devices;
  final bool promptForPush;

  /// The push prompt waits for this, so startup dialogs never stack.
  final Future<void> Function()? beforePushPrompt;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  final _startupDialogs = Completer<void>();

  /// Incremented on every [AppController] notification (without calling
  /// [setState] itself — [VisibleListenableBuilder] controls when the shell
  /// rebuilds). Lets [_TabSlot] skip rebuilding an already-mounted tab when
  /// switching back to it if controller state has not changed.
  int _controllerRevision = 0;

  /// The Mitteilungen tab's segment (true: polls), set by links from Heute
  /// or by deep links.
  ValueNotifier<bool> get _showPolls =>
      communicationPollsSegment(widget.controller);

  void _controllerChanged() => _controllerRevision++;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await widget.beforePushPrompt?.call();
        if (mounted && widget.promptForPush) {
          await requestPushOnOpen(context, widget.controller, widget.devices);
        }
      } finally {
        if (!_startupDialogs.isCompleted) _startupDialogs.complete();
      }
    });
  }

  @override
  void didUpdateWidget(AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _controllerRevision++;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  void _openAdmin() =>
      openPage(context, AdminSectionPage(controller: widget.controller));

  void _selectTab(int index) {
    final navigation = AppNavigationScope.maybeOf(context);
    final current = navigation?.value ?? _tab;
    if (index == current) {
      // The active section again: back to its start.
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    if (navigation != null) {
      navigation.value = index;
    } else {
      setState(() => _tab = index);
    }
  }

  void _openPlan() => _selectTab(AppSection.schedule.index);
  void _openScripts() => _selectTab(AppSection.scripts.index);
  void _openMessages() {
    _showPolls.value = false;
    _selectTab(AppSection.messages.index);
  }

  void _openPolls() {
    _showPolls.value = true;
    _selectTab(AppSection.messages.index);
  }

  // Covered by a page, the shell skips the controller's changes and catches
  // up with one rebuild when it is shown again.
  @override
  Widget build(BuildContext context) => WeeklyResultHost(
    controller: widget.controller,
    beforeCheck: () => _startupDialogs.future,
    child: VisibleListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => _build(context),
    ),
  );

  Widget _build(BuildContext context) {
    final c = widget.controller;
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.rail;
    final admin = c.user?.isAdmin == true;
    final destinations = appNavigationDestinations(c, includeAdmin: wide);
    final navigation = AppNavigationScope.maybeOf(context);
    var selectedTab = navigation?.value ?? _tab;
    // Phones have no Admin tab; Admin stays reachable from the app bar.
    if (selectedTab >= destinations.length) selectedTab = 0;

    final showSync = c.isOffline || c.pendingCount + c.failedCount > 0;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 56,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HeaderLogo(controller: c),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                Brand.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.5,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (showSync) SyncStatusButton(controller: c),
          if (admin && !wide)
            AdminShortcutButton(controller: c, onPressed: _openAdmin),
          const SizedBox(width: 10),
        ],
      ),
      body: Row(
        children: [
          if (wide) ...[
            AppNavigationRail(
              controller: c,
              selectedIndex: selectedTab,
              onSelected: _selectTab,
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: Column(
              children: [
                if (c.isDemo) DemoBanner(controller: c),
                if (!c.isDemo && (c.isOffline || c.failedCount > 0))
                  SyncBanner(controller: c),
                Expanded(
                  child: Stack(
                    children: [
                      IndexedStack(
                        index: selectedTab,
                        children: [
                          _TabSlot(
                            active: selectedTab == 0,
                            revision: _controllerRevision,
                            builder: (_) => ContentWidth(
                              maxWidth: 1360,
                              child: TodayScreen(
                                controller: c,
                                onPlan: _openPlan,
                                onScripts: _openScripts,
                                onMessages: _openMessages,
                                onPolls: _openPolls,
                              ),
                            ),
                          ),
                          _TabSlot(
                            active: selectedTab == 1,
                            revision: _controllerRevision,
                            builder: (_) => ContentWidth(
                              maxWidth: 1360,
                              child: ScheduleScreen(controller: c),
                            ),
                          ),
                          _TabSlot(
                            active: selectedTab == 2,
                            revision: _controllerRevision,
                            builder: (_) => ContentWidth(
                              maxWidth: 1050,
                              child: ProductionsScreen(controller: c),
                            ),
                          ),
                          _TabSlot(
                            active: selectedTab == 3,
                            revision: _controllerRevision,
                            builder: (_) => CommunicationScreen(
                              controller: c,
                              showPolls: _showPolls,
                            ),
                          ),
                          _TabSlot(
                            active: selectedTab == 4,
                            revision: _controllerRevision,
                            builder: (_) => ContentWidth(
                              maxWidth: 1100,
                              child: MyAreaScreen(
                                controller: c,
                                devices: widget.devices,
                              ),
                            ),
                          ),
                          if (admin && wide)
                            _TabSlot(
                              active: selectedTab == 5,
                              revision: _controllerRevision,
                              builder: (_) => ManagementScreen(
                                controller: c,
                                embedded: true,
                              ),
                            ),
                        ],
                      ),
                      // Overlay so toggling busy never shifts the IndexedStack
                      // height and forces all visited tabs to relayout.
                      if (c.busy && !c.isDemo)
                        const Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: RepaintBoundary(
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        ),
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
          : AppNavigationBar(
              selectedIndex: selectedTab,
              onDestinationSelected: _selectTab,
              destinations: destinations,
            ),
    );
  }
}

/// One section of the shell. A section is built the first time it is shown,
/// so the first frame builds only the start section. Hidden sections keep
/// their state but pause: their tickers stop, and the shell's rebuilds pass
/// them by until they are shown again. Revisiting a section without any
/// controller changes reuses the cached subtree without rebuilding it.
class _TabSlot extends StatefulWidget {
  const _TabSlot({
    required this.active,
    required this.revision,
    required this.builder,
  });
  final bool active;
  final int revision;
  final WidgetBuilder builder;
  @override
  State<_TabSlot> createState() => _TabSlotState();
}

class _TabSlotState extends State<_TabSlot> {
  Widget? _shown;
  int _builtRevision = -1;

  @override
  Widget build(BuildContext context) {
    // Inactive tabs do not even allocate their child widget tree; passing the
    // cached widget instance makes Flutter skip the hidden subtree, and
    // revisiting an unchanged tab skips rebuilding it completely.
    if (widget.active && (_shown == null || _builtRevision != widget.revision)) {
      _shown = widget.builder(context);
      _builtRevision = widget.revision;
    }
    final child = _shown;
    if (child == null) return const SizedBox.shrink();
    return TickerMode(
      enabled: widget.active,
      child: RepaintBoundary(child: child),
    );
  }
}

/// The admin hub as its own page, opened from the phone app bar.
class AdminSectionPage extends StatelessWidget {
  const AdminSectionPage({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Admin')),
    body: VisibleListenableBuilder(
      listenable: controller,
      builder: (context, _) =>
          ManagementScreen(controller: controller, embedded: true),
    ),
  );
}
