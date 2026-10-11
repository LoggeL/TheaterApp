import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/brand.dart';
import 'package:theater_app/app/deep_links.dart';
import 'package:theater_app/app/session_gate.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/app/shell/app_section.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/controller/pending_action.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/messages/messages.dart';
import 'package:theater_app/features/polls/polls.dart';
import 'package:theater_app/shared/feedback.dart';
import 'package:theater_app/shared/navigation.dart';

Future<AppController> demoController() async {
  final controller = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
  );
  await controller.init();
  await controller.startDemo();
  return controller;
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('deep links ignore unknown kinds and open one page at a time', (
    tester,
  ) async {
    final c = await demoController();
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

    router.handle(const AppTarget('unknown', 'x'));
    await tester.pumpAndSettle();
    expect(navigator.currentState!.canPop(), isFalse);
    expect(router.hasPending, isFalse);
    expect(selection.value, AppSection.today.index);

    router.handle(AppTarget('events', c.events.first.id));
    await tester.pumpAndSettle();
    router.handle(AppTarget('events', c.events.last.id));
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailScreen, skipOffstage: false), findsOneWidget);
    expect(
      tester.widget<EventDetailScreen>(find.byType(EventDetailScreen)).eventId,
      c.events.last.id,
    );
    expect(selection.value, AppSection.schedule.index);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a poll link selects Mitteilungen and opens the poll', (
    tester,
  ) async {
    final c = await demoController();
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
          home: const Scaffold(body: Text('Start')),
        ),
      ),
    );
    DeepLinkRouter(
      controller: c,
      navigator: navigator,
      messenger: messenger,
      isMounted: () => true,
    ).handle(AppTarget.fromData({'pollId': 'p1'})!);
    await tester.pumpAndSettle();
    expect(selection.value, AppSection.messages.index);
    expect(
      tester.widget<PollDetailScreen>(find.byType(PollDetailScreen)).pollId,
      'p1',
    );
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('deep links keep a page with unsaved input below the target', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = await demoController();
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
    openPage(navigator.currentContext!, MessageComposerScreen(controller: c));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Betreff'), 'Fest');
    await tester.pump();

    router.handle(AppTarget('events', c.events.first.id));
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailScreen), findsOneWidget);
    expect(
      find.byType(MessageComposerScreen, skipOffstage: false),
      findsOneWidget,
    );
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Fest'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('startup shows the brand and a readable error with details', (
    tester,
  ) async {
    final c = await demoController();
    final devices = DeviceServices(
      c,
      onTarget: (_) {},
      onForegroundMessage: (_) {},
    );
    var retries = 0;
    Widget gate({required bool starting, Object? error}) => MaterialApp(
      home: SessionGate(
        controller: c,
        devices: devices,
        starting: starting,
        startupError: error,
        onRetry: () => retries++,
        promptForPush: false,
      ),
    );

    await tester.pumpWidget(gate(starting: true));
    expect(find.text(Brand.name), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(
      gate(starting: false, error: StateError('database is locked')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Start gerade nicht möglich'), findsOneWidget);
    expect(find.textContaining('database is locked'), findsNothing);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('database is locked'), findsOneWidget);
    await tester.tap(find.text('Erneut versuchen'));
    expect(retries, 1);
    await tester.pumpWidget(const SizedBox());
    devices.dispose();
    c.dispose();
  });

  testWidgets('runAction shows German messages and the queued outcome', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await runAction(context, () async => throw StateError('kaputt'));
    await tester.pump();
    expect(
      find.text(
        'Der Vorgang konnte nicht abgeschlossen werden. Bitte erneut versuchen.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Bad state'), findsNothing);

    ScaffoldMessenger.of(context).clearSnackBars();
    await runAction(
      context,
      () => Future.value(ActionOutcome.queued),
      message: 'Gespeichert',
      queuedMessage: 'Vorgemerkt – wird bei Verbindung gesendet',
    );
    await tester.pump();
    expect(
      find.text('Vorgemerkt – wird bei Verbindung gesendet'),
      findsOneWidget,
    );

    ScaffoldMessenger.of(context).clearSnackBars();
    await runAction(
      context,
      () => Future.value(ActionOutcome.synced),
      message: 'Gespeichert',
      queuedMessage: 'Vorgemerkt – wird bei Verbindung gesendet',
    );
    await tester.pump();
    expect(find.text('Gespeichert'), findsOneWidget);
  });
}
