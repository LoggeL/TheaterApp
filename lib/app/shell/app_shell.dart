import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/device_services.dart';
import '../../features/admin/ui/management_screen.dart';
import '../../features/events/ui/schedule_screen.dart';
import '../../features/games/games.dart';
import '../../features/me/ui/my_area_screen.dart';
import '../../features/messages/ui/communication_screen.dart';
import '../../features/scripts/ui/productions_screen.dart';
import '../../features/today/ui/today_screen.dart';
import '../../shared/layout/breakpoints.dart';
import '../../shared/layout/content_width.dart';
import '../../shared/navigation.dart';
import '../brand.dart';
import '../platform/push_prompt.dart';
import 'app_navigation.dart';
import 'app_section.dart';
import 'status_banners.dart';

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

  /// The Mitteilungen tab's segment (true: polls), set by links from Heute.
  final _showPolls = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _showPolls.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.promptForPush) return;
      await widget.beforePushPrompt?.call();
      if (mounted) {
        requestPushOnOpen(context, widget.controller, widget.devices);
      }
    });
  }

  void _openAdmin() =>
      openPage(context, AdminSectionPage(controller: widget.controller));

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => _build(context),
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
    void selectTab(int index) {
      if (index == selectedTab) {
        // The active section again: back to its start.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      if (navigation != null) {
        navigation.value = index;
      } else {
        setState(() => _tab = index);
      }
    }

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
              onSelected: selectTab,
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: Column(
              children: [
                if (c.isDemo) DemoBanner(controller: c),
                if (!c.isDemo && (c.isOffline || c.failedCount > 0))
                  SyncBanner(controller: c),
                if (c.busy && !c.isDemo)
                  const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: IndexedStack(
                    index: selectedTab,
                    children: [
                      for (final (index, tab) in <Widget>[
                        ContentWidth(
                          maxWidth: 1360,
                          child: TodayScreen(
                            controller: c,
                            onPlan: () => selectTab(AppSection.schedule.index),
                            onScripts: () =>
                                selectTab(AppSection.scripts.index),
                            onMessages: () {
                              _showPolls.value = false;
                              selectTab(AppSection.messages.index);
                            },
                            onPolls: () {
                              _showPolls.value = true;
                              selectTab(AppSection.messages.index);
                            },
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
                        CommunicationScreen(
                          controller: c,
                          showPolls: _showPolls,
                        ),
                        ContentWidth(
                          maxWidth: 1100,
                          child: MyAreaScreen(
                            controller: c,
                            devices: widget.devices,
                          ),
                        ),
                        if (admin && wide)
                          ManagementScreen(controller: c, embedded: true),
                      ].indexed)
                        _TabSlot(active: index == selectedTab, child: tab),
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
              onDestinationSelected: selectTab,
              destinations: destinations,
            ),
    );
  }
}

/// One section of the shell. Hidden sections keep their state but pause:
/// their tickers stop, and the shell's rebuilds pass them by until they are
/// shown again.
class _TabSlot extends StatefulWidget {
  const _TabSlot({required this.active, required this.child});
  final bool active;
  final Widget child;
  @override
  State<_TabSlot> createState() => _TabSlotState();
}

class _TabSlotState extends State<_TabSlot> {
  late Widget _shown = widget.child;

  @override
  Widget build(BuildContext context) {
    // The same widget instance again makes Flutter skip the whole subtree.
    if (widget.active) _shown = widget.child;
    return TickerMode(enabled: widget.active, child: _shown);
  }
}

/// The admin hub as its own page, opened from the phone app bar.
class AdminSectionPage extends StatelessWidget {
  const AdminSectionPage({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Admin')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) =>
          ManagementScreen(controller: controller, embedded: true),
    ),
  );
}
