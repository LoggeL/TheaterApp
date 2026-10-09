import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/events.dart';
import 'package:theater_app/ui/slots.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn;

/// Local wall-clock time of a UTC instant, so expectations hold in any time
/// zone (CI runs in UTC, the theatre in Europe/Berlin).
String hm(String utc) =>
    DateFormat('HH:mm').format(DateTime.parse(utc).toLocal());
final firstSlot =
    'Sa 19.9., ${hm('2026-09-19T08:00:00Z')}–${hm('2026-09-19T08:15:00Z')}';

/// Signed in as member 1 (Alex), optionally with admin rights.
class SlotServer extends TestServer {
  SlotServer({this.role = 'member'});
  final String role;
  @override
  JsonMap get user => {...super.user, 'role': role, 'personId': 1};
}

JsonMap slot(
  String id,
  String start,
  String end, {
  int capacity = 2,
  List<(int, String)> people = const [],
}) => {
  'id': id,
  'startsAt': start,
  'endsAt': end,
  'capacity': capacity,
  'booked': people.length,
  'people': [
    for (final (id, name) in people) {'personId': id, 'name': name},
  ],
};

JsonMap pool({
  String? myBooking,
  bool closed = false,
  List<int> personIds = const [],
  bool alexInFirst = false,
}) => {
  'id': 'pool-1',
  'title': 'Fototermin',
  'description': 'Porträts fürs Programmheft.',
  'place': 'Kolpingheim',
  'type': 'other',
  'roleIds': <String>[],
  'personIds': personIds,
  'closed': closed,
  'createdAt': '2026-09-01T10:00:00Z',
  'version': 3,
  'myBooking': myBooking,
  'slots': [
    slot(
      's1',
      '2026-09-19T08:00:00Z',
      '2026-09-19T08:15:00Z',
      people: [
        (3, 'Toni Lichtblick'),
        if (alexInFirst) (1, 'Alex Bühnenfreund'),
      ],
    ),
    slot(
      's2',
      '2026-09-19T08:15:00Z',
      '2026-09-19T08:30:00Z',
      capacity: 1,
      people: [(5, 'Sam Vorhang')],
    ),
    slot('s3', '2026-09-19T08:30:00Z', '2026-09-19T08:45:00Z'),
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Future<void> surface(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget screen(Widget child, {double textScale = 1}) => MaterialApp(
    theme: StageTheme.build(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: child,
  );

  Future<AppController> start(TestServer server) async {
    final controller = server.controller();
    await signIn(controller);
    return controller;
  }

  Future<void> finish(WidgetTester tester, AppController controller) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  testWidgets('an invited member books a free slot; full slots offer none', (
    tester,
  ) async {
    await surface(tester, const Size(360, 1600));
    final server = SlotServer()..data['slotPools'] = [pool()];
    final controller = await start(server);
    await tester.pumpWidget(
      screen(SlotPoolScreen(controller: controller, poolId: 'pool-1')),
    );
    expect(find.text('Noch kein Slot gewählt'), findsOneWidget);
    expect(find.text('Eingeladen: Alle'), findsOneWidget);
    expect(find.text('Samstag, 19. September'), findsOneWidget);
    expect(find.text('●○'), findsOneWidget);
    expect(find.text('1 frei'), findsOneWidget);
    expect(find.text('voll'), findsOneWidget);
    // s1 and s3 are bookable, the full s2 is not.
    expect(find.widgetWithText(FilledButton, 'Buchen'), findsNWidgets(2));
    final full = find.ancestor(
      of: find.text('voll'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: full, matching: find.text('Buchen')),
      findsNothing,
    );
    expect(find.text('Person zuweisen'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Buchen').first);
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'slot.book',
      'poolId': 'pool-1',
      'slotId': 's1',
    });
    expect(tester.takeException(), isNull);
    await finish(tester, controller);
  });

  testWidgets('the own slot is highlighted and can be released', (
    tester,
  ) async {
    await surface(tester, const Size(360, 1600));
    final server = SlotServer()
      ..data['slotPools'] = [pool(myBooking: 's1', alexInFirst: true)];
    final controller = await start(server);
    await tester.pumpWidget(
      screen(SlotPoolScreen(controller: controller, poolId: 'pool-1')),
    );
    expect(find.text('Dein Slot'), findsOneWidget);
    expect(find.textContaining('Dein Slot: $firstSlot'), findsOne);
    expect(find.text('Freigeben'), findsOneWidget);
    expect(find.text('Buchen'), findsNothing);
    // Only s3 still has room; s2 is full.
    expect(find.text('Hierhin umbuchen'), findsOneWidget);
    await tester.tap(find.text('Freigeben'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Freigeben'),
      ),
    );
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'slot.cancel',
      'poolId': 'pool-1',
    });
    await finish(tester, controller);
  });

  testWidgets('closed pools and uninvited admins offer no booking', (
    tester,
  ) async {
    await surface(tester, const Size(360, 1800));
    final server = SlotServer(role: 'admin')
      ..data['slotPools'] = [
        pool(personIds: [4]),
      ];
    final controller = await start(server);
    await tester.pumpWidget(
      screen(SlotPoolScreen(controller: controller, poolId: 'pool-1')),
    );
    expect(find.text('Du bist nicht eingeladen'), findsOneWidget);
    expect(find.text('Buchen'), findsNothing);
    expect(find.text('Hierhin umbuchen'), findsNothing);
    // Admins assign people to slots with room and may remove bookings.
    expect(find.text('Person zuweisen'), findsNWidgets(2));
    expect(find.byTooltip('Sam Vorhang entfernen'), findsOneWidget);
    expect(find.text('1 von 1 Eingeladenen haben gebucht'), findsNothing);
    await tester.tap(find.text('Person zuweisen').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      ),
      'kim',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kim Kulisse'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'slot.assign',
      'poolId': 'pool-1',
      'personId': 4,
      'slotId': 's1',
    });
    await tester.tap(find.byTooltip('Sam Vorhang entfernen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Entfernen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'slot.assign',
      'poolId': 'pool-1',
      'personId': 5,
      'slotId': null,
    });

    server.data['slotPools'] = [pool(closed: true)];
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Geschlossen'), findsOneWidget);
    expect(find.text('Buchung geschlossen'), findsOneWidget);
    expect(find.text('Buchen'), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('admins close and delete a pool from the menu', (tester) async {
    await surface(tester, const Size(360, 1600));
    final server = SlotServer(role: 'admin')..data['slotPools'] = [pool()];
    final controller = await start(server);
    await tester.pumpWidget(
      screen(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openSlotPool(context, controller, 'pool-1'),
              child: const Text('öffnen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Terminfinder verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Buchung schließen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'slotPool.close',
      'id': 'pool-1',
      'version': 3,
      'closed': true,
    });
    await tester.tap(find.byTooltip('Terminfinder verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    expect(find.text('Terminfinder löschen?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'slotPool.delete',
      'id': 'pool-1',
      'version': 3,
    });
    expect(find.text('öffnen'), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('the editor generates gapless slots and sends them', (
    tester,
  ) async {
    await surface(tester, const Size(800, 3000));
    final server = SlotServer(role: 'admin');
    final controller = await start(server);
    await tester.pumpWidget(
      screen(SlotPoolEditorScreen(controller: controller)),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Titel'),
      'Fototermin',
    );
    expect(find.text('Eingeladen: Alle'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('slot-to')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '10');
    await tester.enterText(fields.at(1), '45');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('10:45 Uhr'), findsOneWidget);
    expect(
      find.text('Ergibt 3 Zeitfenster von 10:00 bis 10:45 Uhr.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Slots hinzufügen'));
    await tester.pumpAndSettle();
    expect(find.text('Zeitfenster (3)'), findsOneWidget);
    expect(find.byTooltip('Zeitfenster entfernen'), findsNWidgets(3));
    // Adding the same day again does not duplicate windows.
    await tester.tap(find.text('Slots hinzufügen'));
    await tester.pumpAndSettle();
    expect(find.text('Zeitfenster (3)'), findsOneWidget);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final body = server.actionBodies.last;
    expect(body['action'], 'slotPool.save');
    expect(body['title'], 'Fototermin');
    expect(body['type'], 'other');
    expect(body['roleIds'], isEmpty);
    expect(body['personIds'], isEmpty);
    final day = fixedDay();
    expect(body['slots'], [
      for (final minute in [0, 15, 30])
        {
          'startsAt': day
              .add(Duration(minutes: minute))
              .toUtc()
              .toIso8601String(),
          'endsAt': day
              .add(Duration(minutes: minute + 15))
              .toUtc()
              .toIso8601String(),
          'capacity': 1,
        },
    ]);
    await finish(tester, controller);
  });

  testWidgets('editing keeps slot ids and protects booked slots', (
    tester,
  ) async {
    await surface(tester, const Size(800, 3000));
    final server = SlotServer(role: 'admin')..data['slotPools'] = [pool()];
    final controller = await start(server);
    await tester.pumpWidget(
      screen(
        SlotPoolEditorScreen(
          controller: controller,
          pool: controller.slotPools.single,
        ),
      ),
    );
    expect(find.text('Zeitfenster (3)'), findsOneWidget);
    expect(find.text('1 von 2 gebucht'), findsOneWidget);
    expect(find.text('1 von 1 gebucht'), findsOneWidget);
    // Only the unbooked s3 can be removed.
    expect(find.byTooltip('Zeitfenster entfernen'), findsOneWidget);
    await tester.tap(find.byTooltip('Zeitfenster entfernen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final body = server.actionBodies.last;
    expect(body['id'], 'pool-1');
    expect(body['version'], 3);
    expect([for (final s in body['slots'] as List) s['id']], ['s1', 's2']);
    await finish(tester, controller);
  });

  testWidgets('slot pool events show no RSVP but a way to the pool', (
    tester,
  ) async {
    await surface(tester, const Size(360, 1600));
    final server = SlotServer()
      ..data['slotPools'] = [pool(myBooking: 's1', alexInFirst: true)]
      ..data['events'] = [
        {
          'id': 'slot-pool-1-s1',
          'title': 'Fototermin',
          'startsAt': '2026-09-19T08:00:00Z',
          'endsAt': '2026-09-19T08:15:00Z',
          'personIds': [1, 3],
          'slotPoolId': 'pool-1',
        },
      ]
      ..data['attendanceByEvent'] = {'slot-pool-1-s1': 'yes'};
    final controller = await start(server);
    final event = controller.events.single;
    expect(event.slotPoolId, 'pool-1');
    expect(event.needsResponse, isFalse);
    expect(controller.canRespondTo(event), isFalse);
    await tester.pumpWidget(
      screen(EventDetailScreen(controller: controller, eventId: event.id)),
    );
    expect(find.text('Bin dabei'), findsNothing);
    expect(find.text('Kann nicht'), findsNothing);
    expect(find.textContaining('Rückmeldungen sind geschlossen'), findsNothing);
    expect(find.text('Über den Terminfinder gebucht'), findsOneWidget);
    await tester.tap(find.text('Terminfinder öffnen'));
    await tester.pumpAndSettle();
    expect(find.byType(SlotPoolScreen), findsOneWidget);
    expect(find.text('Freigeben'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      screen(
        Scaffold(
          body: EventCard(event: event, controller: controller),
        ),
      ),
    );
    final badge = tester.widget<RsvpStatusBadge>(find.byType(RsvpStatusBadge));
    expect(badge.status, 'yes');
    expect(badge.locked, isFalse);
    expect(tester.takeException(), isNull);
    await finish(tester, controller);
  });

  testWidgets('overview marks open choices and fits phones at large text', (
    tester,
  ) async {
    await surface(tester, const Size(360, 1400));
    final server = SlotServer(role: 'admin')
      ..data['slotPools'] = [
        pool(),
        {
          ...pool(myBooking: 's1', alexInFirst: true, closed: true),
          'id': 'pool-2',
          'title':
              'Kostümanprobe mit einem sehr langen Titel für kleine Bildschirme',
        },
      ];
    final controller = await start(server);
    expect(slotPoolsAwaitingChoice(controller), 1);
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        screen(SlotPoolsScreen(controller: controller), textScale: scale),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'overview at $scale');
      expect(find.text('Fototermin'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen(SlotPoolsScreen(controller: controller)));
    expect(find.text('Noch kein Slot gewählt'), findsOneWidget);
    expect(find.text('Dein Slot: $firstSlot'), findsOneWidget);
    expect(find.text('Geschlossen'), findsOneWidget);
    expect(find.byTooltip('Terminfinder anlegen'), findsOneWidget);
    expect(
      find.textContaining(
        'Sa 19.9., ${hm('2026-09-19T08:00:00Z')}–${hm('2026-09-19T08:45:00Z')}',
      ),
      findsNWidgets(2),
    );

    for (final (page, title) in [
      (SlotPoolScreen(controller: controller, poolId: 'pool-1'), 'Fototermin'),
      (
        SlotPoolScreen(controller: controller, poolId: 'pool-2'),
        'Kostümanprobe',
      ),
      (
        SlotPoolEditorScreen(
          controller: controller,
          pool: controller.slotPools.first,
        ),
        'Terminfinder bearbeiten',
      ),
    ]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(screen(page, textScale: 2));
      await tester.pumpAndSettle();
      expect(find.textContaining(title), findsWidgets);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$page at 2x');
    }
    await finish(tester, controller);
  });

  test('push data and links open a slot pool', () {
    final data = AppTarget.fromData({'slotPoolId': 'pool-1'});
    expect((data?.kind, data?.id), ('slots', 'pool-1'));
    final link = AppTarget.fromUri(Uri.parse('theaterapp://app/slots/pool-1'));
    expect((link?.kind, link?.id), ('slots', 'pool-1'));
    expect(
      slotWindows(
        DateTime(2026, 1, 1, 10),
        DateTime(2026, 1, 1, 10, 50),
        15,
      ).length,
      3,
    );
  });
}

/// 10:00 on the day after the fixed test clock, the editor's default day.
DateTime fixedDay() => DateTime(2026, 9, 13, 10);
