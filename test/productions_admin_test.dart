import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/features/productions/productions.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

Future<void> _pump(WidgetTester tester, TestServer server) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: ProductionsAdminScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

/// The busy indicator keeps animating while the import dialog is open, so
/// pumpAndSettle would never return.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  testWidgets('creating a production needs a title and continues in its '
      'editor', (tester) async {
    final server = TestServer();
    server.override = (request) {
      if (!request.url.path.contains('/actions')) return null;
      final body = jsonMap(jsonDecode(request.body));
      server.actionBodies.add(body);
      (server.data['productions'] as List).add({
        'id': 'neu',
        'title': body['title'],
        'subtitle': body['subtitle'],
        'version': 1,
      });
      return Future.value(jsonResponse({'ok': true, 'id': 'neu'}));
    };
    await _pump(tester, server);
    await tester.tap(
      find.widgetWithText(FloatingActionButton, 'Produktion anlegen'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProductionEditorScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Produktion anlegen'), findsOneWidget);
    FilledButton create() => tester.widget(
      find.descendant(
        of: find.byType(ProductionEditorScreen),
        matching: find.widgetWithText(FilledButton, 'Produktion anlegen'),
      ),
    );
    expect(create().onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Neues');
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), '');
    await tester.pump();
    expect(find.text('Bitte einen Titel eingeben.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Titel'),
      'Sommernacht',
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(ProductionEditorScreen),
        matching: find.widgetWithText(FilledButton, 'Produktion anlegen'),
      ),
    );
    await tester.pumpAndSettle();
    expect(server.actionBodies.single['action'], 'production.save');
    expect(server.actionBodies.single['id'], isNull);
    // Casting and archive are offered right away in the new editor.
    expect(
      find.widgetWithText(AppBar, 'Produktion bearbeiten'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextField, 'Sommernacht'), findsOneWidget);
    expect(find.byKey(const ValueKey('production-editor-casting')), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the editor guards edits and archiving asks, then offers undo', (
    tester,
  ) async {
    final server = TestServer();
    await _pump(tester, server);
    await tester.tap(find.text('Wenn das Licht angeht'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductionEditorScreen), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Neu');
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Weiter bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductionEditorScreen), findsOneWidget);

    await tester.ensureVisible(find.text('Ins Archiv verschieben'));
    await tester.tap(find.text('Ins Archiv verschieben'));
    await tester.pumpAndSettle();
    expect(find.text('Ins Archiv verschieben?'), findsOneWidget);
    expect(
      find.textContaining('Ungespeicherte Änderungen gehen dabei verloren.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies, isEmpty);

    await tester.tap(find.text('Ins Archiv verschieben'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archivieren'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.single['action'], 'production.archive');
    expect(server.actionBodies.single['archived'], isTrue);
    expect(find.byType(ProductionEditorScreen), findsNothing);
    expect(find.text('„Wenn das Licht angeht“ archiviert.'), findsOneWidget);
    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'production.archive');
    expect(server.actionBodies.last['archived'], isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed pull-to-refresh offers a retry', (tester) async {
    final server = TestServer();
    await _pump(tester, server);
    server.override = (request) => request.url.path.contains('/snapshot')
        ? Future.value(jsonResponse({'error': 'kaputt'}, 500))
        : null;
    tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show();
    await tester.pumpAndSettle();
    expect(find.text('Erneut versuchen'), findsOneWidget);
  });

  testWidgets('archived productions are collapsed below the active ones', (
    tester,
  ) async {
    final server = TestServer();
    server.data['productions'] = [
      for (final p in (server.data['productions'] as List).map(jsonMap))
        p['id'] == DemoData.secondProductionId ? {...p, 'archived': true} : p,
    ];
    await _pump(tester, server);
    expect(find.text('Wenn das Licht angeht'), findsOneWidget);
    expect(find.text('Archiv (1)'), findsOneWidget);
    expect(find.text('Fünf Minuten im Foyer'), findsNothing);
    await tester.tap(find.text('Archiv (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Fünf Minuten im Foyer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('importing marks known scripts and asks before replacing one', (
    tester,
  ) async {
    final server = TestServer();
    final imports = <http.Request>[];
    server.override = (request) {
      final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
      if (path.endsWith('/admin/script-source')) {
        return Future.value(
          jsonResponse({
            'productions': [
              {'id': DemoData.mainProductionId, 'title': 'Licht'},
              {'id': 'frisch', 'title': 'Ganz neu'},
            ],
          }),
        );
      }
      if (path.endsWith('/admin/import-script')) {
        imports.add(request);
        return Future.value(jsonResponse({'ok': true}));
      }
      return null;
    };
    await _pump(tester, server);
    await tester.tap(find.text('Drehbuch importieren'));
    await _settle(tester);
    expect(find.text('Bereits importiert'), findsOneWidget);
    await tester.tap(find.text('Licht'));
    await _settle(tester);
    expect(find.text('Drehbuch erneut importieren?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await _settle(tester);
    expect(imports, isEmpty);

    await tester.tap(find.text('Drehbuch importieren'));
    await _settle(tester);
    await tester.tap(find.text('Ganz neu'));
    await _settle(tester);
    await tester.pumpAndSettle();
    expect(jsonDecode(imports.single.body), {'productionId': 'frisch'});
    expect(find.text('Drehbuch importiert.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
