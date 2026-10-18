import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/productions/productions.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

const _tile = ValueKey('production-editor-scope-events');

/// A server that answers `production.scopeEvents` with [updated] events and
/// an ensemble of [ensembleSize] people.
TestServer _server({
  int updated = 3,
  int ensembleSize = 2,
  bool supported = true,
  bool archived = false,
}) {
  final server = TestServer();
  server.data['capabilities'] = {
    ...jsonMap(server.data['capabilities']),
    'features': [if (supported) 'productionScopeEvents'],
  };
  if (archived) {
    server.data['productions'] = [
      for (final p in (server.data['productions'] as List).map(jsonMap))
        p['id'] == DemoData.mainProductionId ? {...p, 'archived': true} : p,
    ];
  }
  server.override = (request) {
    if (!request.url.path.contains('/actions')) return null;
    final body = jsonMap(jsonDecode(request.body));
    server.actionBodies.add(body);
    return Future.value(
      jsonResponse({
        'ok': true,
        'updated': updated,
        'eventIds': [for (var i = 0; i < updated; i++) 'event-$i'],
        'ensembleSize': ensembleSize,
        if (body['dryRun'] == true) 'dryRun': true,
      }),
    );
  };
  return server;
}

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
      home: ProductionEditorScreen(
        controller: controller,
        production: controller.productionRecords.firstWhere(
          (p) => p['id'] == DemoData.mainProductionId,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _start(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_tile));
  await tester.tap(find.byKey(_tile));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('the action needs server support and an active production', (
    tester,
  ) async {
    await _pump(tester, _server(supported: false));
    expect(find.byKey(_tile), findsNothing);
    await _pump(tester, _server(archived: true));
    expect(find.byKey(_tile), findsNothing);
    await _pump(tester, _server());
    expect(find.text('Termine nur fürs Ensemble'), findsOneWidget);
  });

  testWidgets('it counts first, asks and then limits the events silently', (
    tester,
  ) async {
    final server = _server();
    await _pump(tester, server);
    await _start(tester);
    expect(server.actionBodies.single, {
      'action': 'production.scopeEvents',
      'productionId': DemoData.mainProductionId,
      'dryRun': true,
    });
    expect(find.text('Termine nur fürs Ensemble?'), findsOneWidget);
    expect(
      find.text(
        '3 Termine ohne Zielgruppe gelten künftig nur für das Ensemble von '
        '„Wenn das Licht angeht“ (aktuell 2 Personen). Wer nicht dazugehört, '
        'sieht diese Termine nicht mehr. Es werden keine Benachrichtigungen '
        'verschickt.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Achtung'), findsNothing);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies, hasLength(1));

    await _start(tester);
    await tester.tap(find.text('Nur fürs Ensemble'));
    await tester.pumpAndSettle();
    expect(server.actionBodies, hasLength(3));
    expect(server.actionBodies.last, {
      'action': 'production.scopeEvents',
      'productionId': DemoData.mainProductionId,
    });
    expect(find.text('3 Termine angepasst.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty ensemble gets a clear warning', (tester) async {
    await _pump(tester, _server(updated: 1, ensembleSize: 0));
    await _start(tester);
    expect(
      find.textContaining(
        '1 Termin ohne Zielgruppe gilt künftig nur für das Ensemble von '
        '„Wenn das Licht angeht“ (aktuell 0 Personen).',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Achtung: Das Ensemble ist noch leer. Bis die Besetzung eingetragen '
        'ist, sieht niemand ohne Admin-Rechte diese Termine.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('nothing to change only says so', (tester) async {
    final server = _server(updated: 0);
    await _pump(tester, server);
    await _start(tester);
    expect(find.text('Termine nur fürs Ensemble?'), findsNothing);
    expect(
      find.text('Alle Termine dieses Stücks haben bereits eine Zielgruppe.'),
      findsOneWidget,
    );
    expect(server.actionBodies.single['dryRun'], isTrue);
  });

  testWidgets('the event editor points out a play event for everyone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer(), controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: EventEditorScreen(
          controller: controller,
          event: controller.events.firstWhere((e) => e.id == 'demo-costume'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const hint = ValueKey('event-audience-everyone-hint');
    await tester.scrollUntilVisible(
      find.byKey(hint),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text(
        'Dieser Termin gilt für alle Mitglieder. Nur fürs Ensemble? Dann '
        'Ensemble des Stücks wählen.',
      ),
      findsOneWidget,
    );
    final chip = find.ancestor(
      of: find.textContaining('Wenn das Licht angeht'),
      matching: find.byType(FilterChip),
    );
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.byKey(hint), findsNothing);
    expect(server.actionBodies, isEmpty);
  });
}
