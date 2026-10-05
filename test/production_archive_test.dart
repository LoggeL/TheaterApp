import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/ui/reader.dart';
import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  test(
    'archive status and mutation version survive caching and script enrichment',
    () {
      const production = Production(
        id: 'old',
        title: 'Altes Stück',
        archived: true,
        version: 6,
      );
      final restored = Production.fromJson(production.toJson()).withScript(
        const ScriptDocument(
          productionId: 'old',
          revision: 'r1',
          roles: [],
          scenes: [],
          cues: [],
        ),
      );
      expect(restored.archived, true);
      expect(restored.version, 6);
      expect(
        Production.fromJson({
          'id': 'legacy',
          'title': 'Älteres Drehbuch',
        }).archived,
        false,
      );
    },
  );

  test(
    'offline archive and restore keep scripts and preferences across restart and use consecutive versions',
    () async {
      final server = TestServer(),
          store = MemoryLocalStore(),
          credentials = MemoryCredentialStore();
      final first = server.controller(store: store, credentials: credentials);
      await signIn(first);
      await first.loadScript(DemoData.mainProductionId);
      final document = first.scripts[DemoData.mainProductionId]!;
      await first.setPreference(
        'reader.${DemoData.mainProductionId}.role',
        'LENA',
      );
      await first.setPreference(
        'reader.${DemoData.mainProductionId}.bookmarks',
        [document.cues.first.id],
      );
      server.offline = true;
      await first.setProductionArchived(DemoData.mainProductionId, true);
      expect(
        first.archivedProductions.map((p) => p.id),
        contains(DemoData.mainProductionId),
      );
      expect(
        first.productionRecords.firstWhere(
          (p) => p['id'] == DemoData.mainProductionId,
        )['archived'],
        true,
      );
      first.dispose();
      final second = server.controller(store: store, credentials: credentials);
      addTearDown(second.dispose);
      await second.init();
      expect(
        second.archivedProductions.map((p) => p.id),
        contains(DemoData.mainProductionId),
      );
      expect(
        second.scripts[DemoData.mainProductionId]!.toJson(),
        document.toJson(),
      );
      expect(
        second.preferences['reader.${DemoData.mainProductionId}.role'],
        'LENA',
      );
      expect(
        second.preferences['reader.${DemoData.mainProductionId}.bookmarks'],
        [document.cues.first.id],
      );
      await second.setProductionArchived(DemoData.mainProductionId, false);
      expect(
        second.activeProductions.map((p) => p.id),
        contains(DemoData.mainProductionId),
      );
      final archives = second.outbox
          .where((a) => a.payload['action'] == 'production.archive')
          .toList();
      expect(archives.length, 2);
      expect(
        archives.last.payload['version'],
        (archives.first.payload['version'] as int) + 1,
      );
    },
  );

  testWidgets(
    'current library hides archived scripts; archive keeps newest first and opens the reader',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = TestServer();
      server.data['productions'] = [
        {'id': 'sommer2025', 'title': 'Sommerstück 2025', 'archived': true},
        {
          'id': 'winter2026',
          'title': 'Romeo und Julia',
          'premiereAt': '2026-12-27T16:00:00Z',
        },
        {
          'id': DemoData.mainProductionId,
          'title': 'Sommerstück 2026',
          'archived': true,
        },
      ];
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      await controller.loadScript(DemoData.mainProductionId);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProductionsScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Romeo und Julia'), findsOneWidget);
      expect(find.text('Neuestes Stück'), findsOneWidget);
      expect(find.text('Sommerstück 2026'), findsNothing);
      expect(find.text('Sommerstück 2025'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('production-archive-link')));
      await tester.pumpAndSettle();
      expect(find.text('Neuestes Stück'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Sommerstück 2026')).dy,
        lessThan(tester.getTopLeft(find.text('Sommerstück 2025')).dy),
      );
      await tester.tap(find.text('Sommerstück 2026'));
      await tester.pumpAndSettle();
      expect(find.byType(ScriptReaderScreen), findsOneWidget);
      expect(controller.scripts[DemoData.mainProductionId], isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an entirely archived library still offers the archive', (
    tester,
  ) async {
    final server = TestServer();
    server.data['productions'] = [
      {'id': 'old', 'title': 'Sommerstück 2025', 'archived': true},
    ];
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProductionsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Kein aktuelles Stück.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('production-archive-link')),
      findsOneWidget,
    );
    expect(find.text('Neuestes Stück'), findsNothing);
  });
}
