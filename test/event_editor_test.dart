import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/events/events.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  /// Opens the editor as a route above a start page, so it can be left.
  Future<(TestServer, AppController)> open(
    WidgetTester tester, {
    TheaterEvent? Function(AppController)? event,
    void Function(TestServer)? prepare,
  }) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    prepare?.call(server);
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
                    builder: (_) => EventEditorScreen(
                      controller: controller,
                      event: event?.call(controller),
                    ),
                  ),
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
    return (server, controller);
  }

  FilledButton saveButton(WidgetTester tester) => tester.widget(
    find.ancestor(
      of: find.text('Termin speichern'),
      matching: find.byType(FilledButton),
    ),
  );

  testWidgets('event editor saves description and additional event type', (
    tester,
  ) async {
    final server = TestServer(), c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: EventEditorScreen(controller: c),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Titel'),
      'Werkstatt',
    );
    // The type follows the title; the description comes after the invitees.
    final kind = find.byKey(const ValueKey('event-kind'));
    await tester.scrollUntilVisible(
      kind,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(kind);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Aufbau').last);
    await tester.tap(find.text('Aufbau').last);
    await tester.pumpAndSettle();
    final description = find.widgetWithText(TextField, 'Beschreibung');
    await tester.scrollUntilVisible(
      description,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(description, 'Schraubendreher mitbringen');
    await tester.scrollUntilVisible(
      find.text('Termin speichern'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Termin speichern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['type'], 'setup');
    expect(
      server.actionBodies.last['description'],
      'Schraubendreher mitbringen',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a title is required before saving', (tester) async {
    final (_, controller) = await open(tester);
    expect(saveButton(tester).onPressed, isNull);
    expect(find.text('Noch fehlt: Titel'), findsOneWidget);
    // No error before the field was touched.
    expect(find.text('Bitte einen Titel eingeben.'), findsNothing);
    final title = find.widgetWithText(TextField, 'Titel');
    await tester.enterText(title, 'Leseprobe');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNotNull);
    expect(find.text('Noch fehlt: Titel'), findsNothing);
    await tester.enterText(title, '  ');
    await tester.pump();
    expect(find.text('Bitte einen Titel eingeben.'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('unsaved input asks before it is thrown away', (tester) async {
    final (_, controller) = await open(tester);
    // An untouched form closes right away.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EventEditorScreen), findsNothing);
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Fotos');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Weiter bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.byType(EventEditorScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verwerfen'));
    await tester.pumpAndSettle();
    expect(find.byType(EventEditorScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('saving confirms with a message and closes the editor', (
    tester,
  ) async {
    final (server, controller) = await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Fotos');
    final save = find.text('Termin speichern');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['title'], 'Fotos');
    expect(find.byType(EventEditorScreen), findsNothing);
    expect(find.text('Termin gespeichert'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('offline saves say they are queued', (tester) async {
    final (server, controller) = await open(tester);
    server.offline = true;
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Fotos');
    final save = find.text('Termin speichern');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      find.text('Termin vorgemerkt – wird bei Verbindung übertragen.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a series occurrence says changes stay with it', (tester) async {
    late String id;
    final (_, controller) = await open(
      tester,
      event: (c) => c.events.firstWhere((e) => e.id == id),
      prepare: (server) {
        final event = (server.data['events'] as List)
            .cast<JsonMap>()
            .firstWhere((e) => e['slotPoolId'] == null);
        event['seriesId'] = 'series-1';
        id = event['id'] as String;
      },
    );
    expect(
      find.text('Teil einer Serie – Änderungen gelten nur für diesen Termin.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final flagged in [true, false]) {
    testWidgets(
      'saving a series occurrence ${flagged ? 'asks' : 'does not ask'} '
      'about the following ones',
      (tester) async {
        late String id;
        final (server, controller) = await open(
          tester,
          event: (c) => c.events.firstWhere((e) => e.id == id),
          prepare: (server) {
            final event = (server.data['events'] as List)
                .cast<JsonMap>()
                .firstWhere((e) => e['slotPoolId'] == null);
            event['seriesId'] = 'series-1';
            id = event['id'] as String;
            if (flagged) {
              server.data['capabilities'] = {
                'features': ['seriesEdit'],
              };
            }
          },
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Titel'),
          'Neuer Titel',
        );
        final save = find.text('Termin speichern');
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        if (flagged) {
          expect(find.text('Serientermin ändern?'), findsOneWidget);
          await tester.tap(find.text('Diesen und alle folgenden'));
          await tester.pumpAndSettle();
          expect(server.actionBodies.last['series'], 'following');
        } else {
          expect(find.text('Serientermin ändern?'), findsNothing);
          expect(server.actionBodies.last.containsKey('series'), isFalse);
        }
        expect(server.actionBodies.last['title'], 'Neuer Titel');
        expect(find.byType(EventEditorScreen), findsNothing);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}
