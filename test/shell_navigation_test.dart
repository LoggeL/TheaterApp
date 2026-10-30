import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/deep_links.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/app/shell/app_section.dart';
import 'package:theater_app/app/shell/status_banners.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/me/me.dart';
import 'package:theater_app/features/messages/messages.dart';
import 'package:theater_app/features/polls/polls.dart';
import 'package:theater_app/features/settings/settings.dart';
import 'package:theater_app/features/slots/slots.dart';
import 'package:theater_app/features/sync/sync.dart';
import 'package:theater_app/features/today/today.dart';
import 'package:theater_app/main.dart';
import 'package:theater_app/shared/navigation.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

void setWidth(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<AppController> pumpDemo(WidgetTester tester) async {
  final controller = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
  );
  await controller.init();
  await controller.startDemo();
  await tester.pumpWidget(
    TheaterApp(controller: controller, enableDeviceServices: false),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> finish(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
}

BuildContext shellContext(WidgetTester tester) =>
    tester.element(find.byType(AppShell, skipOffstage: false));

/// A server session as a regular member (person 1), so the unread rules for
/// admins do not apply.
TestServer memberServer() {
  final server = TestServer();
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (!path.endsWith('/snapshot') || server.offline) {
      return null;
    }
    return Future.value(
      jsonResponse({
        ...server.data,
        'user': {...server.user, 'role': 'member', 'personId': 1},
      }),
    );
  };
  return server;
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  for (final width in [1000.0, 1440.0]) {
    testWidgets('pages opened at ${width.toInt()}px keep exactly one rail', (
      tester,
    ) async {
      setWidth(tester, width);
      final c = await pumpDemo(tester);
      final devices = tester.widget<AppShell>(find.byType(AppShell)).devices;
      final pages = <Widget>[
        SettingsScreen(controller: c, devices: devices),
        PollsScreen(controller: c),
        EventsAdminScreen(controller: c),
        SlotPoolScreen(controller: c, poolId: 'demo-photos'),
        SyncScreen(controller: c),
        // Brings its own frame, which must not double the rail.
        EventDetailScreen(controller: c, eventId: c.events.first.id),
      ];
      for (final page in pages) {
        openPage(shellContext(tester), page);
        await tester.pumpAndSettle();
        expect(find.byType(AppNavigationRail), findsOneWidget);
        expect(
          find.byKey(const ValueKey('desktop-route-frame')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        Navigator.of(shellContext(tester)).pop();
        await tester.pumpAndSettle();
      }

      // A rail tap returns to the start and selects the section.
      openPage(shellContext(tester), SyncScreen(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AppNavigationRail),
          matching: find.text('Post'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SyncScreen), findsNothing);
      expect(find.text('Mitteilungen.'), findsOneWidget);
      await finish(tester, c);
    });
  }

  testWidgets('tapping the active section closes the opened pages', (
    tester,
  ) async {
    setWidth(tester, 1440);
    final c = await pumpDemo(tester);
    openPage(shellContext(tester), SyncScreen(controller: c));
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AppNavigationRail),
        matching: find.text('Heute'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsNothing);
    expect(find.byKey(const ValueKey('today-primary-column')), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('a nested frame without rail hides the outer rail', (
    tester,
  ) async {
    setWidth(tester, 1440);
    final c = await pumpDemo(tester);
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    openPage(
      shellContext(tester),
      ValueListenableBuilder<bool>(
        valueListenable: enabled,
        builder: (context, value, _) => DesktopRouteFrame(
          controller: c,
          selectedIndex: 2,
          enabled: value,
          child: const Scaffold(body: _Counter()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppNavigationRail), findsOneWidget);
    await tester.tap(find.text('0'));
    await tester.pump();
    enabled.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(AppNavigationRail), findsNothing);
    // The page keeps its state while the rail goes and comes back.
    expect(find.text('1'), findsOneWidget);
    enabled.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(AppNavigationRail), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await finish(tester, c);
  });

  for (final width in [320.0, 390.0, 600.0, 899.0]) {
    testWidgets('phones at ${width.toInt()}px show five labelled tabs', (
      tester,
    ) async {
      setWidth(tester, width);
      final c = await pumpDemo(tester);
      expect(c.user!.isAdmin, isTrue);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationDestination), findsNWidgets(5));
      for (final label in ['Heute', 'Termine', 'Skript', 'Post', 'Ich']) {
        expect(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          ),
          findsOneWidget,
        );
      }
      expect(find.byTooltip('Admin'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Admin'));
      await tester.pumpAndSettle();
      expect(find.text('Administration.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester, c);
    });
  }

  testWidgets('the sync icon appears only offline or with waiting changes', (
    tester,
  ) async {
    setWidth(tester, 390);
    final server = TestServer();
    final c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    expect(c.isOffline, isFalse);
    expect(c.pendingCount + c.failedCount, 0);
    expect(find.byType(SyncStatusButton), findsNothing);

    server.offline = true;
    await c.respond('demo-rehearsal', 'yes');
    await tester.pumpAndSettle();
    expect(c.isOffline, isTrue);
    expect(find.byType(SyncStatusButton), findsOneWidget);
    expect(find.byTooltip('Offline · 1 Änderung wartet'), findsOneWidget);
    expect(syncStatusLabel(c), 'Offline · 1 Änderung wartet');
    await finish(tester, c);
  });

  testWidgets('the Mitteilungen badge adds open polls to unread messages', (
    tester,
  ) async {
    setWidth(tester, 390);
    final server = memberServer();
    JsonMap message(String id, {bool read = false}) => {
      'id': id,
      'title': 'Mitteilung $id',
      'body': 'Text',
      'audience': 'all',
      'roleIds': <String>[],
      'productionIds': <String>[],
      'recipientIds': [1],
      'authorId': 4,
      'authorName': 'Kim Kulisse',
      'createdAt': '2026-09-12T08:00:00Z',
      'read': read,
    };
    server.data['messages'] = [
      message('m1'),
      message('m2'),
      message('m3', read: true),
    ];
    server.data['polls'] = [
      {
        'id': 'p1',
        'title': 'Essen',
        'options': [
          {'id': 'a', 'label': 'Pizza', 'votes': 0},
        ],
      },
    ];
    final c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('Mitteilungen · 2 ungelesen · 1 Abstimmung offen'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byWidgetPredicate(
          (w) => w is Badge && w.label is Text && (w.label as Text).data == '3',
        ),
      ),
      findsWidgets,
    );

    // The Termine badge also counts Terminfinder awaiting a choice.
    final events = unansweredSoon(c, c.now) + slotPoolsAwaitingChoice(c);
    expect(slotPoolsAwaitingChoice(c), greaterThan(0));
    expect(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Badge &&
              w.isLabelVisible &&
              w.label is Text &&
              (w.label as Text).data == '$events',
        ),
      ),
      findsWidgets,
    );
    await finish(tester, c);
  });

  testWidgets('rail jumps ask before discarding an unsaved editor', (
    tester,
  ) async {
    setWidth(tester, 1000);
    final c = await pumpDemo(tester);
    final navigation = AppNavigationScope.maybeOf(shellContext(tester))!;
    final before = navigation.value;
    openPage(shellContext(tester), MessageComposerScreen(controller: c));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Betreff'), 'Fest');
    await tester.pump();
    Finder rail(String label) => find.descendant(
      of: find.byType(AppNavigationRail),
      matching: find.text(label),
    );

    await tester.tap(rail('Termine'));
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Weiter bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.byType(MessageComposerScreen), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Fest'), findsOneWidget);
    expect(navigation.value, before);

    await tester.tap(rail('Termine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verwerfen'));
    await tester.pumpAndSettle();
    expect(find.byType(MessageComposerScreen), findsNothing);
    expect(navigation.value, AppSection.schedule.index);
    expect(find.text('Änderungen verwerfen?'), findsNothing);
    await finish(tester, c);
  });

  testWidgets('links from Heute open the matching Mitteilungen segment', (
    tester,
  ) async {
    setWidth(tester, 390);
    final c = await pumpDemo(tester);
    await tester.tap(find.text('Post').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<bool>),
        matching: find.textContaining('Abstimmungen'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PollsScreen), findsOneWidget);

    TodayScreen today() =>
        tester.widget(find.byType(TodayScreen, skipOffstage: false));
    today().onMessages!();
    await tester.pumpAndSettle();
    expect(find.byType(MessagesScreen), findsOneWidget);
    expect(find.byType(PollsScreen), findsNothing);

    today().onPolls!();
    await tester.pumpAndSettle();
    expect(find.byType(PollsScreen), findsOneWidget);
    // The tab's own list, not a separate page above Heute.
    expect(Navigator.of(shellContext(tester)).canPop(), isFalse);
    expect(
      AppNavigationScope.maybeOf(shellContext(tester))!.value,
      AppSection.messages.index,
    );
    await finish(tester, c);
  });

  testWidgets('the first frame builds only the start section', (tester) async {
    setWidth(tester, 390);
    final c = await pumpDemo(tester);
    expect(find.byType(TodayScreen), findsOneWidget);
    for (final type in [ScheduleScreen, CommunicationScreen, MyAreaScreen]) {
      expect(find.byType(type, skipOffstage: false), findsNothing);
    }
    Finder tab(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );

    await tester.tap(tab('Termine'));
    await tester.pumpAndSettle();
    expect(find.byType(ScheduleScreen), findsOneWidget);
    expect(find.byType(MyAreaScreen, skipOffstage: false), findsNothing);
    final schedule = tester.element(find.byType(ScheduleScreen));

    // Visited sections stay built, with their state, while hidden.
    await tester.tap(tab('Heute'));
    await tester.pumpAndSettle();
    expect(find.byType(ScheduleScreen), findsNothing);
    expect(
      tester.element(find.byType(ScheduleScreen, skipOffstage: false)),
      same(schedule),
    );
    await tester.tap(tab('Termine'));
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(ScheduleScreen)), same(schedule));
    expect(tester.takeException(), isNull);
    await finish(tester, c);
  });

  testWidgets('the link that starts the app opens its page at once', (
    tester,
  ) async {
    final c = await pumpDemo(tester);
    final navigator = GlobalKey<NavigatorState>();
    final messenger = GlobalKey<ScaffoldMessengerState>();
    final selection = ValueNotifier(AppSection.today.index);
    addTearDown(selection.dispose);
    await tester.pumpWidget(
      AppNavigationScope(
        selection: selection,
        controller: c,
        child: MaterialApp(
          navigatorKey: navigator,
          scaffoldMessengerKey: messenger,
          // iOS transitions, so the back swipe can be checked.
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: const Scaffold(body: Text('Start')),
        ),
      ),
    );
    final router = DeepLinkRouter(
      controller: c,
      navigator: navigator,
      messenger: messenger,
      isMounted: () => true,
    );

    router.handle(AppTarget('events', c.events.first.id));
    // First the section, a frame later the page.
    expect(selection.value, AppSection.schedule.index);
    expect(navigator.currentState!.canPop(), isFalse);
    await tester.pump();
    await tester.pump();
    final page = find.byType(EventDetailScreen);
    expect(page, findsOneWidget);
    final route = ModalRoute.of(tester.element(page))!;
    expect(route.transitionDuration, Duration.zero);
    expect(route.animation!.status, AnimationStatus.completed);
    expect(find.text('Start'), findsNothing);
    // Going back still animates, and the iOS back swipe works.
    expect(route.reverseTransitionDuration, greaterThan(Duration.zero));
    await tester.dragFrom(const Offset(5, 300), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailScreen), findsNothing);
    expect(find.text('Start'), findsOneWidget);

    // Later links open with the usual transition.
    router.handle(AppTarget('events', c.events.last.id));
    await tester.pump();
    // (Offstage for its first frame, while heroes are measured.)
    expect(
      ModalRoute.of(
        tester.element(find.byType(EventDetailScreen, skipOffstage: false)),
      )!.transitionDuration,
      greaterThan(Duration.zero),
    );
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsNothing);
    await finish(tester, c);
  });

  testWidgets('demo can be ended from the banner after confirming', (
    tester,
  ) async {
    setWidth(tester, 390);
    final c = await pumpDemo(tester);
    await tester.tap(find.text('Demo beenden'));
    await tester.pumpAndSettle();
    expect(find.text('Demo beenden?'), findsOneWidget);
    await tester.tap(find.text('Hierbleiben'));
    await tester.pumpAndSettle();
    expect(c.isDemo, isTrue);
    await tester.tap(find.text('Demo beenden'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo beenden').last);
    await tester.pumpAndSettle();
    expect(c.isDemo, isFalse);
    expect(c.user, isNull);
    await finish(tester, c);
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _taps = 0;
  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: () => setState(() => _taps++),
      child: Text('$_taps'),
    ),
  );
}
