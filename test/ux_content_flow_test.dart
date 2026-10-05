import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/ui/polls.dart';
import 'package:theater_app/ui/reader.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

const _productionId = 'demo-midnight';
const _lightText = 'LX 01 · Warmes Arbeitslicht, Bühne 40 %.';
const _pendingVoteText =
    'Deine Stimme wird synchronisiert, sobald eine Verbindung besteht.';
const _missingCueText =
    'Diese Textstelle ist in dieser Fassung nicht vorhanden.';

Future<AppController> _demoReader(WidgetTester tester) async {
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

Future<void> _openReader(
  WidgetTester tester,
  AppController controller, {
  String? initialCueId,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ScriptReaderScreen(
        controller: controller,
        productionId: _productionId,
        initialCueId: initialCueId,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScriptCue _lightingCue(AppController controller) => controller
    .scripts[_productionId]!
    .cues
    .firstWhere((cue) => cue.text == _lightText);

void _expectRevealedLight(AppController controller) {
  expect(find.text(_lightText), findsOneWidget);
  expect(find.text(_missingCueText), findsNothing);
  expect(
    controller.preferences['reader.$_productionId.categories'],
    unorderedEquals(['direction', 'lighting']),
  );
  expect(controller.preferences['reader.$_productionId.showTechnical'], isTrue);
}

Future<void> _close(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

void main() {
  testWidgets(
    'search reveals a hidden technical result without unrelated categories',
    (tester) async {
      final controller = await _demoReader(tester);
      await _openReader(tester, controller);
      expect(find.text(_lightText), findsNothing);
      await tester.tap(find.byTooltip('Im Drehbuch suchen'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'LX 01');
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
      _expectRevealedLight(controller);
      expect(tester.takeException(), isNull);
      await _close(tester, controller);
    },
  );

  testWidgets('a bookmark reveals its hidden technical category', (
    tester,
  ) async {
    final controller = await _demoReader(tester);
    final cue = _lightingCue(controller);
    await controller.setPreference('reader.$_productionId.bookmarks', [cue.id]);
    await _openReader(tester, controller);
    expect(find.text(_lightText), findsNothing);
    await tester.tap(find.byTooltip('Lesezeichen öffnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_lightText));
    await tester.pumpAndSettle();
    _expectRevealedLight(controller);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('following the shared focus reveals a hidden technical cue', (
    tester,
  ) async {
    final controller = await _demoReader(tester);
    final document = controller.scripts[_productionId]!;
    final cue = _lightingCue(controller);
    await controller.publishFocus(
      _productionId,
      revision: document.revision,
      cueId: cue.id,
    );
    await _openReader(tester, controller);
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemeinsamer Fokus'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Der Regie folgen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zurück zum Stück'));
    await tester.pumpAndSettle();
    _expectRevealedLight(controller);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('deep links reveal the derived automatic microphone category', (
    tester,
  ) async {
    final server = TestServer();
    final document = ScriptDocument(
      productionId: _productionId,
      revision: 'microphone-revision',
      scenes: const [ScriptScene(id: '1', title: 'Anfang', ordinal: 0)],
      roles: const [],
      cues: const [
        ScriptCue(
          id: 'auto-mic',
          sceneId: '1',
          ordinal: 0,
          kind: 'microphone',
          isAutoMic: true,
          text: 'Automatik: Mikrofon ein.',
        ),
        ScriptCue(
          id: 'manual-mic',
          sceneId: '1',
          ordinal: 1,
          kind: 'microphone',
          text: 'Manueller Mikrofonhinweis.',
        ),
      ],
    );
    server.override = (request) =>
        request.url.path.replaceFirst(RegExp(r'/$'), '').endsWith('/script')
        ? Future.value(jsonResponse(document.toJson()))
        : null;
    final controller = server.controller();
    await signIn(controller);
    await _openReader(tester, controller, initialCueId: 'auto-mic');
    expect(find.text('Automatik: Mikrofon ein.'), findsOneWidget);
    expect(find.text('Manueller Mikrofonhinweis.'), findsNothing);
    expect(find.text(_missingCueText), findsNothing);
    expect(
      controller.preferences['reader.$_productionId.categories'],
      unorderedEquals(['direction', 'autoMicrophone']),
    );
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('missing deep-link cues preserve the chosen reading filters', (
    tester,
  ) async {
    final controller = await _demoReader(tester);
    await controller.setPreference('reader.$_productionId.mode', 'actor');
    await controller.setPreference('reader.$_productionId.categories', [
      'direction',
    ]);
    await _openReader(tester, controller, initialCueId: 'missing-cue');
    expect(find.text(_missingCueText), findsOneWidget);
    expect(controller.preferences['reader.$_productionId.mode'], 'actor');
    expect(controller.preferences['reader.$_productionId.categories'], [
      'direction',
    ]);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets(
    'poll synchronization only describes a pending vote for the displayed poll',
    (tester) async {
      final server = TestServer();
      server.data['polls'] = [
        for (final id in ['current-poll', 'other-poll'])
          {
            'id': id,
            'title': id,
            'options': [
              {'id': 'a', 'label': 'A', 'votes': 0},
              {'id': 'b', 'label': 'B', 'votes': 0},
            ],
          },
      ];
      final controller = server.controller();
      await signIn(controller);
      server.offline = true;
      await controller.respond('demo-rehearsal', 'yes');
      expect(controller.pendingCount, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: PollDetailScreen(
            controller: controller,
            pollId: 'current-poll',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_pendingVoteText), findsNothing);
      await controller.vote('other-poll', 'a');
      await tester.pumpAndSettle();
      expect(controller.pendingCount, 2);
      expect(find.text(_pendingVoteText), findsNothing);
      await controller.vote('current-poll', 'b');
      await tester.pumpAndSettle();
      expect(find.text(_pendingVoteText), findsOneWidget);
      expect(controller.polls.first.selectedOptionId, 'b');

      server.offline = false;
      server.actionStatus = 409;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(controller.failedCount, 3);
      expect(find.text(_pendingVoteText), findsNothing);
      expect(controller.polls.first.selectedOptionId, isNull);
      expect(tester.takeException(), isNull);
      await _close(tester, controller);
    },
  );
}
