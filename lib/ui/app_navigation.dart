import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/brand.dart';
import 'brand_logo.dart';

/// Keeps section selection available to routes opened above the app shell.
class AppNavigationScope extends InheritedNotifier<ValueNotifier<int>> {
  const AppNavigationScope({
    super.key,
    required ValueNotifier<int> selection,
    required super.child,
  }) : super(notifier: selection);

  static ValueNotifier<int>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppNavigationScope>()
      ?.notifier;
}

List<NavigationDestination> appNavigationDestinations(
  AppController controller,
) {
  final now = DateTime.now();
  final unanswered = controller.events
      .where(
        (event) =>
            event.needsResponse &&
            (event.startsAt == null ||
                (event.endsAt ?? event.startsAt!).isAfter(now)),
      )
      .length;
  Widget eventIcon(IconData icon) => Tooltip(
    message: unanswered == 0
        ? 'Termine'
        : '$unanswered offene Rückmeldungen zu Terminen',
    child: Badge(
      isLabelVisible: unanswered > 0,
      label: Text('$unanswered'),
      child: Icon(icon),
    ),
  );
  final registrations = controller.openRegistrationCount;
  Widget adminIcon(IconData icon) => Tooltip(
    message: registrations == 0
        ? 'Admin'
        : registrations == 1
        ? '1 neue Registrierung wartet auf Zuordnung'
        : '$registrations neue Registrierungen warten auf Zuordnung',
    child: Badge(
      isLabelVisible: registrations > 0,
      label: Text('$registrations'),
      child: Icon(icon),
    ),
  );
  return [
    const NavigationDestination(
      icon: Icon(Icons.wb_sunny_outlined),
      selectedIcon: Icon(Icons.wb_sunny),
      label: 'Heute',
    ),
    NavigationDestination(
      icon: eventIcon(Icons.calendar_month_outlined),
      selectedIcon: eventIcon(Icons.calendar_month),
      label: 'Termine',
    ),
    const NavigationDestination(
      icon: Icon(Icons.auto_stories_outlined),
      selectedIcon: Icon(Icons.auto_stories),
      label: 'Drehbücher',
    ),
    const NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: 'Mein Bereich',
    ),
    if (controller.user?.isAdmin == true)
      NavigationDestination(
        icon: adminIcon(Icons.admin_panel_settings_outlined),
        selectedIcon: adminIcon(Icons.admin_panel_settings),
        label: 'Admin',
      ),
  ];
}

class AppNavigationRail extends StatelessWidget {
  const AppNavigationRail({
    super.key,
    required this.controller,
    required this.selectedIndex,
    required this.onSelected,
    this.showBrand = false,
  });
  final AppController controller;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool showBrand;

  @override
  Widget build(BuildContext context) {
    final extended = MediaQuery.sizeOf(context).width >= 1250;
    final destinations = appNavigationDestinations(controller);
    return NavigationRail(
      minExtendedWidth: 220,
      extended: extended,
      labelType: extended
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.all,
      selectedIndex: selectedIndex.clamp(0, destinations.length - 1),
      onDestinationSelected: onSelected,
      leading: showBrand
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const BrandLogo(size: 32),
                  const SizedBox(width: 10),
                  Text(
                    Brand.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            )
          : null,
      destinations: [
        for (final destination in destinations)
          NavigationRailDestination(
            icon: destination.icon,
            selectedIcon: destination.selectedIcon,
            label: Text(destination.label),
          ),
      ],
    );
  }
}

/// Preserves the app's section navigation while reading on a wide screen.
class DesktopRouteFrame extends StatelessWidget {
  const DesktopRouteFrame({
    super.key,
    required this.controller,
    required this.selectedIndex,
    required this.child,
    this.enabled = true,
  });
  final AppController controller;
  final int selectedIndex;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final selection = AppNavigationScope.maybeOf(context);
    if (!enabled ||
        selection == null ||
        !controller.hasAccess ||
        MediaQuery.sizeOf(context).width < 1250 ||
        MediaQuery.textScalerOf(context).scale(14) > 21) {
      return child;
    }
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        key: const ValueKey('desktop-route-frame'),
        children: [
          AppNavigationRail(
            controller: controller,
            selectedIndex: selectedIndex,
            showBrand: true,
            onSelected: (index) {
              selection.value = index;
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}
