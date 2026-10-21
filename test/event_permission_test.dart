import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/platform/pwa_install.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/me/me.dart';
import 'package:theater_app/features/rehearsal/rehearsal.dart';
import 'package:theater_app/features/settings/settings.dart';
import 'package:theater_app/features/slots/slots.dart';
import 'package:theater_app/main.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;

/// A member with the right "Termine verwalten" (person 1).
class _HolderServer extends TestServer {
  List<String> permissions = ['events'];
  @override
  JsonMap get user => {
    ...super.user,
    'role': 'member',
    'personId': 1,
    'permissions': permissions,
  };
}

String _at(Duration offset) => fixedNow.add(offset).toUtc().toIso8601String();

JsonMap _event(String id, {JsonMap extra = const {}}) => {
  'id': id,
  'title': 'Probe $id',
  'startsAt': _at(const Duration(days: 3)),
  'endsAt': _at(const Duration(days: 3, hours: 2)),
  'place': 'Probensaal',
  ...extra,
};

_HolderServer _holder() {
  final server = _HolderServer();
  server.data['events'] = [
    _event('a', extra: {'createdBy': 1, 'updatedBy': 2}),
    // Addressed to others; holders see it like admins do.
    _event(
      'b',
      extra: {
        'personIds': [3],
        'addressedToMe': false,
      },
    ),
  ];
  server.data['capabilities'] = {
    'pushConfigured': true,
    'features': ['accountPermissions', 'lateDeclines', 'eventDetailsV2'],
  };
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Future<void> surface(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<AppController> pump(
    WidgetTester tester,
    TestServer server,
    Widget Function(AppController) page,
  ) async {
    await surface(tester, const Size(500, 1600));
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(body: page(controller)),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> finish(WidgetTester tester, AppController controller) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  test('the user carries its rights; admins hold all of them', () {
    final holder = AppUser.fromJson({
      'userId': 'u',
      'displayName': 'Leo',
      'role': 'member',
      'permissions': ['events'],
    });
    expect(holder.can('events'), isTrue);
    expect(holder.canManageEvents, isTrue);
    expect(holder.isAdmin, isFalse);
    // The cached user is restored offline with its rights.
    expect(AppUser.fromJson(holder.toJson()).permissions, ['events']);
    final member = AppUser.fromJson({'userId': 'm', 'role': 'member'});
    expect(member.permissions, isEmpty);
    expect(member.canManageEvents, isFalse);
    const admin = AppUser(id: 'a', name: 'A', email: '', role: 'admin');
    expect(admin.canManageEvents, isTrue);
  });

  test(
    'events keep their editors in the cache; queued rights are labelled',
    () {
      final event = TheaterEvent.fromJson(
        _event('a', extra: {'createdBy': 1, 'updatedBy': 2}),
      );
      expect(event.lastEditedBy, 2);
      final cached = TheaterEvent.fromJson(event.toJson());
      expect([cached.createdBy, cached.updatedBy], [1, 2]);
      expect(cached.copyWith(response: 'yes').updatedBy, 2);
      expect(TheaterEvent.fromJson(_event('b')).lastEditedBy, isNull);
      String label(String action) => PendingAction.fromJson({
        'id': action,
        'payload': {'action': action},
        'createdAt': '2026-09-12T10:00:00.000',
      }).label;
      expect(label('event.delete'), 'Termin');
      expect(label('slot.assign'), 'Terminfinder');
      expect(label('account.permissions'), 'Rechte');
      expect(label('account.role'), 'Admin-Rechte');
    },
  );

  testWidgets('holders create and manage events from the Termine tab', (
    tester,
  ) async {
    final controller = await pump(
      tester,
      _holder(),
      (c) => ScheduleScreen(controller: c),
    );
    expect(
      find.widgetWithText(FloatingActionButton, 'Termin anlegen'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Weitere Optionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Termine verwalten'));
    await tester.pumpAndSettle();
    expect(find.byType(EventsAdminScreen), findsOneWidget);
    expect(find.text('Admin-Zugang erforderlich.'), findsNothing);
    expect(
      find.widgetWithText(FloatingActionButton, 'Termin anlegen'),
      findsOneWidget,
    );
    await finish(tester, controller);
  });

  testWidgets('plain members get neither the menu item nor the button', (
    tester,
  ) async {
    final server = _holder()..permissions = [];
    final controller = await pump(
      tester,
      server,
      (c) => ScheduleScreen(controller: c),
    );
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(find.byTooltip('Weitere Optionen'));
    await tester.pumpAndSettle();
    expect(find.text('Termine verwalten'), findsNothing);
    expect(find.text('Terminfinder'), findsOneWidget);
    await finish(tester, controller);
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets('holders get no Admin area at ${width.toInt()}px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = _holder().controller();
      await signIn(controller);
      await tester.pumpWidget(
        TheaterApp(controller: controller, enableDeviceServices: false),
      );
      await tester.pumpAndSettle();
      expect(controller.user!.canManageEvents, isTrue);
      expect(find.byTooltip('Admin'), findsNothing);
      expect(find.text('Admin'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('the event page offers the Probenleitung with the last editor', (
    tester,
  ) async {
    final controller = await pump(
      tester,
      _holder(),
      (c) => EventDetailScreen(controller: c, eventId: 'a'),
    );
    expect(find.byTooltip('Termin bearbeiten'), findsOneWidget);
    expect(find.text('Probenleitung'), findsOneWidget);
    expect(find.text('Zuletzt geändert von Robin Spielmann'), findsOneWidget);
    for (final label in [
      'Rückmeldungen ansehen',
      'Anwesenheit erfassen',
      'Szenen planen',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await finish(tester, controller);
  });

  testWidgets('events for others say why the holder sees them', (tester) async {
    final controller = await pump(
      tester,
      _holder(),
      (c) => EventDetailScreen(controller: c, eventId: 'b'),
    );
    expect(find.text('Du bist nicht eingeladen'), findsOneWidget);
    expect(
      find.text(
        'Der Termin richtet sich an andere. Du siehst ihn, weil du Termine verwaltest.',
      ),
      findsOneWidget,
    );
    expect(find.text('Zuletzt geändert von Robin Spielmann'), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('Terminfinder for others say why the holder may assign', (
    tester,
  ) async {
    final server = _holder();
    server.data['slotPools'] = [
      {
        'id': 'pool-1',
        'title': 'Fototermin',
        'type': 'other',
        'roleIds': <String>[],
        'personIds': [3],
        'productionIds': <String>[],
        'addressedToMe': false,
        'closed': false,
        'version': 1,
        'slots': [
          {
            'id': 's1',
            'startsAt': _at(const Duration(days: 4)),
            'endsAt': _at(const Duration(days: 4, minutes: 15)),
            'capacity': 1,
            'booked': 0,
            'people': <JsonMap>[],
          },
        ],
      },
    ];
    final controller = await pump(
      tester,
      server,
      (c) => SlotPoolScreen(controller: c, poolId: 'pool-1'),
    );
    expect(find.text('Du bist nicht eingeladen'), findsOneWidget);
    expect(
      find.text(
        'Weil du Termine verwaltest, kannst du Personen über „Person zuweisen“ eintragen.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Als Admin'), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('holders open the editor and save', (tester) async {
    final server = _holder();
    final controller = await pump(
      tester,
      server,
      (c) => EventDetailScreen(controller: c, eventId: 'a'),
    );
    await tester.tap(find.byTooltip('Termin bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.byType(EventEditorScreen), findsOneWidget);
    expect(
      find.text('Dafür ist das Recht „Termine verwalten“ nötig.'),
      findsNothing,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Titel'),
      'Probe neu',
    );
    final save = find.text('Termin speichern');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'event.save');
    expect(server.actionBodies.last['title'], 'Probe neu');
    expect(find.text('Termin gespeichert'), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('the responses overview loads the event details', (tester) async {
    final server = _holder();
    final requested = <String>[];
    server.override = (request) {
      if (!request.url.path.contains('/admin/events/')) return null;
      requested.add(request.url.path);
      return Future.value(
        jsonResponse({
          'responses': [
            {'personId': 2, 'status': 'no', 'reason': 'Krank'},
          ],
          'checkins': [],
          'absences': [],
          'invitedIds': [1, 2],
          'openIds': [1],
          'absentIds': [],
        }),
      );
    };
    final controller = await pump(
      tester,
      server,
      (c) => ResponsesAdminScreen(controller: c, event: c.events.first),
    );
    expect(requested.single, contains('/admin/events/a'));
    expect(
      find.text('Dafür ist das Recht „Termine verwalten“ nötig.'),
      findsNothing,
    );
    expect(find.text('Rückmeldungen'), findsWidgets);
    await finish(tester, controller);
  });

  testWidgets('admin pages stay closed for holders', (tester) async {
    final controller = await pump(
      tester,
      _holder(),
      (c) => RolesAdminScreen(controller: c),
    );
    expect(find.text('Admin-Zugang erforderlich.'), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('Mein Bereich names the right; settings offer late declines', (
    tester,
  ) async {
    await surface(tester, const Size(600, 2400));
    final controller = _holder().controller();
    await signIn(controller);
    final devices = DeviceServices(
      controller,
      onTarget: (_) {},
      onForegroundMessage: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(
          body: MyAreaScreen(
            controller: controller,
            devices: devices,
            installation: PwaInstallation(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Termine verwalten'), findsOneWidget);
    expect(find.text('Administration'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: SettingsScreen(controller: controller, devices: devices),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Kurzfristige Absagen melden'), findsOneWidget);
    // Registrations and feedback stay with the admins.
    expect(find.text('Neue Registrierungen'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('an open editor shows the missing right after revocation', (
    tester,
  ) async {
    final server = _holder();
    final controller = await pump(
      tester,
      server,
      (c) => EventEditorScreen(controller: c, event: c.events.first),
    );
    expect(find.widgetWithText(TextField, 'Titel'), findsOneWidget);
    server.permissions = [];
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(
      find.text('Dafür ist das Recht „Termine verwalten“ nötig.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextField, 'Titel'), findsNothing);
    await finish(tester, controller);
  });

  test('changes queued before a revocation fail visibly', () async {
    final server = _holder();
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    server.offline = true;
    await controller.performAction({
      'action': 'event.save',
      'id': 'a',
      'version': 1,
      'title': 'Probe neu',
      'startsAt': _at(const Duration(days: 3)),
      'endsAt': _at(const Duration(days: 3, hours: 2)),
    });
    expect(controller.pendingCount, 1);
    expect(controller.outbox.single.label, 'Termin');
    server.offline = false;
    server.override = (request) => request.url.path.contains('/actions')
        ? Future.value(
            jsonResponse({
              'error': 'Hierfür fehlt das Recht „Termine verwalten“.',
              'code': 'forbidden',
            }, 403),
          )
        : null;
    await controller.refresh();
    final failed = controller.outbox.single;
    expect(failed.failed, isTrue);
    expect(failed.retryable, isFalse);
    expect(failed.lastError, 'Hierfür fehlt das Recht „Termine verwalten“.');
    expect(controller.failedCount, 1);
  });
}
