import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

Future<void> _pump(
  WidgetTester tester,
  TestServer server,
  Widget Function(AppController) screen,
) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: screen(controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the ensemble management shows each account status', (
    tester,
  ) async {
    final server = TestServer();
    server.override = (request) => request.url.path.contains('/admin/accounts')
        ? Future.value(
            jsonResponse({
              'accounts': [
                {'uid': 'a', 'personId': 1, 'status': 'approved'},
                {'uid': 'k', 'personId': 4, 'status': 'suspended'},
              ],
            }),
          )
        : null;
    await _pump(tester, server, (c) => MembersAdminScreen(controller: c));
    Finder pillOf(String name, String status) => find.descendant(
      of: find.widgetWithText(ListTile, name),
      matching: find.text(status),
    );
    expect(pillOf('Alex Bühnenfreund', 'Freigegeben'), findsOneWidget);
    expect(pillOf('Kim Kulisse', 'Gesperrt'), findsOneWidget);
    expect(pillOf('Sam Vorhang', 'Kein Konto verknüpft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'roles still in use cannot be removed; others need a confirmation',
    (tester) async {
      final server = TestServer();
      server.data['personRoles'] = [
        ...server.data['personRoles'] as List,
        {'id': 'role-free', 'name': 'Maske', 'version': 2},
      ];
      await _pump(tester, server, (c) => RolesAdminScreen(controller: c));
      expect(find.text('Rolle anlegen'), findsOneWidget);
      expect(find.text('3 Personen'), findsOneWidget);
      expect(find.text('0 Personen'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Schauspiel'),
          matching: find.byTooltip('Rolle verwalten'),
        ),
      );
      await tester.pumpAndSettle();
      final blocked = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(
          PopupMenuItem<String>,
          'Entfernen (noch 3 Personen)',
        ),
      );
      expect(blocked.enabled, isFalse);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Maske'),
          matching: find.byTooltip('Rolle verwalten'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entfernen'));
      await tester.pumpAndSettle();
      expect(find.text('Rolle entfernen?'), findsOneWidget);
      expect(server.actionBodies, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Entfernen'));
      await tester.pumpAndSettle();
      expect(server.actionBodies.single, {
        'action': 'personRole.delete',
        'id': 'role-free',
        'version': 2,
      });
      expect(find.text('Rolle entfernt.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the role name dialog only saves a name', (tester) async {
    final server = TestServer();
    await _pump(tester, server, (c) => RolesAdminScreen(controller: c));
    await tester.tap(find.text('Rolle anlegen'));
    await tester.pumpAndSettle();
    FilledButton save() =>
        tester.widget(find.widgetWithText(FilledButton, 'Speichern'));
    expect(save().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '  Licht ');
    await tester.pump();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.single['action'], 'personRole.save');
    expect(server.actionBodies.single['name'], 'Licht');
    expect(find.text('Rolle angelegt.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
