import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../features/events/domain/event_selectors.dart';
import '../../features/messages/domain/message_selectors.dart';
import '../../features/polls/domain/poll_selectors.dart';
import '../../features/slots/domain/slot_pool.dart';
import '../../shared/feedback.dart';
import '../../shared/layout/breakpoints.dart';
import '../../shared/widgets/brand_logo.dart';
import '../brand.dart';

/// Keeps section selection available to routes opened above the app shell.
/// [controller] lets pages opened with `openPage` show the section rail.
class AppNavigationScope extends InheritedNotifier<ValueNotifier<int>> {
  const AppNavigationScope({
    super.key,
    required ValueNotifier<int> selection,
    this.controller,
    required super.child,
  }) : super(notifier: selection);
  final AppController? controller;

  static ValueNotifier<int>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppNavigationScope>()
      ?.notifier;

  /// The signed-in session's controller, without listening to it.
  static AppController? controllerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppNavigationScope>()?.controller;

  @override
  bool updateShouldNotify(AppNavigationScope oldWidget) =>
      super.updateShouldNotify(oldWidget) || oldWidget.controller != controller;
}

String _count(int n, String one, String many) => n == 1 ? one : '$n $many';

/// A badge whose count is read out as [semantics] instead of a bare number.
Widget _badged(IconData icon, int count, String semantics) => Semantics(
  label: count == 0 ? null : semantics,
  child: ExcludeSemantics(
    child: Badge(
      isLabelVisible: count > 0,
      label: Text('$count'),
      child: Icon(icon),
    ),
  ),
);

/// The shell sections in [AppSection] order. Admin is left out where
/// [includeAdmin] is false: phones reach it from the app bar instead.
List<NavigationDestination> appNavigationDestinations(
  AppController controller, {
  bool includeAdmin = true,
}) {
  final unanswered = unansweredSoon(controller, controller.now);
  final slots = slotPoolsAwaitingChoice(controller);
  final events = unanswered + slots;
  final eventText = [
    if (unanswered > 0)
      _count(
        unanswered,
        '1 offene Rückmeldung',
        'offene Rückmeldungen in den nächsten zwei Wochen',
      ),
    if (slots > 0)
      _count(slots, '1 Terminfinder wartet', 'Terminfinder warten'),
  ].join(' · ');
  Widget eventIcon(IconData icon) => _badged(icon, events, eventText);

  final unread = unreadMessageCount(controller);
  final polls = pollsToVote(controller).length;
  final messages = unread + polls;
  final messageText = [
    if (unread > 0) '$unread ungelesen',
    if (polls > 0) _count(polls, '1 Abstimmung offen', 'Abstimmungen offen'),
  ].join(' · ');
  Widget messageIcon(IconData icon) => _badged(icon, messages, messageText);

  final registrations = controller.openRegistrationCount;
  final adminText = _count(
    registrations,
    '1 neue Registrierung wartet auf Zuordnung',
    'neue Registrierungen warten auf Zuordnung',
  );
  Widget adminIcon(IconData icon) => _badged(icon, registrations, adminText);

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
      tooltip: events == 0 ? null : eventText,
    ),
    const NavigationDestination(
      icon: Icon(Icons.auto_stories_outlined),
      selectedIcon: Icon(Icons.auto_stories),
      label: 'Drehbücher',
    ),
    NavigationDestination(
      icon: messageIcon(Icons.chat_bubble_outline),
      selectedIcon: messageIcon(Icons.chat_bubble),
      label: 'Mitteilungen',
      tooltip: messages == 0 ? null : messageText,
    ),
    const NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: 'Mein Bereich',
    ),
    if (includeAdmin && controller.user?.isAdmin == true)
      NavigationDestination(
        icon: adminIcon(Icons.admin_panel_settings_outlined),
        selectedIcon: adminIcon(Icons.admin_panel_settings),
        label: 'Admin',
        tooltip: registrations == 0 ? null : adminText,
      ),
  ];
}

/// The admin entry in the phone app bar, with the registration badge.
class AdminShortcutButton extends StatelessWidget {
  const AdminShortcutButton({
    super.key,
    required this.controller,
    required this.onPressed,
  });
  final AppController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final registrations = controller.openRegistrationCount;
    return IconButton(
      tooltip: 'Admin',
      onPressed: onPressed,
      icon: _badged(
        Icons.admin_panel_settings_outlined,
        registrations,
        _count(registrations, '1 neue Registrierung', 'neue Registrierungen'),
      ),
    );
  }
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
    final extended =
        MediaQuery.sizeOf(context).width >= Breakpoints.extendedRail;
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

/// Marks the outermost [DesktopRouteFrame] of a route, so that frames nested
/// inside it (a page that brings its own frame and was opened with
/// `openPage`) render only their child.
class _RouteFrameScope extends InheritedWidget {
  const _RouteFrameScope({required this.frame, required super.child});
  final _DesktopRouteFrameState frame;

  @override
  bool updateShouldNotify(_RouteFrameScope oldWidget) => false;
}

/// Preserves the app's section navigation on a wide screen. Idempotent: only
/// the outermost frame of a route shows the rail. A nested frame with
/// [enabled] false (e.g. the reader's stage mode) hides it.
class DesktopRouteFrame extends StatefulWidget {
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
  State<DesktopRouteFrame> createState() => _DesktopRouteFrameState();
}

class _DesktopRouteFrameState extends State<DesktopRouteFrame> {
  /// Nested frames that currently ask to hide the rail.
  final _hiddenBy = <Object>{};
  _DesktopRouteFrameState? _outer;

  void _hide(Object frame, bool hide) {
    final changed = hide ? _hiddenBy.add(frame) : _hiddenBy.remove(frame);
    // Called while descendants build: apply on the next frame.
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _outer?._hide(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _outer = context.getInheritedWidgetOfExactType<_RouteFrameScope>()?.frame;
    if (_outer != null) {
      _outer!._hide(this, !widget.enabled);
      return widget.child;
    }
    final selection = AppNavigationScope.maybeOf(context);
    final rail =
        widget.enabled &&
        _hiddenBy.isEmpty &&
        selection != null &&
        widget.controller.hasAccess &&
        MediaQuery.sizeOf(context).width >= Breakpoints.rail &&
        MediaQuery.textScalerOf(context).scale(14) <= 21;
    // The page keeps its place in the tree when the rail comes or goes, so
    // its state survives resizing and the reader's stage mode.
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rail) ...[
            AppNavigationRail(
              key: const ValueKey('desktop-route-frame'),
              controller: widget.controller,
              selectedIndex: widget.selectedIndex,
              showBrand: true,
              onSelected: (index) async {
                // Unsaved input asks first; staying keeps the section.
                if (await popToFirst(context, Navigator.of(context))) {
                  selection.value = index;
                }
              },
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            key: const ValueKey('route-frame-page'),
            child: _RouteFrameScope(frame: this, child: widget.child),
          ),
        ],
      ),
    );
  }
}
