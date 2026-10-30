import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/scripts/scripts.dart';

import 'app_controller_test.dart' show TestServer, signIn;

const script = ScriptDocument(
  productionId: 'test',
  revision: 'revision-1',
  roles: [ScriptRole(id: 'LENA', name: 'Lena')],
  scenes: [
    ScriptScene(id: '1', title: 'Anfang', ordinal: 0),
    ScriptScene(id: '2', title: 'Ende', ordinal: 1),
  ],
  cues: [
    ScriptCue(
      id: 'scene',
      sceneId: '1',
      ordinal: 0,
      kind: 'scene',
      text: 'Anfang',
    ),
    ScriptCue(
      id: 'direction',
      sceneId: '1',
      ordinal: 1,
      kind: 'direction',
      text: 'Vorhang auf.',
    ),
    ScriptCue(
      id: 'other',
      sceneId: '1',
      ordinal: 2,
      kind: 'dialogue',
      role: 'OSKAR',
      text: 'Hallo?',
    ),
    ScriptCue(
      id: 'own',
      sceneId: '1',
      ordinal: 3,
      kind: 'dialogue',
      role: 'LENA',
      text: 'Hallo!',
    ),
    ScriptCue(
      id: 'next-scene',
      sceneId: '2',
      ordinal: 4,
      kind: 'dialogue',
      role: 'OSKAR',
      text: 'Einen Tag später.',
    ),
    ScriptCue(
      id: 'light',
      sceneId: '2',
      ordinal: 5,
      kind: 'lighting',
      text: 'Licht 40 %.',
    ),
    ScriptCue(
      id: 'mic',
      sceneId: '2',
      ordinal: 6,
      kind: 'microphone',
      text: 'Mikro an.',
      isAutoMic: true,
      micCueType: 'EIN',
    ),
    ScriptCue(
      id: 'end',
      sceneId: '2',
      ordinal: 7,
      kind: 'direction',
      text: 'Abgang.',
    ),
  ],
);

