import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../features/events/domain/event_selectors.dart';
import '../../features/games/games.dart';
import '../../features/messages/domain/message_selectors.dart';
import '../../features/polls/domain/poll_selectors.dart';
import '../../features/slots/domain/slot_pool.dart';
import '../../shared/feedback.dart';
import '../../shared/layout/breakpoints.dart';
import '../brand.dart';
import 'app_section.dart';

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
/// [tooltip] is announced by screen readers as the tooltip.
Widget _badged(IconData icon, int count, String semantics, {String? tooltip}) =>
    Semantics(
      label: count == 0 ? null : semantics,
      tooltip: tooltip,
      child: ExcludeSemantics(
        child: Badge(
          isLabelVisible: count > 0,
          label: Text('$count'),
          child: Icon(icon),
        ),
      ),
    );

/// One section of the navigation. The visible [label] is a single short word,
/// so it stays on one line at large text sizes too. [name] is the section's
/// full name where it differs from [label]: the long-press tooltip shows it,
/// and screen readers announce it as the tooltip after the visible label.
/// A [count] above zero shows a badge that is read out as [status].
NavigationDestination _destination(
  IconData icon,
  IconData selectedIcon, {
  required String label,
  String? name,
  int count = 0,
  String status = '',
}) {
  Widget badged(IconData data) => _badged(data, count, status, tooltip: name);
  final tooltip = [?name, if (count > 0) status].join(' · ');
  return NavigationDestination(
    icon: badged(icon),
    selectedIcon: badged(selectedIcon),
    label: label,
    tooltip: tooltip.isEmpty ? null : tooltip,
  );
}

/// The shell sections in [AppSection] order. Admin is left out where
/// [includeAdmin] is false: phones reach it from the app bar instead.
List<NavigationDestination> appNavigationDestinations(
  AppController controller, {
  bool includeAdmin = true,
}) {
  final unanswered = unansweredSoon(controller, controller.now);
  final slots = slotPoolsAwaitingChoice(controller);
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

  final unread = unreadMessageCount(controller);
  final polls = pollsToVote(controller).length;
  final messageText = [
    if (unread > 0) '$unread ungelesen',
    if (polls > 0) _count(polls, '1 Abstimmung offen', 'Abstimmungen offen'),
  ].join(' · ');

  final registrations = controller.openRegistrationCount;
  return [
    _destination(Icons.wb_sunny_outlined, Icons.wb_sunny, label: 'Heute'),
    _destination(
      Icons.calendar_month_outlined,
      Icons.calendar_month,
      label: 'Termine',
      count: unanswered + slots,
      status: eventText,
    ),
    _destination(
      Icons.auto_stories_outlined,
      Icons.auto_stories,
      label: 'Skript',
      name: 'Drehbücher',
    ),
    _destination(
      Icons.mail_outline,
      Icons.mail,
      label: 'Post',
      name: 'Mitteilungen',
      count: unread + polls,
      status: messageText,
    ),
    _destination(
      Icons.person_outline,
      Icons.person,
      label: 'Ich',
      name: 'Mein Bereich',
    ),
    if (includeAdmin && controller.user?.isAdmin == true)
      _destination(
        Icons.admin_panel_settings_outlined,
        Icons.admin_panel_settings,
        label: 'Admin',
        count: registrations,
        status: _count(
          registrations,
          '1 neue Registrierung wartet auf Zuordnung',
          'neue Registrierungen warten auf Zuordnung',
        ),
      ),
  ];
}

/// Keeps a navigation label on one line: a label too wide for its slot ends
/// with an ellipsis instead of breaking inside a word. The full name stays in
/// the tooltip and the semantics.
Widget _oneLine(Widget child) => DefaultTextStyle.merge(
  maxLines: 1,
  softWrap: false,
  overflow: TextOverflow.ellipsis,
  child: child,
);

/// The phone navigation bar. [NavigationBar] already caps the label text
/// scale at 1.3; on top of that every label keeps to one line.
class AppNavigationBar extends StatelessWidget {
  const AppNavigationBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });
  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) => NavigationBar(
    selectedIndex: selectedIndex,
    onDestinationSelected: onDestinationSelected,
    destinations: [
      for (final destination in destinations) _oneLine(destination),
    ],
  );
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

/// The rail has no tooltips of its own: show the destination's on hover.
/// Screen readers already get the full name from the icon's semantics.
Widget _railTooltip(NavigationDestination destination, Widget icon) =>
    destination.tooltip == null
    ? icon
    : Tooltip(
        message: destination.tooltip,
        excludeFromSemantics: true,
        child: icon,
      );

/// The rail's place of the game entry ([gameEntryShown]): after "Ich",
/// before "Admin". The sections keep their [AppSection] index; only the
/// rail counts the entry in between.
int get _gameSlot => AppSection.me.index + 1;

