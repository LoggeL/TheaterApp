import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/features/events/events.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

class _MemberServer extends TestServer {
  @override
  JsonMap get user => {...super.user, 'role': 'member'};
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  /// Opens the detail of [id] as a route above a start page.
  Future<AppController> open(
    WidgetTester tester,
    TestServer server,
    String id,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(
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

  testWidgets('admins edit an event from its page', (tester) async {
    final server = TestServer()..data['events'] = [_event('a')];
    final controller = await open(tester, server, 'a');
    await tester.tap(find.byTooltip('Termin bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.byType(EventEditorScreen), findsOneWidget);
    expect(
      tester
          .widget<EventEditorScreen>(find.byType(EventEditorScreen))
          .event
          ?.id,
      'a',
    );
    await finish(tester, controller);
  });

  testWidgets('members see no edit action', (tester) async {
    final server = _MemberServer()..data['events'] = [_event('a')];
    final controller = await open(tester, server, 'a');
    expect(find.byTooltip('Termin bearbeiten'), findsNothing);
    expect(find.text('Probenleitung'), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('deleting from the editor also leaves the event page', (
    tester,
  ) async {
    final server = TestServer()..data['events'] = [_event('a')];
    final controller = await open(tester, server, 'a');
    await tester.tap(find.byTooltip('Termin bearbeiten'));
    await tester.pumpAndSettle();
    final delete = find.text('Termin löschen');
    await tester.ensureVisible(delete);
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Termin löschen?'), findsOneWidget);
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'event.delete');
    expect(server.actionBodies.last.containsKey('series'), isFalse);
    expect(find.byType(EventEditorScreen), findsNothing);
    expect(find.byType(EventDetailScreen), findsNothing);
    expect(find.text('Termin gelöscht'), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('the audience row also names production ensembles', (
    tester,
  ) async {
    final server = TestServer()
      ..data['events'] = [
        _event(
          'a',
          extra: {
            'productionIds': [DemoData.mainProductionId],
          },
        ),
        _event('b', extra: {'description': 'Bitte Textbuch mitbringen.'}),
      ];
    var controller = await open(tester, server, 'a');
    final ensemble = controller.audienceLabel(const [], const [], const [
      DemoData.mainProductionId,
    ]);
    expect(ensemble, startsWith('Ensemble '));
    expect(find.text('Für $ensemble'), findsOneWidget);
    await finish(tester, controller);

    controller = await open(tester, server, 'b');
    expect(find.text('Für alle'), findsOneWidget);
    // The date heads the page instead of the theater's name.
    final event = controller.events.firstWhere((e) => e.id == 'b');
    expect(find.text(eventDate(event).toUpperCase()), findsOneWidget);
    expect(find.text('KOLPINGTHEATER RAMSEN'), findsNothing);
    // The description follows the response.
    expect(find.text('Beschreibung'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Bist du dabei?')).dy,
      lessThan(tester.getTopLeft(find.text('Beschreibung')).dy),
    );
    // On the route the export sits in the app bar only.
    expect(find.byTooltip('In Kalender übernehmen'), findsOneWidget);
    expect(find.text('In Kalender übernehmen'), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('queued changes are not repeated on the event page', (
    tester,
  ) async {
    final server = TestServer()..data['events'] = [_event('a')];
    final controller = await open(tester, server, 'a');
    server.offline = true;
    await tester.tap(find.text('Bin dabei'));
    await tester.pumpAndSettle();
    expect(controller.pendingCount, 1);
    expect(find.text('Auf diesem Gerät vorgemerkt'), findsOneWidget);
    expect(find.textContaining('warten auf Übertragung'), findsNothing);
    await finish(tester, controller);
  });

  testWidgets('a missing event keeps the page title', (tester) async {
    final server = TestServer()..data['events'] = [_event('a')];
    final controller = await open(tester, server, 'weg');
    expect(find.text('Termin nicht verfügbar'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Termin')),
      findsOneWidget,
    );
    await finish(tester, controller);
  });

  testWidgets('the inline desktop detail offers editing and export', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1360, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final server = TestServer()..data['events'] = [_event('a')];
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(body: ScheduleScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final edit = find.widgetWithText(FilledButton, 'Bearbeiten');
    expect(edit, findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Probenleitung')).dy,
      lessThan(tester.getTopLeft(edit).dy),
    );
    expect(
      tester.getTopLeft(edit).dy,
      lessThan(tester.getTopLeft(find.text('Rückmeldungen ansehen')).dy),
    );
    expect(find.text('In Kalender übernehmen'), findsOneWidget);
    await tester.ensureVisible(edit);
    await tester.pumpAndSettle();
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.byType(EventEditorScreen), findsOneWidget);
    await finish(tester, controller);
  });

  testWidgets('response choices are announced as one exclusive group', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final server = TestServer()..data['events'] = [_event('a')];
    final controller = await open(tester, server, 'a');
    await tester.tap(find.text('Bin dabei'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.text('Bin dabei')),
      isSemantics(
        label: 'Bin dabei',
        isButton: true,
        isInMutuallyExclusiveGroup: true,
        isSelected: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('Kann nicht')),
      isSemantics(
        isButton: true,
        isInMutuallyExclusiveGroup: true,
        isSelected: false,
      ),
    );
    semantics.dispose();
    await finish(tester, controller);
  });

  testWidgets('admins see that they are not invited instead of the RSVP', (
    tester,
  ) async {
    final server = TestServer()
      ..data['events'] = [
        _event(
          'technik',
          extra: {
            'roleIds': ['role-3'],
            'addressedToMe': false,
          },
        ),
      ];
    final controller = await open(tester, server, 'technik');
    expect(find.text('Du bist nicht eingeladen'), findsOneWidget);
    expect(find.text('Nicht eingeladen'), findsOneWidget);
    expect(find.byType(RsvpPanel), findsNothing);
    await finish(tester, controller);
  });
}
