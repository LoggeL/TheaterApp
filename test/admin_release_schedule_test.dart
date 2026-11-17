import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/core/telemetry/perf_stats.dart';
import 'package:theater_app/features/games/data/admin_releases_api.dart';
import 'package:theater_app/features/games/ui/admin_release_schedule.dart';
import 'package:theater_app/features/settings/settings.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// The admins' Release-Zeitplan (`runnerReleaseSchedule`): an entry in the
// settings only admins see, the drops in order with their state, and a new
// date for each, saved on the server.

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerRoleFigures',
  'runnerAdminCatalog',
  'runnerReleaseSchedule',
];

JsonMap _release(
  String id,
  String name,
  String startsAt, {
  String status = 'scheduled',
  String? planned,
  bool ready = true,
  int missing = 0,
  int items = 3,
  JsonMap push = const {'state': 'pending', 'at': null},
}) => {
  'id': id,
  'name': name,
  'startsAt': startsAt,
  'plannedStartsAt': planned ?? startsAt,
  'overridden': planned != null,
  'itemCount': items,
  'active': status != 'scheduled',
  'ready': ready,
  'status': status,
  'missing': missing,
  'push': push,
};

final _plan = <String, Object?>{
  'timeZone': 'Europe/Berlin',
  'defaultTime': '18:00',
  'serverTime': '2026-11-17T12:00:00.000Z',
  // Out of order on purpose: the screen shows them earliest first.
  'releases': [
    _release(
      'traum-2026',
      'Traum von Freiheit',
      '2026-11-22T17:00:00.000Z',
      ready: false,
      missing: 4,
      items: 27,
    ),
    _release(
      'hell-2026',
      'Eine höllische Herausforderung',
      '2026-11-08T17:00:00.000Z',
      status: 'live',
      items: 12,
      push: {'state': 'sent', 'at': '2026-11-08T17:00:10.000Z'},
    ),
    _release(
      'black-swan-2027',
      'Die Geschichte der Black Swan',
      '2027-04-04T16:00:00.000Z',
      planned: '2027-03-28T16:00:00.000Z',
      items: 2,
    ),
    _release(
      'spaet-2026',
      'Spätlese',
      '2026-11-16T17:00:00.000Z',
      status: 'blocked',
      ready: false,
      missing: 2,
      push: {'state': 'held', 'at': '2026-11-16T17:00:05.000Z'},
    ),
  ],
};

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

typedef _Put = ({String path, JsonMap body});

/// A signed-in controller; [role] `member` for anybody but an admin.
/// [answer] answers each PUT (by default with the release as saved).
Future<(AppController, List<String>, List<_Put>)> _signedIn({
  String role = 'admin',
  List<String> features = _features,
  http.Response Function(_Put put)? answer,
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  final gets = <String>[];
  final puts = <_Put>[];
  JsonMap user() => {...server.user, 'role': role};
  server.override = (request) {
    final path = _path(request);
    if (path.endsWith('/admin/runner/releases') && request.method == 'GET') {
      gets.add(path);
      return Future.value(jsonResponse(_plan));
    }
    if (path.contains('/admin/runner/releases/') && request.method == 'PUT') {
      final put = (path: path, body: jsonDecode(request.body) as JsonMap);
      puts.add(put);
      return Future.value(
        answer?.call(put) ??
            jsonResponse(
              _release(
                path.split('/').last,
                'Traum von Freiheit',
                '2026-11-25T17:00:00.000Z',
                planned: '2026-11-22T17:00:00.000Z',
              ),
            ),
      );
    }
    if (path.endsWith('/auth/login')) {
      return Future.value(
        jsonResponse({
          'token': server.token,
          'expiresAt': '2027-01-01T00:00:00Z',
          'user': user(),
        }),
      );
    }
    if (path.endsWith('/snapshot')) {
      return Future.value(jsonResponse({...server.data, 'user': user()}));
    }
    return null;
  };
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return (controller, gets, puts);
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens the release's sheet, picks the 25th of its month and keeps the time.
Future<void> _changeTo25th(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('release-$id')));
  await _settle(tester);
  await tester.tap(find.byKey(const ValueKey('release-change-date')));
  await _settle(tester);
  await tester.tap(find.text('25'));
  await tester.pump();
  await tester.tap(find.text('OK'));
  await _settle(tester);
  // The time picker starts at the release's time.
  await tester.tap(find.text('OK'));
  await _settle(tester);
}

