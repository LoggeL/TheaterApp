import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/device_services.dart';
import '../../features/admin/ui/management_screen.dart';
import '../../features/events/ui/schedule_screen.dart';
import '../../features/me/ui/my_area_screen.dart';
import '../../features/messages/ui/communication_screen.dart';
import '../../features/scripts/ui/productions_screen.dart';
import '../../features/today/ui/today_screen.dart';
import '../../shared/layout/content_width.dart';
import '../../shared/widgets/brand_logo.dart';
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
          SyncStatusButton(controller: c),
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
                if (c.isDemo) const DemoBanner(),
                if (!c.isDemo && (c.isOffline || c.failedCount > 0))
                  SyncBanner(controller: c),
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
                          onPlan: () => selectTab(AppSection.schedule.index),
                          onScripts: () => selectTab(AppSection.scripts.index),
                          onMessages: () =>
                              selectTab(AppSection.messages.index),
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
                      CommunicationScreen(controller: c),
                      ContentWidth(
                        maxWidth: 1100,
                        child: MyAreaScreen(
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
          : NavigationBarTheme(
              // Six sections on a phone: smaller labels keep words whole.
              data: MediaQuery.sizeOf(context).width / destinations.length < 76
                  ? NavigationBarTheme.of(context).copyWith(
                      labelTextStyle: const WidgetStatePropertyAll(
                        TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.1,
                        ),
                      ),
                    )
                  : NavigationBarTheme.of(context),
              child: NavigationBar(
                // Below ~56 px per section even small labels break mid-word.
                labelBehavior:
                    MediaQuery.sizeOf(context).width / destinations.length < 56
                    ? NavigationDestinationLabelBehavior.alwaysHide
                    : null,
                selectedIndex: selectedTab,
                onDestinationSelected: selectTab,
                destinations: destinations,
              ),
            ),
    );
  }
}
