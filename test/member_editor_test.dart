import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';
import 'package:theater_app/shared/navigation.dart';

import 'app_controller_test.dart' show TestServer, signIn;

/// Opens [screen] from a plain page so popping it is observable.
Future<void> _open(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => openPage(context, screen),
            child: const Text('Öffnen'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Öffnen'));
  await tester.pumpAndSettle();
}

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern'));

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
    // Speichern stays disabled until a name is entered.
    await tester.pump();
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

  testWidgets('a name is required and unsaved input asks before leaving', (
    tester,
  ) async {
    final server = TestServer(), c = server.controller();
    addTearDown(c.dispose);
    await signIn(c);
    await _open(tester, MemberEditorScreen(controller: c));
    expect(_saveButton(tester).onPressed, isNull);
    expect(find.text('Bitte einen Namen eingeben.'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Mia');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNotNull);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), '  ');
    await tester.pump();
    expect(find.text('Bitte einen Namen eingeben.'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Mia');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Weiter bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberEditorScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verwerfen'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberEditorScreen), findsNothing);
    expect(server.actionBodies, isEmpty);
  });

  testWidgets('without the account list only deactivating is offered', (
    tester,
  ) async {
    final server = TestServer();
    server.override = (request) => request.url.path.contains('/admin/accounts')
        ? Future<http.Response>.error(http.ClientException('offline'))
        : null;
    final c = server.controller();
    addTearDown(c.dispose);
    await signIn(c);
    final member = {
      ...jsonMap(jsonList(server.data['members']).first),
      'active': true,
      'version': 3,
    };
    await _open(tester, MemberEditorScreen(controller: c, member: member));
    final open = find.widgetWithText(OutlinedButton, 'Person löschen');
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.textContaining('nicht geladen werden'), findsOneWidget);
    expect(find.text('Endgültig löschen'), findsNothing);
    await tester.tap(find.text('Nur deaktivieren'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'member.save');
    expect(server.actionBodies.last['active'], false);
    expect(find.byType(MemberEditorScreen), findsNothing);
    expect(find.text('Person gespeichert.'), findsOneWidget);
  });
}
