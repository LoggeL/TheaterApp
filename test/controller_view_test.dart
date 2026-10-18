import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/background_sync.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/main.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

void main() {
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
