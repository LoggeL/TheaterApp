import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/scripts/scripts.dart';

ScriptCue _cue(
  String id,
  String scene,
  int ordinal,
  String kind,
  String text, [
  List<String> roles = const [],
]) => ScriptCue.fromJson({
  'id': id,
  'sceneId': scene,
  'ordinal': ordinal,
  'category': kind,
  'role': roles.join(' & '),
  'roles': roles,
  'text': text,
});

final script = ScriptDocument(
  productionId: 'romeo',
  revision: 'r1',
  roles: const [
    ScriptRole(id: 'ROMEO', name: 'Romeo', personId: 7),
    ScriptRole(id: 'JULIA', name: 'Julia'),
    ScriptRole(id: 'AMME', name: 'Amme'),
    ScriptRole(id: 'ALLE', name: 'Alle'),
  ],
  scenes: const [
    ScriptScene(id: '1', title: 'Balkon', ordinal: 0),
    ScriptScene(id: '2', title: 'Gruft', ordinal: 1),
  ],
  cues: [
    _cue('s1', '1', 0, 'scene', 'Balkon'),
    _cue('d1', '1', 1, 'direction', 'Nacht. Romeo unter dem Balkon.'),
    _cue('r1', '1', 2, 'dialogue', 'Doch still, was schimmert dort?', [
      'ROMEO',
    ]),
    _cue('j1', '1', 3, 'dialogue', 'Ach, Romeo!', ['JULIA']),
    _cue('l1', '1', 4, 'lighting', 'Mondlicht.'),
    _cue('d2', '1', 5, 'direction', 'Er tritt näher.'),
    _cue('r2', '1', 6, 'dialogue', 'Sie spricht!', ['ROMEO']),
    _cue('r3', '1', 7, 'dialogue', 'O sprich noch einmal.', ['ROMEO']),
    _cue('b1', '1', 8, 'dialogue', 'Gute Nacht!', ['ROMEO', 'JULIA']),
    _cue('s2', '2', 9, 'scene', 'Gruft'),
    _cue('a1', '2', 10, 'dialogue', 'Es ist vorbei.', ['AMME']),
    _cue('all', '2', 11, 'dialogue', 'Weh uns!', ['ALLE']),
  ],
);

