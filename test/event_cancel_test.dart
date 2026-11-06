import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/today/domain/today_digest.dart';
import 'package:theater_app/features/today/today.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

// "Termin absagen" (servers with `eventCancel`): the event stays, marked as
// cancelled; answers are closed.
class _MemberServer extends TestServer {
  @override
  JsonMap get user => {...super.user, 'role': 'member'};
}

String _at(Duration offset) => fixedNow.add(offset).toUtc().toIso8601String();

JsonMap _event(
  String id, {
  Duration start = const Duration(days: 2),
  bool cancelled = false,
  JsonMap extra = const {},
}) => {
  'id': id,
  'title': 'Probe $id',
  'startsAt': _at(start),
  'endsAt': _at(start + const Duration(hours: 2)),
  'place': 'Probensaal',
  'version': 3,
  if (cancelled) ...{
    'cancelledAt': _at(const Duration(hours: -1)),
    'cancelReason': 'Saal belegt',
  },
  ...extra,
};

T _server<T extends TestServer>(
  T server,
  List<JsonMap> events, {
  List<String> features = const ['eventCancel'],
  bool push = true,
}) {
  server.data['events'] = events;
  server.data['attendanceByEvent'] = <String, dynamic>{};
  server.data['capabilities'] = {'pushConfigured': push, 'features': features};
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Widget app(Widget home) =>
      MaterialApp(theme: StageTheme.build(Brightness.light), home: home);

  /// Opens the detail of [id] as a route above a start page.
  Future<AppController> open(
    WidgetTester tester,
    TestServer server,
    String id,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        EventDetailScreen(controller: controller, eventId: id),
                  ),
                ),
                child: const Text('Start'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> finish(WidgetTester tester, AppController controller) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  test('a cancelled event takes no answers and keeps its mark', () {
    final event = TheaterEvent.fromJson(
      _event('a', cancelled: true, extra: {'cancelledBy': 7}),
    );
    expect(event.cancelled, isTrue);
    expect([event.cancelReason, event.cancelledBy], ['Saal belegt', 7]);
    expect(event.needsResponse, isFalse);
    expect(event.acceptsResponsesAt(fixedNow), isFalse);
    expect(event.acceptsDeclineAt(fixedNow), isFalse);
    expect(eventMarker(event, fixedNow, isNext: true), isNull);
    final copy = TheaterEvent.fromJson(
      event.copyWith(response: 'yes').toJson(),
    );
    expect(copy.cancelled, isTrue);
    expect(copy.cancelReason, 'Saal belegt');
    expect(copy.attending, isFalse, reason: 'nobody attends it');
    final plain = TheaterEvent.fromJson(_event('b'));
    expect([plain.cancelled, plain.needsResponse], [false, true]);
    expect(plain.toJson().containsKey('cancelledAt'), isFalse);
    // The calendar export marks it as cancelled, like the server's feed.
    final ics = calendarFile(event, now: fixedNow);
    expect(ics, contains('STATUS:CANCELLED'));
    expect(ics, contains('SUMMARY:Abgesagt: Probe a'));
    expect(calendarFile(plain, now: fixedNow), isNot(contains('CANCELLED')));
  });

  test(
    'open-answer badges and implicit attendance skip cancelled events',
    () async {
      final server = _server(_MemberServer(), [
        _event('open'),
        _event('off', cancelled: true),
        _event(
          'auto',
          cancelled: true,
          extra: {'autoAccept': true, 'implicitYes': true},
        ),
      ]);
      final controller = server.controller();
      await signIn(controller);
      TheaterEvent event(String id) =>
          controller.events.firstWhere((e) => e.id == id);
      expect(unansweredSoon(controller, fixedNow), 1);
      expect(event('auto').implicitYes, isFalse);
      expect(controller.canRespondTo(event('off')), isFalse);
      await expectLater(
        controller.respond('off', 'yes'),
        throwsA(isA<ApiException>()),
      );
      expect(
        server.actionBodies.where((b) => b['action'] == 'attendance'),
        isEmpty,
      );
      controller.dispose();
    },
  );

  testWidgets(
    'members see the cancellation with its reason and cannot answer',
    (tester) async {
      final server = _server(_MemberServer(), [_event('a', cancelled: true)]);
      final controller = await open(tester, server, 'a');
      expect(find.text('Abgesagt'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('event-cancelled-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('Grund: Saal belegt'), findsOneWidget);
      expect(find.byType(RsvpPanel), findsNothing);
      expect(find.text('Bin dabei'), findsNothing);
      expect(find.text('Termin absagen'), findsNothing);
      final title = tester.widget<Text>(find.text('Probe a').first);
      expect(title.style?.decoration, TextDecoration.lineThrough);
      await finish(tester, controller);
    },
  );

  testWidgets('admins call an event off with a reason after confirming', (
    tester,
  ) async {
    final server = _server(TestServer(), [_event('a')]);
    final controller = await open(tester, server, 'a');
    final cancel = find.byKey(const ValueKey('event-cancel'));
    await tester.ensureVisible(cancel);
    await tester.pumpAndSettle();
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.text('Termin absagen?'), findsOneWidget);
    expect(
      find.text('Wer zugesagt hat, erfährt per Push von der Absage.'),
      findsOneWidget,
    );
    // Cancelling the dialog sends nothing.
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies, isEmpty);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('event-cancel-reason')),
      '  Saal\nbelegt ',
    );
    await tester.tap(find.byKey(const ValueKey('event-cancel-confirm')));
    await tester.pumpAndSettle();
    final body = server.actionBodies.single;
    expect(
      [body['action'], body['id'], body['version'], body['reason']],
      ['event.cancel', 'a', 3, 'Saal belegt'],
    );
    expect(find.text('Termin abgesagt'), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('the push notice follows auto-accept and the push setup', (
    tester,
  ) async {
    final server = _server(TestServer(), [
      _event('a', extra: {'autoAccept': true}),
    ], push: false);
    var controller = await open(tester, server, 'a');
    final cancel = find.byKey(const ValueKey('event-cancel'));
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Push ist nicht eingerichtet, es geht keine Benachrichtigung raus.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    await finish(tester, controller);

    controller = await open(
      tester,
      _server(TestServer(), [
        _event('a', extra: {'autoAccept': true}),
      ]),
      'a',
    );
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Alle Eingeladenen, die nicht abgesagt haben, erfahren per Push von '
        'der Absage.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    await finish(tester, controller);
  });

  testWidgets('admins withdraw a cancellation; older servers offer neither', (
    tester,
  ) async {
    final server = _server(TestServer(), [_event('a', cancelled: true)]);
    var controller = await open(tester, server, 'a');
    expect(find.byKey(const ValueKey('event-cancel')), findsNothing);
    // Nobody attends a cancelled event: no check-in.
    expect(find.text('Anwesenheit erfassen'), findsNothing);
    final undo = find.byKey(const ValueKey('event-uncancel'));
    await tester.ensureVisible(undo);
    await tester.pumpAndSettle();
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(find.text('Absage zurücknehmen?'), findsOneWidget);
    await tester.tap(find.text('Zurücknehmen'));
    await tester.pumpAndSettle();
    final body = server.actionBodies.single;
    expect(
      [body['action'], body['id'], body['version']],
      ['event.uncancel', 'a', 3],
    );
    expect(body.containsKey('reason'), isFalse);
    await finish(tester, controller);

    controller = await open(
      tester,
      _server(TestServer(), [_event('b')], features: const []),
      'b',
    );
    expect(find.byKey(const ValueKey('event-cancel')), findsNothing);
    expect(find.byKey(const ValueKey('event-uncancel')), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('past events and Terminfinder events cannot be called off', (
    tester,
  ) async {
    final controller = await open(
      tester,
      _server(TestServer(), [_event('past', start: const Duration(days: -2))]),
      'past',
    );
    expect(find.byKey(const ValueKey('event-cancel')), findsNothing);
    final slot = TheaterEvent.fromJson(_event('s', extra: {'slotPoolId': 'p'}));
    expect(canCancelEvent(controller, slot), isFalse);
    await finish(tester, controller);
  });

  testWidgets('a queued cancellation shows at once and closes answers', (
    tester,
  ) async {
    final server = _server(TestServer(), [_event('a')]);
    final controller = server.controller();
    await signIn(controller);
    server.offline = true;
    final outcome = await controller.performAction({
      'action': 'event.cancel',
      'id': 'a',
      'version': 3,
      'reason': 'Saal belegt',
    });
    expect(outcome, ActionOutcome.queued);
    final event = controller.events.single;
    expect(
      [event.cancelled, event.cancelReason, event.version],
      [true, 'Saal belegt', 4],
    );
    expect(controller.canRespondTo(event), isFalse);
    controller.dispose();
  });

  testWidgets(
    'the start page neither offers nor leads with a cancelled event',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _server(_MemberServer(), [
        _event('off', start: const Duration(days: 1), cancelled: true),
        _event('next', start: const Duration(days: 3)),
      ]);
      server.data['attendanceByEvent'] = {'off': 'yes', 'next': 'yes'};
      final controller = server.controller();
      await signIn(controller);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => TodayScreen(
                controller: controller,
                onPlan: () {},
                onScripts: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final digest = TodayDigest.from(controller);
      expect(digest.next?.id, 'next');
      expect(digest.openResponses, isEmpty);
      // The cancelled one is listed further down, marked as such.
      expect(digest.laterEvents.map((e) => e.id), contains('off'));
      final off = find.text('Probe off');
      await tester.scrollUntilVisible(off, 200);
      expect(find.text('Abgesagt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('the quick answer turns into a note for a cancelled event', (
    tester,
  ) async {
    final server = _server(_MemberServer(), [_event('off', cancelled: true)]);
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: QuickRsvp(
            event: controller.events.single,
            controller: controller,
            dense: true,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('quick-rsvp-cancelled')), findsOneWidget);
    expect(find.text('Bin dabei'), findsNothing);
    expect(find.text('Kann nicht'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
