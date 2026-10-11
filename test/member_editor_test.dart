import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('member editor saves two independently selectable roles', (
    tester,
  ) async {
    final server = TestServer();
    server.data['personRoles'] = [
      {'id': 'r1', 'name': 'Technik'},
      {'id': 'r2', 'name': 'Requisite'},
    ];
    final c = server.controller();
    await signIn(c);
    await tester.pumpWidget(
      MaterialApp(home: MemberEditorScreen(controller: c)),
    );
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Sam');
    await tester.tap(find.text('Technik'));
    await tester.tap(find.text('Requisite'));
    await tester.ensureVisible(find.text('Speichern'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['roleIds'], ['r1', 'r2']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
