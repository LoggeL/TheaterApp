import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/reader.dart';
import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  test('reimported archives stay below newer seasons', () {
    final productions = [
      Production(
        id: 'sommerstueck2025',
        title: 'Sommerstück 2025',
        createdAt: DateTime.utc(2027),
      ),
      const Production(id: 'winterstueck2026', title: 'Winterstück 2026'),
      const Production(id: 'sommerstueck2027', title: 'Sommerstück 2027'),
      const Production(id: 'sommerstueck2026', title: 'Sommerstück 2026'),
    ]..sort(Production.compareNewestFirst);
    expect(productions.map((p) => p.id), [
      'sommerstueck2027',
      'winterstueck2026',
      'sommerstueck2026',
      'sommerstueck2025',
    ]);
  });

  test(
    'premiere and creation metadata survive offline cache and script enrichment',
    () {
      final production = Production(
        id: 'winter',
        title: 'Romeo und Julia',
        premiereAt: DateTime.utc(2026, 12, 27, 16),
        createdAt: DateTime.utc(2026, 10, 5),
      );
      final restored = Production.fromJson(production.toJson()).withScript(
        const ScriptDocument(
          productionId: 'winter',
          revision: 'r1',
          roles: [],
          scenes: [],
          cues: [],
        ),
      );
      expect(restored.premiereAt, production.premiereAt);
      expect(restored.createdAt, production.createdAt);
      expect(restored.sortDate, production.premiereAt);
    },
  );

  testWidgets(
    'library highlights only the newest production in an unsorted snapshot',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = TestServer();
      server.data['productions'] = [
        {'id': 'sommerstueck2025', 'title': 'Sommerstück 2025'},
        {'id': 'winterstueck2026', 'title': 'Winterstück 2026'},
        {'id': 'sommerstueck2026', 'title': 'Sommerstück 2026'},
      ];
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      expect(controller.productions.map((p) => p.id), [
        'winterstueck2026',
        'sommerstueck2026',
        'sommerstueck2025',
      ]);
      expect(controller.productionRecords.first['id'], 'winterstueck2026');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProductionsScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Neuestes Stück'), findsOneWidget);
      final newestCard = find.byKey(
        const ValueKey('production.winterstueck2026'),
      );
      expect(
        find.descendant(of: newestCard, matching: find.text('Neuestes Stück')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
