import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/reader.dart';

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
}