void main() {
  group('cue cards', () {
    test('show the line before, directions between and no technique', () {
      final cards = learnCards(script, {'ROMEO'});
      expect(cards.map((c) => c.line.id), ['r1', 'r2', 'r3', 'b1', 'all']);
      // Scene start: no prompt, the opening direction as context.
      expect(cards[0].prompt, isNull);
      expect(cards[0].directions.map((c) => c.id), ['d1']);
      // The light cue is skipped, the direction stays.
      expect(cards[1].prompt?.id, 'j1');
      expect(cards[1].directions.map((c) => c.id), ['d2']);
      expect(cards[1].promptIsOwn, isFalse);
      // Two own lines in a row: the first is the cue for the second.
      expect(cards[2].prompt?.id, 'r2');
      expect(cards[2].promptIsOwn, isTrue);
    });

    test('a shared line counts for each speaker, case-insensitively', () {
      expect(learnCards(script, {'julia'}).map((c) => c.line.id), [
        'j1',
        'b1',
        'all',
      ]);
    });

    test('group lines are optional and scenes filter the cards', () {
      final cards = learnCards(script, {'AMME'});
      expect(cards.map((c) => c.line.id), ['a1', 'all']);
      expect(cards.last.group, isTrue);
      expect(cards.last.prompt?.id, 'a1');
      expect(
        learnCards(script, {
          'AMME',
        }, includeGroups: false).map((c) => c.line.id),
        ['a1'],
      );
      expect(
        learnCards(script, {'ROMEO'}, sceneIds: {'2'}).map((c) => c.line.id),
        ['all'],
      );
      expect(learnCards(script, {}), isEmpty);
      expect(hasGroupLines(script), isTrue);
      expect(isGroupSpeaker('alle  anderen'), isTrue);
      expect(isGroupSpeaker('ENSEMBLE 3'), isFalse);
    });
  });

  test('the first-letter hint keeps punctuation and umlauts', () {
    expect(initialsHint('Das würde mich glücklich machen.'), 'D w m g m.');
    expect(
      initialsHint('Ein Knopf.  Zwei Bonbons – und gibt’s Ärger?'),
      'E K. Z B – u g Ä?',
    );
  });

  group('progress', () {
    final line = script.cues.firstWhere((c) => c.id == 'r1');

    test('known lines climb, missed lines fall back, edits start over', () {
      var progress = const LearnProgress();
      expect(progress.of(line).isNew, isTrue);
      for (var i = 0; i < 4; i++) {
        progress = progress.rate(line, known: true);
      }
      expect(progress.of(line).box, LearnProgress.masteredBox);
      expect(progress.of(line).mastered, isTrue);
      progress = progress.rate(line, known: false);
      expect(progress.of(line).box, 0);
      expect(progress.of(line).seen, 5);
      expect(progress.of(line).known, 4);
      // Survives a round trip through the stored preferences.
      final restored = LearnProgress.fromJson(progress.toJson());
      expect(restored.of(line).seen, 5);
      // A changed text in a new script version counts as new.
      final edited = _cue('r1', '1', 2, 'dialogue', 'Doch still!', ['ROMEO']);
      expect(restored.of(edited).isNew, isTrue);
    });

    test('weak lines come first and known ones can be skipped', () {
      final cards = learnCards(script, {'ROMEO'});
      final progress = const LearnProgress()
          .rate(cards[0].line, known: true)
          .rate(cards[0].line, known: true)
          .rate(cards[0].line, known: true)
          .rate(cards[1].line, known: true)
          .rate(cards[2].line, known: false);
      expect(learnQueue(cards, progress).map((c) => c.line.id), [
        'r1',
        'r2',
        'r3',
        'b1',
        'all',
      ]);
      expect(
        learnQueue(
          cards,
          progress,
          order: LearnOrder.weakFirst,
        ).map((c) => c.line.id),
        ['r3', 'b1', 'all', 'r2', 'r1'],
      );
      expect(
        learnQueue(cards, progress, skipMastered: true).map((c) => c.line.id),
        ['r2', 'r3', 'b1', 'all'],
      );
      expect(progress.summary(cards), (fresh: 2, weak: 2, mastered: 1));
    });

    test('a missed card comes back a few cards later', () {
      final cards = learnCards(script, {'ROMEO'});
      final session = LearnSession(cards);
      session.answer(known: false);
      expect(session.length, cards.length + 1);
      final order = <String>[];
      while (!session.finished) {
        order.add(session.current!.line.id);
        session.answer(known: true);
      }
      expect(order, ['r2', 'r3', 'b1', 'r1', 'all']);
      expect(session.missed.single.line.id, 'r1');
      expect((session.known, session.again), (5, 1));
    });
  });

  test('default roles come from the cast list, then from the reader', () {
    expect(
      LearnPreferences.read(
        {},
        'romeo',
        roles: script.roles,
        personId: 7,
      ).roles,
      {'ROMEO'},
    );
    expect(
      LearnPreferences.read(
        {
          'reader.romeo.roles': ['JULIA'],
        },
        'romeo',
        roles: script.roles,
      ).roles,
      {'JULIA'},
    );
    expect(
      LearnPreferences.read(
        {
          'learn.romeo.roles': ['AMME'],
        },
        'romeo',
        roles: script.roles,
        personId: 7,
      ).roles,
      {'AMME'},
    );
  });

  group('screen', () {
    const productionId = DemoData.mainProductionId;

    Future<AppController> demo(WidgetTester tester) async {
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
      return controller;
    }

    Future<void> open(WidgetTester tester, AppController controller) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LineLearningScreen(
            controller: controller,
            productionId: productionId,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> close(WidgetTester tester, AppController controller) async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }

    testWidgets('asks for a role when none is known', (tester) async {
      final controller = await demo(tester);
      await open(tester, controller);
      expect(find.text('Keine Rolle gewählt'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('learn-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('learn-role-LENA')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      expect(controller.preferences['learn.$productionId.roles'], ['LENA']);
      expect(find.textContaining('Lernen ·'), findsOneWidget);
      await close(tester, controller);
    });

    testWidgets('hides the line, gives hints and saves the rating', (
      tester,
    ) async {
      final controller = await demo(tester);
      await controller.setPreference('reader.$productionId.roles', ['LENA']);
      await open(tester, controller);
      expect(find.text('Lena'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('learn-start')));
      await tester.pumpAndSettle();

      // The first Lena line opens the scene: no prompt, own text hidden.
      expect(find.text('SZENENBEGINN'), findsOneWidget);
      expect(find.text('Sag bitte, dass du den Schlüssel hast.'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('learn-own-line')));
      await tester.pumpAndSettle();
      expect(find.text('S b, d d d S h.'), findsOneWidget);
      expect(find.byKey(const ValueKey('learn-known')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('learn-reveal')));
      await tester.pumpAndSettle();
      expect(
        find.text('Sag bitte, dass du den Schlüssel hast.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('learn-known')));
      await tester.pumpAndSettle();

      // The next card shows Oskar's line as the cue.
      expect(find.text('STICHWORT · Oskar'), findsOneWidget);
      expect(
        find.text('Ich habe Kaffee. Das ist fast dasselbe.'),
        findsOneWidget,
      );
      expect(
        find.text('Nur wenn Kaffee neuerdings Schlösser öffnet.'),
        findsNothing,
      );
      final progress = LearnProgress.fromJson(
        controller.preferences['learn.$productionId.progress'],
      );
      expect(progress.lines.values.single.box, 1);

      // Closing the drill returns to the overview with the new count.
      await tester.tap(find.byTooltip('Durchgang beenden'));
      await tester.pumpAndSettle();
      expect(find.text('sitzen'), findsOneWidget);
      await close(tester, controller);
    });

    testWidgets('scenes can be left out for a rehearsal', (tester) async {
      final controller = await demo(tester);
      await controller.setPreference('learn.$productionId.roles', ['LENA']);
      await open(tester, controller);
      await tester.tap(find.text('Keine'));
      await tester.pumpAndSettle();
      expect(find.text('Keine Repliken in dieser Auswahl'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('learn-scene-2')));
      await tester.pumpAndSettle();
      expect(controller.preferences['learn.$productionId.scenes'], ['2']);
      await tester.tap(find.byKey(const ValueKey('learn-start')));
      await tester.pumpAndSettle();
      expect(find.text('Hinter dem Vorhang'), findsOneWidget);
      expect(find.text('STICHWORT · Mira'), findsOneWidget);
      await close(tester, controller);
    });

    testWidgets('the production card and the reader menu open it', (
      tester,
    ) async {
      final controller = await demo(tester);
      await controller.setPreference('reader.$productionId.roles', ['LENA']);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProductionsScreen(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(
        const ValueKey('production-learn.$productionId'),
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(LineLearningScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptReaderScreen(
            controller: controller,
            productionId: productionId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Weitere Aktionen'));
      await tester.pumpAndSettle();
      expect(find.byType(LineLearningScreen), findsNothing);
      await tester.tap(find.text('Text lernen'));
      await tester.pumpAndSettle();
      expect(find.byType(LineLearningScreen), findsOneWidget);
      await close(tester, controller);
    });
  });
}
