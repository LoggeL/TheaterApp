import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/events/events.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

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
    await tester.enterText(
      find.widgetWithText(TextField, 'Beschreibung'),
      'Schraubendreher mitbringen',
    );
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
}