void main() {
  test('the routes of the plan count as one each in the telemetry', () {
    expect(
      apiPathPattern('/admin/runner/releases/traum-2026'),
      '/admin/runner/releases/:id',
    );
    expect(apiPathPattern('/admin/runner/releases'), '/admin/runner/releases');
  });

  test('the plan reads every release and sorts it by date', () {
    final plan = AdminReleasePlan.fromJson(_plan);
    expect(plan.releases.map((r) => r.id), [
      'hell-2026',
      'spaet-2026',
      'traum-2026',
      'black-swan-2027',
    ]);
    final swan = plan.releases.last;
    expect(swan.overridden, isTrue);
    expect(swan.plannedStartsAt, DateTime.utc(2027, 3, 28, 16));
    expect(plan.releases.first.status, AdminReleaseStatus.live);
    expect(plan.releases[1].status, AdminReleaseStatus.blocked);
  });

  testWidgets('only admins of a server with the plan see the entry', (
    tester,
  ) async {
    for (final (role, features, shown) in [
      ('admin', _features, true),
      ('member', _features, false),
      // An older server without the plan: no entry, the viewer stays.
      ('admin', _features.sublist(0, 4), false),
    ]) {
      final (controller, _, _) = await _signedIn(
        role: role,
        features: features,
      );
      final devices = DeviceServices(
        controller,
        onTarget: (_) {},
        onForegroundMessage: (_) {},
      );
      await _pump(
        tester,
        SettingsScreen(controller: controller, devices: devices),
      );
      expect(
        find.byKey(const ValueKey('admin-release-schedule')),
        shown ? findsOneWidget : findsNothing,
        reason: '$role $features',
      );
      if (shown) expect(find.text('Release-Zeitplan'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('members get no plan and no request, even when opened', (
    tester,
  ) async {
    final (controller, gets, _) = await _signedIn(role: 'member');
    await _pump(tester, AdminReleaseScheduleScreen(controller: controller));
    expect(find.text('Nur für Admins.'), findsOneWidget);
    expect(gets, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('admins see the releases in order with date, status and items', (
    tester,
  ) async {
    final (controller, gets, _) = await _signedIn();
    await _pump(tester, AdminReleaseScheduleScreen(controller: controller));
    expect(gets, hasLength(1));
    final names = [
      'Eine höllische Herausforderung',
      'Spätlese',
      'Traum von Freiheit',
      'Die Geschichte der Black Swan',
    ];
    final tops = [
      for (final name in names) tester.getTopLeft(find.text(name)).dy,
    ];
    expect(tops, [...tops]..sort());
    // Berlin time, also in summer time.
    expect(
      find.text('So., 08.11.2026, 18:00 Uhr · 12 Inhalte'),
      findsOneWidget,
    );
    expect(
      find.text('So., 22.11.2026, 18:00 Uhr · 27 Inhalte'),
      findsOneWidget,
    );
    expect(find.text('So., 04.04.2027, 18:00 Uhr · 2 Inhalte'), findsOneWidget);
    expect(
      find.text('Geändert · laut releases.json So., 28.03.2027, 18:00 Uhr'),
      findsOneWidget,
    );
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Blockiert'), findsOneWidget);
    expect(find.text('Geplant'), findsNWidgets(2));
    expect(find.text('Blockiert wegen fehlender Bilder (2)'), findsOneWidget);
    expect(find.text('Geplant · Bilder fehlen noch (4)'), findsOneWidget);
    expect(
      find.text('Push gesendet am So., 08.11.2026, 18:00'),
      findsOneWidget,
    );
    expect(find.text('Push folgt, sobald alle Bilder da sind'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a new date is picked in Berlin time and saved on the server', (
    tester,
  ) async {
    final (controller, gets, puts) = await _signedIn();
    await _pump(tester, AdminReleaseScheduleScreen(controller: controller));
    await _changeTo25th(tester, 'traum-2026');
    expect(puts, hasLength(1));
    expect(puts.single.path, endsWith('/admin/runner/releases/traum-2026'));
    expect(puts.single.body, {'date': '2026-11-25', 'time': '18:00'});
    expect(
      find.text('Termin von „Traum von Freiheit“ gespeichert.'),
      findsOneWidget,
    );
    // The plan is read again after the change.
    expect(gets, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a live release moves later only after a confirmation', (
    tester,
  ) async {
    final (controller, _, puts) = await _signedIn(
      answer: (put) => put.body['confirm'] == true
          ? jsonResponse(
              _release(
                'hell-2026',
                'Eine höllische Herausforderung',
                '2026-11-25T17:00:00.000Z',
              ),
            )
          : jsonResponse({
              'error':
                  '„Eine höllische Herausforderung“ ist bereits '
                  'freigeschaltet.',
              'code': 'release_live',
            }, 409),
    );
    await _pump(tester, AdminReleaseScheduleScreen(controller: controller));
    await _changeTo25th(tester, 'hell-2026');
    expect(find.text('Bereits freigeschaltet'), findsOneWidget);
    expect(
      find.textContaining('Die Inhalte verschwinden für alle'),
      findsOneWidget,
    );
    // Cancelled: nothing more is sent.
    await tester.tap(find.text('Abbrechen'));
    await _settle(tester);
    expect(puts, hasLength(1));
    expect(puts.single.body.containsKey('confirm'), isFalse);

    await _changeTo25th(tester, 'hell-2026');
    await tester.tap(find.text('Trotzdem verschieben'));
    await _settle(tester);
    expect(puts, hasLength(3));
    expect(puts.last.body, {
      'date': '2026-11-25',
      'time': '18:00',
      'confirm': true,
    });
    expect(
      find.text('Termin von „Eine höllische Herausforderung“ gespeichert.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('errors of the server show, and a changed date can be reset', (
    tester,
  ) async {
    final (controller, _, puts) = await _signedIn(
      answer: (put) => put.body.containsKey('startsAt')
          ? jsonResponse(
              _release(
                'black-swan-2027',
                'Die Geschichte der Black Swan',
                '2027-03-28T16:00:00.000Z',
              ),
            )
          : jsonResponse({
              'error': 'Bitte ein gültiges Datum mit Uhrzeit wählen.',
              'code': 'invalid_date',
            }, 400),
    );
    await _pump(tester, AdminReleaseScheduleScreen(controller: controller));
    await _changeTo25th(tester, 'traum-2026');
    expect(
      find.text('Bitte ein gültiges Datum mit Uhrzeit wählen.'),
      findsOneWidget,
    );
    // Only a changed date offers the one of releases.json.
    await tester.tap(find.byKey(const ValueKey('release-traum-2026')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('release-reset-date')), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('release-black-swan-2027')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('release-reset-date')));
    await _settle(tester);
    expect(puts.last.path, endsWith('/admin/runner/releases/black-swan-2027'));
    expect(puts.last.body, {'startsAt': null});
    await tester.pumpWidget(const SizedBox());
  });
}
