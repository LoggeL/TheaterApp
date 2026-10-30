import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/background_sync.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/messages/messages.dart';
import 'package:theater_app/features/today/today.dart';
import 'package:theater_app/main.dart';
import 'package:theater_app/shared/navigation.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

/// Counts the builds per widget type while the test runs.
Map<Type, int> countBuilds() {
  final builds = <Type, int>{};
  debugOnRebuildDirtyWidget = (element, _) => builds.update(
    element.widget.runtimeType,
    (n) => n + 1,
    ifAbsent: () => 1,
  );
  return builds;
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('a covered shell waits with its rebuild until it shows again', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await c.init();
    await c.startDemo();
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    final shell = tester.element(find.byType(AppShell));
    openPage(
      shell,
      EventDetailScreen(controller: c, eventId: c.events.first.id),
    );
    await tester.pumpAndSettle();

    final builds = countBuilds();
    await c.setPreference('test.change', 1);
    await tester.pumpAndSettle();
    await c.setPreference('test.change', 2);
    await tester.pumpAndSettle();
    // The page shows the change; the shell below and Heute do not build.
    expect(builds[EventDetailScreen], greaterThan(0));
    expect(builds[AppNavigationBar], isNull);
    expect(builds[TodayScreen], isNull);

    builds.clear();
    Navigator.of(shell).pop();
    await tester.pumpAndSettle();
    // Uncovered: one rebuild catches up on both changes.
    expect(builds[AppNavigationBar], 1);
    expect(builds[TodayScreen], 1);
    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a change rebuilds the shell, not the session gate', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await c.init();
    await c.startDemo();
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    final builds = countBuilds();
    await c.setPreference('test.change', 1);
    await tester.pumpAndSettle();
    // The shell's own listener rebuilds it once, the gate does not.
    expect(builds[AppShell], isNull);
    expect(builds[AppNavigationBar], 1);
    expect(builds[TodayScreen], 1);
    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a message counts as read once its page is in place', (
    tester,
  ) async {
    final server = TestServer();
    server.data['messages'] = [
      {
        'id': 'm1',
        'title': 'Probe fällt aus',
        'body': 'Heute keine Probe.',
        'createdAt': '2026-09-12T08:00:00Z',
        'read': false,
      },
    ];
    final c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    openPage(
      tester.element(find.byType(AppShell)),
      MessageDetailScreen(controller: c, message: c.messages.single),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-transition: nothing sent yet.
    expect(server.actionBodies, isEmpty);
    await tester.pumpAndSettle();
    expect(server.actionBodies.single['action'], 'message.read');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  test('queued message reads show in the projected messages', () async {
    final server = TestServer();
    server.data['messages'] = [
      {'id': 'm1', 'title': 'Probe fällt aus', 'read': false},
      {'id': 'm2', 'title': 'Kostüme', 'read': false},
    ];
    final c = server.controller();
    addTearDown(c.dispose);
    await signIn(c);
    server.offline = true;
    await c.performAction({'action': 'message.read', 'id': 'm1'});
    expect(c.pendingCount, 1);
    expect(
      {for (final m in c.messages) m['id']: m['read']},
      {'m1': true, 'm2': false},
    );
  });

  test('queued casting shows in the production records', () async {
    final server = TestServer();
    final c = server.controller();
    addTearDown(c.dispose);
    await signIn(c);
    server.offline = true;
    await c.performAction({
      'action': 'production.cast',
      'id': DemoData.mainProductionId,
      'changes': [
        {'kind': 'director', 'personId': 5},
      ],
    });
    expect(c.pendingCount, 1);
    final record = c.productionRecords.firstWhere(
      (p) => p['id'] == DemoData.mainProductionId,
    );
    expect(record['directorMemberIds'], contains(5));
  });

  test('the background refresh never reports busy', () async {
    final server = TestServer();
    final c = server.controller();
    addTearDown(c.dispose);
    await signIn(c);
    final busy = <bool>[];
    c.addListener(() => busy.add(c.busy));
    final sync = BackgroundSync(c, isStarting: () => false);
    addTearDown(sync.dispose);
    // New data, so the refresh has something to show.
    server.data['messages'] = [
      {'id': 'm-new', 'title': 'Neue Probenzeit', 'read': false},
    ];
    await sync.refresh();
    expect(busy, isNotEmpty);
    expect(busy, everyElement(isFalse));
    expect(c.isRefreshing, isFalse);

    // Someone waiting for the running background refresh sees progress.
    busy.clear();
    final background = c.refresh(silent: true);
    final manual = c.refresh();
    expect(c.busy, isTrue);
    await Future.wait([background, manual]);
    expect(c.busy, isFalse);
    expect(busy, contains(true));
  });

  test(
    'a background refresh without new data leaves the screen alone',
    () async {
      final server = TestServer();
      final c = server.controller();
      addTearDown(c.dispose);
      await signIn(c);
      var notifications = 0;
      c.addListener(() => notifications++);
      server.data['serverTime'] = '2030-01-01T00:00:00Z';
      await c.refresh(silent: true);
      expect(notifications, 0);
      expect(c.isRefreshing, isFalse);
      // A manual refresh still reports back, and changed data is shown.
      await c.refresh();
      expect(notifications, greaterThan(0));
      notifications = 0;
      server.data['events'] = const [];
      await c.refresh(silent: true);
      expect(notifications, greaterThan(0));
      expect(c.events, isEmpty);
    },
  );

  testWidgets('the automatic refresh shows no progress bar', (tester) async {
    final server = TestServer();
    final c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    // Hold the snapshot request so the refresh stays in flight.
    final gate = Completer<void>();
    server.override = (request) => request.url.path.contains('/snapshot')
        ? gate.future.then((_) => jsonResponse(server.data))
        : null;
    final refresh = c.refresh(silent: true);
    await tester.pump();
    expect(c.isRefreshing, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    gate.complete();
    await refresh;
    await tester.pumpAndSettle();
    expect(c.isRefreshing, isFalse);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  test('an expired session on any request signs out', () async {
    final server = TestServer();
    server.override = (request) => request.url.path.contains('/galleries')
        ? Future.value(jsonResponse({'error': 'Sitzung abgelaufen'}, 401))
        : null;
    final c = server.controller();
    addTearDown(c.dispose);
    await signIn(c);
    expect(c.user, isNotNull);
    await expectLater(
      c.remote('/galleries'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
    );
    expect(c.user, isNull);
    expect(
      c.error,
      'Deine Anmeldung ist abgelaufen. Bitte melde dich erneut an.',
    );
  });
}
