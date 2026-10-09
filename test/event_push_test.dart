import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/admin.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<(TestServer, AppController)> open(
    WidgetTester tester, {
    bool push = true,
    TheaterEvent? Function(AppController)? event,
  }) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    server.data['capabilities'] = {'pushConfigured': push};
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

  SwitchListTile pushSwitch(WidgetTester tester) =>
      tester.widget(find.byKey(const ValueKey('event-push')));

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.dragUntilVisible(
      target,
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
  }

  Future<JsonMap> save(WidgetTester tester, TestServer server) async {
    final save = find.text('Termin speichern');
    await scrollTo(tester, save);
    await tester.tap(save);
    await tester.pump();
    return server.actionBodies.lastWhere((b) => b['action'] == 'event.save');
  }

  testWidgets('a new event notifies its invitees by default', (tester) async {
    final (server, controller) = await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Fotos');
    await scrollTo(tester, find.byKey(const ValueKey('event-push')));
    expect(pushSwitch(tester).value, isTrue);
    expect(pushSwitch(tester).onChanged, isNotNull);
    expect(find.text('Geht an: Alle'), findsOneWidget);
    final body = await save(tester, server);
    expect(body['push'], isTrue);
    expect(
      find.text('Termin gespeichert, Benachrichtigung wird verschickt.'),
      findsWidgets,
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the push can be switched off', (tester) async {
    final (server, controller) = await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Fotos');
    await scrollTo(tester, find.byKey(const ValueKey('event-push')));
    await tester.tap(find.byKey(const ValueKey('event-push')));
    await tester.pump();
    expect(pushSwitch(tester).value, isFalse);
    final body = await save(tester, server);
    expect(body['push'], isFalse);
    expect(
      find.text('Termin gespeichert, Benachrichtigung wird verschickt.'),
      findsNothing,
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('editing an event does not push unless asked', (tester) async {
    final (server, controller) = await open(
      tester,
      event: (c) => c.events.firstWhere((e) => e.slotPoolId == null),
    );
    await scrollTo(tester, find.byKey(const ValueKey('event-push')));
    expect(pushSwitch(tester).value, isFalse);
    final body = await save(tester, server);
    expect(body['push'], isFalse);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the switch is disabled without push setup', (tester) async {
    final (server, controller) = await open(tester, push: false);
    expect(controller.pushConfigured, isFalse);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Fotos');
    await scrollTo(tester, find.byKey(const ValueKey('event-push')));
    expect(pushSwitch(tester).value, isFalse);
    expect(pushSwitch(tester).onChanged, isNull);
    expect(find.text('Push ist noch nicht eingerichtet.'), findsOneWidget);
    final body = await save(tester, server);
    expect(body['push'], isFalse);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