void main() {
  test(
    'actor context includes the preceding cue but never crosses a scene boundary',
    () {
      final result = visibleScriptCues(
        script,
        mode: 'actor',
        role: 'lena',
        contextLines: 1,
      );
      expect(result.map((cue) => cue.id), ['other', 'own']);
      expect(
        script.cues,
        hasLength(8),
        reason: 'Display filtering must not mutate the canonical document.',
      );
    },
  );

  test(
    'zero context displays only own cues and role matching is case-insensitive',
    () {
      expect(
        visibleScriptCues(
          script,
          mode: 'actor',
          role: 'Lena',
          contextLines: 0,
        ).map((cue) => cue.id),
        ['own'],
      );
    },
  );

  test(
    'technical mode preserves generated microphone cues and chronological order',
    () {
      final result = visibleScriptCues(script, mode: 'technical');
      expect(result.map((cue) => cue.id), ['direction', 'light', 'mic', 'end']);
      expect(result[2].isAutoMic, isTrue);
      expect(result[2].micCueType, 'EIN');
    },
  );

  test(
    'category preferences hide technical and stage direction rows independently',
    () {
      expect(
        visibleScriptCues(
          script,
          showDirections: false,
          showTechnical: false,
        ).map((cue) => cue.id),
        ['other', 'own', 'next-scene'],
      );
      expect(
        visibleScriptCues(
          script,
          mode: 'stage',
          showDirections: false,
        ).map((cue) => cue.id),
        ['other', 'own', 'next-scene', 'light', 'mic'],
      );
    },
  );

  test(
    'missing own role gives an empty actor view instead of unrelated dialogue',
    () {
      expect(visibleScriptCues(script, mode: 'actor', role: 'MIRA'), isEmpty);
    },
  );

  testWidgets(
    'native library opens a script, saves own role and bookmarks a cue',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
      );
      await controller.init();
      await controller.startDemo();
      await controller.setPreference('reader.demo-midnight.contextLines', 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProductionsScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wenn das Licht angeht'));
      await tester.pumpAndSettle();
      expect(find.text('Szenen'), findsOneWidget);
      await tester.tap(find.text('Meine Rollen').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lena'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lesemodus'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Meine Texte'),
      );
      await tester.pumpAndSettle();
      expect(controller.preferences['reader.demo-midnight.role'], 'LENA');
      expect(controller.preferences['reader.demo-midnight.mode'], 'actor');
      expect(find.text('DEIN TEXT'), findsNothing);
      expect(
        find.text('Ich habe Kaffee. Das ist fast dasselbe.'),
        findsNothing,
      );
      await tester.longPress(
        find.text('Sag bitte, dass du den Schlüssel hast.').first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lesezeichen setzen'));
      await tester.pumpAndSettle();
      expect(
        controller.preferences['reader.demo-midnight.bookmarks'],
        isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'a rehearsal deep link opens the requested scene and scene navigation works',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
      );
      await controller.init();
      await controller.startDemo();
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptReaderScreen(
            controller: controller,
            productionId: 'demo-midnight',
            initialSceneId: '4',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Das ist unser Zeichen'), findsWidgets);
      await tester.tap(find.text('Szenen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hinter dem Vorhang').last);
      await tester.pumpAndSettle();
      expect(find.text('Hinter dem Vorhang'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  group('reading without rebuilding the app', () {
    const id = DemoData.mainProductionId;
    late TestServer server;
    late MemoryLocalStore store;
    late MemoryCredentialStore credentials;
    var scriptRequests = 0;

    setUp(() {
      server = TestServer();
      store = MemoryLocalStore();
      credentials = MemoryCredentialStore();
      scriptRequests = 0;
      server.override = (request) {
        if (request.url.path.contains('/script')) scriptRequests++;
        return null;
      };
    });

    Future<AppController> signedIn(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = server.controller(
        store: store,
        credentials: credentials,
      );
      await signIn(controller);
      return controller;
    }

    Future<void> open(WidgetTester tester, AppController controller) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptReaderScreen(controller: controller, productionId: id),
        ),
      );
      await tester.pumpAndSettle();
    }

    String sceneLabel(WidgetTester tester) => tester
        .widgetList<Text>(
          find.descendant(of: find.byType(AppBar), matching: find.byType(Text)),
        )
        .map((text) => text.data)
        .skip(1)
        .first!;

    testWidgets('scrolling across scenes notifies nobody and keeps the place', (
      tester,
    ) async {
      final controller = await signedIn(tester);
      await controller.loadScript(id);
      await open(tester, controller);
      final firstScene = sceneLabel(tester);
      var notifications = 0;
      controller.addListener(() => notifications++);

      final list = find.byType(ScrollablePositionedList);
      for (var i = 0; i < 6; i++) {
        await tester.drag(list, const Offset(0, -500));
        await tester.pumpAndSettle();
      }
      expect(sceneLabel(tester), isNot(firstScene));
      await tester.pump(const Duration(seconds: 6));
      expect(notifications, 0);
      final saved = controller.preferences['reader.$id.lastCueId'];
      expect(saved, isNotNull);

      // Closing the reader stores the latest place without waiting.
      await tester.drag(list, const Offset(0, -1500));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      final last = controller.preferences['reader.$id.lastCueId'];
      expect(last, isNot(saved));
      expect(notifications, 0);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      controller.dispose();

      final again = server.controller(store: store, credentials: credentials);
      addTearDown(again.dispose);
      await again.init();
      expect(again.preferences['reader.$id.lastCueId'], last);
    });

    testWidgets('a stored script is fetched again only after it changed', (
      tester,
    ) async {
      final controller = await signedIn(tester);
      addTearDown(controller.dispose);
      await controller.loadScript(id);
      expect(scriptRequests, 1);
      final document = controller.scripts[id];

      await open(tester, controller);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(tester, controller);
      expect(scriptRequests, 1);

      // A new cast bumps the production's version: one quiet check. The
      // same script comes back, so nothing is rebuilt or announced.
      final production = (server.data['productions'] as List).first as Map;
      expect(production['id'], id);
      production['version'] = 2;
      await controller.refresh();
      var notifications = 0;
      controller.addListener(() => notifications++);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(tester, controller);
      expect(scriptRequests, 2);
      expect(notifications, 0);
      expect(controller.scripts[id], same(document));
      await tester.pumpWidget(const SizedBox.shrink());
      await open(tester, controller);
      expect(scriptRequests, 2);

      // Asked for, the newest version is always fetched.
      await controller.loadScript(id);
      expect(scriptRequests, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
