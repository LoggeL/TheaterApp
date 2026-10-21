import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/deep_links.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/app/shell/app_section.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/rehearsal/rehearsal.dart';
import 'package:theater_app/features/settings/settings.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;
import 'app_platform_test.dart' show demoController;

// "Alle gelten als zugesagt": invitees without an own answer attend unless
// they decline.
class _MemberServer extends TestServer {
  @override
  JsonMap get user => {...super.user, 'role': 'member'};
}

const _features = ['autoAccept', 'pushSettings', 'seriesEdit', 'seriesManage'];

String _at(Duration offset) => fixedNow.add(offset).toUtc().toIso8601String();

JsonMap _event(
  String id, {
  Duration start = const Duration(days: 3),
  bool auto = true,
  JsonMap extra = const {},
}) => {
  'id': id,
  'title': 'Probe $id',
  'startsAt': _at(start),
  'endsAt': _at(start + const Duration(hours: 2)),
  'place': 'Saal',
  if (auto) ...{'autoAccept': true, 'implicitYes': true, 'implicitPeople': 3},
  ...extra,
};

T _server<T extends TestServer>(T server, List<JsonMap> events) {
  server.data['events'] = events;
  server.data['attendanceByEvent'] = <String, dynamic>{};
  server.data['capabilities'] = {'pushConfigured': true, 'features': _features};
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Widget app(Widget home) =>
      MaterialApp(theme: StageTheme.build(Brightness.light), home: home);

  /// Opens [page] as a route above a start page, like the app does.
  Future<void> openRoute(WidgetTester tester, Widget Function() page) async {
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => page()),
                ),
                child: const Text('öffnen'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
  }

  Future<void> surface(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.dragUntilVisible(
      target,
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester, AppController controller) async {
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  test('the event model keeps auto-accept through the cache and copies', () {
    final event = TheaterEvent.fromJson(_event('a', extra: {'people': 5}));
    expect(
      [event.autoAccept, event.implicitYes, event.implicitCount],
      [true, true, 3],
    );
    expect(event.attendeeCount, 5);
    expect(event.needsResponse, isFalse, reason: 'nobody owes an answer');
    expect(event.attending, isTrue);
    final copy = TheaterEvent.fromJson(
      event.copyWith(response: 'no', implicitYes: false).toJson(),
    );
    expect(
      [copy.autoAccept, copy.implicitYes, copy.implicitCount, copy.response],
      [true, false, 3, 'no'],
    );
    expect(copy.attending, isFalse);
    expect(TheaterEvent.fromJson(event.toJson()).implicitYes, isTrue);
    final plain = TheaterEvent.fromJson(_event('b', auto: false));
    expect([plain.autoAccept, plain.implicitYes], [false, false]);
    expect(plain.needsResponse, isTrue);
    expect(plain.toJson().containsKey('autoAccept'), isFalse);
  });

  test(
    'the implicit yes follows queued answers and absences offline',
    () async {
      final server = _server(_MemberServer(), [
        _event('soon', start: const Duration(minutes: 30)),
        _event('later'),
        _event('plain', auto: false),
      ]);
      final controller = server.controller();
      await signIn(controller);
      TheaterEvent event(String id) =>
          controller.events.firstWhere((e) => e.id == id);
      expect(event('later').implicitYes, isTrue);
      // Only the plain event waits for an answer.
      expect(unansweredSoon(controller, fixedNow), 1);
      server.offline = true;
      await controller.respond('later', 'no');
      expect(event('later').implicitYes, isFalse);
      await controller.respond('later', 'open');
      expect(event('later').implicitYes, isTrue);
      // Within the decline cutoff the offline projection writes no decline
      // (the server records one), yet the absence ends the implicit yes.
      await controller.addAbsence(fixedNow, fixedNow, 'Krank');
      expect(event('soon').response, 'open');
      expect(event('soon').implicitYes, isFalse);
      expect(event('later').implicitYes, isTrue);
      controller.dispose();
    },
  );

  test('planning counts implicit attendees as yes and the absent as no', () {
    final event = TheaterEvent.fromJson(_event('e'));
    final responses = effectiveResponses(
      event,
      {'1': 'yes', '2': 'open', '9': 'late'},
      [1, 2, 3, 4],
      {2, 3},
    );
    expect(responses, {
      '1': 'yes',
      '2': 'yes',
      '3': 'yes',
      '4': 'no',
      '9': 'late',
    });
    expect(
      effectiveResponses(
        TheaterEvent.fromJson(_event('p', auto: false)),
        {'2': 'open'},
        [1, 2],
        {1, 2},
      ),
      {'2': 'open'},
    );
  });

  testWidgets('the editor offers auto-accept only on servers that know it', (
    tester,
  ) async {
    await surface(tester, const Size(1000, 2400));
    final old = TestServer()..data['capabilities'] = {'pushConfigured': true};
    var controller = old.controller();
    await signIn(controller);
    await openRoute(tester, () => EventEditorScreen(controller: controller));
    expect(find.byKey(const ValueKey('event-auto-accept')), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Probe');
    await scrollTo(tester, find.text('Termin speichern'));
    await tester.tap(find.text('Termin speichern'));
    await tester.pumpAndSettle();
    expect(old.actionBodies.last.containsKey('autoAccept'), isFalse);
    await finish(tester, controller);

    final server = _server(TestServer(), []);
    controller = server.controller();
    await signIn(controller);
    await openRoute(tester, () => EventEditorScreen(controller: controller));
    final toggle = find.byKey(const ValueKey('event-auto-accept'));
    await scrollTo(tester, toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(
      find.text(
        'Eingeladene sagen nur ab, wenn sie nicht können. Sie werden zwei '
        'Tage vorher erinnert.',
      ),
      findsOneWidget,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    // The switch alone counts as unsaved input.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Weiter bearbeiten'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Probe');
    await scrollTo(tester, find.text('Termin speichern'));
    await tester.tap(find.text('Termin speichern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'event.save');
    expect(server.actionBodies.last['autoAccept'], isTrue);
    await finish(tester, controller);
  });

  testWidgets('switching auto-accept off warns; series edits carry it', (
    tester,
  ) async {
    await surface(tester, const Size(1000, 2400));
    final server = _server(TestServer(), [
      _event('a', extra: {'seriesId': 's1'}),
    ]);
    final controller = server.controller();
    await signIn(controller);
    await openRoute(
      tester,
      () => EventEditorScreen(
        controller: controller,
        event: controller.events.single,
      ),
    );
    await tester.tap(find.text('Ganze Serie'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('event-auto-accept'));
    await scrollTo(tester, toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Wer nicht ausdrücklich zugesagt hat, gilt danach wieder als offen.',
      ),
      findsOneWidget,
    );
    await scrollTo(tester, find.text('Serie speichern'));
    await tester.tap(find.text('Serie speichern'));
    await tester.pumpAndSettle();
    final body = server.actionBodies.last;
    expect([body['autoAccept'], body['series']], [false, 'all']);
    await finish(tester, controller);
  });

  testWidgets('members see that they are planned in and may only decline', (
    tester,
  ) async {
    await surface(tester, const Size(500, 1600));
    final server = _server(_MemberServer(), [_event('a')]);
    final controller = server.controller();
    await signIn(controller);
    await openRoute(
      tester,
      () => EventDetailScreen(controller: controller, eventId: 'a'),
    );
    expect(find.text('Du bist eingeplant'), findsOneWidget);
    expect(find.text('automatisch'), findsOneWidget);
    expect(
      find.text('Alle gelten als zugesagt. Kannst du nicht? Bitte absagen.'),
      findsOneWidget,
    );
    expect(find.text('Alle gelten als zugesagt'), findsOneWidget);
    expect(find.text('Rückmeldung zurücknehmen'), findsNothing);
    expect(find.text('Absage zurücknehmen'), findsNothing);

    await tester.tap(find.text('Kann nicht'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Absagen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['status'], 'no');
    expect(find.text('Bist du dabei?'), findsOneWidget);
    expect(find.text('automatisch'), findsNothing);

    await tester.ensureVisible(find.text('Absage zurücknehmen'));
    await tester.tap(find.text('Absage zurücknehmen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['status'], 'open');
    expect(find.text('Du bist wieder eingeplant.'), findsOneWidget);
    expect(find.text('Du bist eingeplant'), findsOneWidget);
    expect(find.text('automatisch'), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('an absence without a decline row is not "eingeplant"', (
    tester,
  ) async {
    await surface(tester, const Size(500, 1600));
    final server = _server(_MemberServer(), [_event('a')]);
    final day = fixedNow.add(const Duration(days: 3));
    final date =
        '${day.year}-${'${day.month}'.padLeft(2, '0')}-${'${day.day}'.padLeft(2, '0')}';
    server.data['absences'] = [
      {'id': 'x', 'from': date, 'to': date, 'reason': 'Urlaub'},
    ];
    final controller = server.controller();
    await signIn(controller);
    expect(controller.events.single.implicitYes, isFalse);
    await openRoute(
      tester,
      () => EventDetailScreen(controller: controller, eventId: 'a'),
    );
    expect(find.text('Bist du dabei?'), findsOneWidget);
    expect(find.text('Du bist eingeplant'), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('withdrawing a decline offline says it is only queued', (
    tester,
  ) async {
    await surface(tester, const Size(500, 1600));
    final server = _server(_MemberServer(), [
      _event('a', extra: {'implicitYes': false}),
    ]);
    server.data['attendanceByEvent'] = {'a': 'no'};
    final controller = server.controller();
    await signIn(controller);
    await openRoute(
      tester,
      () => EventDetailScreen(controller: controller, eventId: 'a'),
    );
    server.offline = true;
    await tester.ensureVisible(find.text('Absage zurücknehmen'));
    await tester.tap(find.text('Absage zurücknehmen'));
    await tester.pumpAndSettle();
    expect(
      find.text('Rücknahme vorgemerkt – wird bei Verbindung gesendet'),
      findsOneWidget,
    );
    expect(find.text('Du bist wieder eingeplant.'), findsNothing);
    expect(find.text('Auf diesem Gerät vorgemerkt'), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('the schedule neither asks for nor misses implicit answers', (
    tester,
  ) async {
    await surface(tester, const Size(500, 1400));
    final server = _server(_MemberServer(), [
      _event('auto'),
      _event('plain', auto: false, start: const Duration(days: 4)),
    ]);
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      app(Scaffold(body: ScheduleScreen(controller: controller))),
    );
    await tester.pumpAndSettle();
    Finder count(String chip, String n) => find.descendant(
      of: find.widgetWithText(ChoiceChip, chip),
      matching: find.text(n),
    );
    expect(count('Offen', '1'), findsOneWidget);
    expect(count('Zugesagt', '1'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Zugesagt'));
    await tester.pumpAndSettle();
    expect(find.text('Probe auto'), findsOneWidget);
    expect(find.text('Probe plain'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Eingeplant')), findsWidgets);
    await finish(tester, controller);
  });

  testWidgets('the overview counts implicit attendees and offers no nudge', (
    tester,
  ) async {
    await surface(tester, const Size(1000, 2400));
    final server = _server(TestServer(), [_event('e')]);
    // Alex dabei, Robin später, Toni und Kim automatisch, Sam abwesend.
    server.data['memberAttendanceByEvent'] = {
      'e': {'1': 'yes', '2': 'late'},
    };
    server.data['implicitAttendanceByEvent'] = {
      'e': [3, 4],
    };
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      app(
        ResponsesAdminScreen(
          controller: controller,
          event: controller.events.single,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('4 dabei, davon 2 automatisch · 1 abgesagt'),
      findsOneWidget,
    );
    expect(find.text('automatisch'), findsNWidgets(2));
    expect(find.text('Noch keine Rückmeldung'), findsNothing);
    expect(find.text('Offene erinnern'), findsNothing);
    expect(
      find.text('Eingeplante werden zwei Tage vorher automatisch erinnert.'),
      findsOneWidget,
    );
    final event = controller.events.single;
    expect(memberResponseLabel(controller, event, 3), 'Eingeplant');
    // Sam's absence covers the day: declined, not open.
    expect(memberResponseLabel(controller, event, 5), 'Abgesagt');
    expect(memberResponseLabel(controller, event, 1), isNot('Eingeplant'));
    // Within two days the reminder is out; below two hours none goes out.
    TheaterEvent startingIn(Duration d) =>
        TheaterEvent.fromJson(_event('x', start: d));
    expect(
      plannedReminderNote(controller, startingIn(const Duration(hours: 20))),
      'Eingeplante wurden automatisch erinnert.',
    );
    expect(
      plannedReminderNote(controller, startingIn(const Duration(hours: 1))),
      isNull,
    );
    expect(
      plannedReminderNote(
        controller,
        TheaterEvent.fromJson(_event('y', auto: false)),
      ),
      isNull,
    );
    expect(plannedResponses(controller, controller.events.single), {
      '1': 'yes',
      '2': 'late',
      '3': 'yes',
      '4': 'yes',
      '5': 'no',
    });
    await finish(tester, controller);
  });

  test('"Du bist eingeplant" notifications offer "Ok" and the decline', () {
    NotificationResponse response(String? action, String actions) =>
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: action,
          payload:
              '{"eventId":"e-1","recipientUid":"member-a",'
              '"attendanceActions":"$actions","intent":"decline"}',
        );
    expect(
      AppTarget.fromNotificationResponse(response('no', 'planned'))!.attendance,
      'no',
    );
    // "Ok" sends an explicit yes.
    expect(
      AppTarget.fromNotificationResponse(
        response('yes', 'planned'),
      )!.attendance,
      'yes',
    );
    // Unknown action values give no quick answer.
    expect(
      AppTarget.fromNotificationResponse(
        response('yes', 'decline'),
      )!.attendance,
      isNull,
    );
    // A tap on the body opens the decline sheet.
    final tap = AppTarget.fromNotificationResponse(response(null, 'planned'))!;
    expect(
      [tap.kind, tap.id, tap.intent, tap.attendance],
      ['events', 'e-1', 'decline', null],
    );
    final link = AppTarget.fromWebUri(
      Uri.parse(
        'https://theater.example/?target=${Uri.encodeComponent('theaterapp://app/events/e-1?intent=decline')}',
      ),
    )!;
    expect([link.kind, link.id, link.intent], ['events', 'e-1', 'decline']);
    expect(
      AppTarget.fromUri(Uri.parse('theaterapp://app/events/e-1'))!.intent,
      isNull,
    );
    expect(
      AppTarget.fromUri(
        Uri.parse('theaterapp://app/polls/p?intent=decline'),
      )!.intent,
      isNull,
    );
  });

  // "Ok" turns the implicit yes into an explicit one, "Komme nicht" declines.
  for (final (action, saved) in [
    ('yes', 'Zusage gespeichert.'),
    ('no', 'Absage gespeichert.'),
  ]) {
    test('the "Du bist eingeplant" action $action is sent as answer', () async {
      final server = _server(_MemberServer(), [_event('a')]);
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      expect(controller.events.single.implicitYes, isTrue);
      final target = AppTarget.fromNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: action,
          payload:
              '{"eventId":"a","recipientUid":"member-a",'
              '"attendanceActions":"planned","intent":"decline"}',
        ),
      )!;
      final message = await controller.respondFromNotification(
        target.id,
        target.attendance!,
        target.recipientUid!,
      );
      expect(message, saved);
      expect(server.actionBodies.last['status'], action);
      final event = controller.events.single;
      expect(event.response, action);
      // Now an own answer: no longer "automatisch".
      expect(event.implicitYes, isFalse);
    });
  }

  testWidgets('a decline link opens the event with the decline sheet once', (
    tester,
  ) async {
    await surface(tester, const Size(500, 1400));
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
    router.handle(
      AppTarget.fromUri(
        Uri.parse('theaterapp://app/events/demo-build?intent=decline'),
      )!,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EventDetailScreen>(find.byType(EventDetailScreen))
          .openDecline,
      isTrue,
    );
    expect(find.text('Dieses Mal ohne dich.'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('Dieses Mal ohne dich.'), findsNothing);
    // Rebuilds do not bring it back.
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Dieses Mal ohne dich.'), findsNothing);
    await finish(tester, c);
  });

  for (final flagged in [true, false]) {
    testWidgets('the planned reminder can be switched off '
        '${flagged ? 'with' : 'only with'} the flag', (tester) async {
      await surface(tester, const Size(1000, 3600));
      final server = _MemberServer();
      server.data['capabilities'] = {
        'features': ['pushSettings', if (flagged) 'autoAccept'],
      };
      final controller = server.controller();
      await signIn(controller);
      expect(controller.reminders['eventPlanned'], isTrue);
      final devices = DeviceServices(
        controller,
        onTarget: (_) {},
        onForegroundMessage: (_) {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(controller: controller, devices: devices),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(
        SwitchListTile,
        'Eingeplant-Erinnerung',
      );
      expect(toggle, flagged ? findsOneWidget : findsNothing);
      if (flagged) {
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          jsonMap(server.actionBodies.last['value'])['eventPlanned'],
          false,
        );
      }
      await finish(tester, controller);
    });
  }
}