/// The section rail. With the game entry the rail has one destination more
/// than there are sections: [selectedIndex] and [onSelected] still speak of
/// sections, the entry itself opens the game ([onGame], by default
/// [openStageRunner]). [gameOpen] marks the entry while the game or a page
/// it opened is shown; without [onGame] a tap on it then does nothing.
class AppNavigationRail extends StatelessWidget {
  const AppNavigationRail({
    super.key,
    required this.controller,
    required this.selectedIndex,
    required this.onSelected,
    this.showBrand = false,
    this.onGame,
    this.gameOpen = false,
  });
  final AppController controller;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool showBrand;
  final VoidCallback? onGame;
  final bool gameOpen;

  @override
  Widget build(BuildContext context) {
    final extended =
        MediaQuery.sizeOf(context).width >= Breakpoints.extendedRail;
    final sections = appNavigationDestinations(controller);
    final game = gameEntryShown(controller);
    final slot = _gameSlot;
    final destinations = [
      ...sections.take(slot),
      if (game)
        _destination(
          gameEntryIcon,
          gameEntrySelectedIcon,
          label: gameEntryLabel,
        ),
      ...sections.skip(slot),
    ];
    final section = selectedIndex.clamp(0, sections.length - 1);
    return NavigationRail(
      minExtendedWidth: 220,
      extended: extended,
      labelType: extended
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.all,
      selectedIndex: game && gameOpen
          ? slot
          : game && section >= slot
          ? section + 1
          : section,
      onDestinationSelected: (index) {
        if (!game || index < slot) return onSelected(index);
        if (index > slot) return onSelected(index - 1);
        if (onGame != null) return onGame!();
        if (gameOpen) return;
        openStageRunner(context, controller);
      },
      leading: showBrand
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HeaderLogo(controller: controller),
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
            icon: _railTooltip(destination, destination.icon),
            selectedIcon: _railTooltip(
              destination,
              destination.selectedIcon ?? destination.icon,
            ),
            label: Text(
              destination.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
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
/// [enabled] false (e.g. the reader's stage mode) hides it. [pageType] is
/// the type of the route's screen: the game's page, and every page above it
/// (the Garderobe, the Wochenprobe, a figure), marks the rail's game entry
/// instead of the section it was opened from.
class DesktopRouteFrame extends StatefulWidget {
  const DesktopRouteFrame({
    super.key,
    required this.controller,
    required this.selectedIndex,
    required this.child,
    this.enabled = true,
    this.pageType,
  });
  final AppController controller;
  final int selectedIndex;
  final Widget child;
  final bool enabled;
  final Type? pageType;

  @override
  State<DesktopRouteFrame> createState() => _DesktopRouteFrameState();
}

class _DesktopRouteFrameState extends State<DesktopRouteFrame> {
  /// Nested frames that currently ask to hide the rail.
  final _hiddenBy = <Object>{};
  _DesktopRouteFrameState? _outer;

  /// The open routes of the game's page ([StageRunnerScreen]): a page above
  /// one of them belongs to the game, and the rail's game entry leads back
  /// to it there instead of starting the game anew.
  static final _gameRoutes = <Route<dynamic>>{};

  /// This frame's route while it is the game's page.
  Route<dynamic>? _gameRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _trackGame();
  }

  @override
  void didUpdateWidget(DesktopRouteFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _trackGame();
  }

  void _trackGame() {
    final route = widget.pageType == StageRunnerScreen
        ? ModalRoute.of(context)
        : null;
    if (identical(route, _gameRoute)) return;
    if (_gameRoute case final old?) _gameRoutes.remove(old);
    _gameRoute = route;
    if (route != null) _gameRoutes.add(route);
  }

  /// Whether this frame's route is the game's page or above one: frames
  /// rebuild when their route's place changes ([ModalRoute.of]), so one
  /// below the game shows no mark once it is the top again.
  bool _inGame(NavigatorState? navigator) =>
      _gameRoute != null ||
      _gameRoutes.any(
        (route) => route.navigator == navigator && route.isActive,
      );

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
    if (_gameRoute case final route?) _gameRoutes.remove(route);
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
    // Depends on the route, so a change of its place rebuilds the mark.
    ModalRoute.of(context);
    final navigator = Navigator.maybeOf(context);
    final inGame = rail && _inGame(navigator);
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
              gameOpen: inGame,
              onSelected: (index) async {
                // Unsaved input asks first; staying keeps the section.
                if (await popToFirst(context, Navigator.of(context))) {
                  selection.value = index;
                }
              },
              onGame: () async {
                // The game's own page stays as it is.
                if (_gameRoute != null) return;
                final navigator = Navigator.of(context);
                // A page the game opened: back to the game, its run kept.
                if (_inGame(navigator)) {
                  await popBackTo(context, navigator, _gameRoutes.contains);
                  return;
                }
                // Like a section: back to the start first, then the game.
                if (await popToFirst(context, navigator)) {
                  if (navigator.mounted) {
                    openStageRunner(navigator.context, widget.controller);
                  }
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
