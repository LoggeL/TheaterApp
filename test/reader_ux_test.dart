import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/scripts/scripts.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;

const _productionId = DemoData.mainProductionId;
const _lightText = 'LX 01 · Warmes Arbeitslicht, Bühne 40 %.';
const _lenaText = 'Sag bitte, dass du den Schlüssel hast.';

void _phone(WidgetTester tester, [Size size = const Size(390, 844)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<AppController> _demo(WidgetTester tester, {Size? size}) async {
  _phone(tester, size ?? const Size(390, 844));
  final controller = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
  );
  await controller.init();
  await controller.startDemo();
  return controller;
}

Future<void> _prefs(
  AppController controller,
  Map<String, Object?> values,
) async {
  for (final entry in values.entries) {
    await controller.setPreference(
      'reader.$_productionId.${entry.key}',
      entry.value,
    );
  }
}

Future<void> _open(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ScriptReaderScreen(
        controller: controller,
        productionId: _productionId,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

String _cueId(AppController controller, bool Function(ScriptCue) test) =>
    controller.scripts[_productionId]!.cues.firstWhere(test).id;

void main() {
  group('pure helpers', () {
    const roles = [
      ScriptRole(id: 'LENA', name: 'Lena', personId: 7),
      ScriptRole(id: 'OSKAR', name: 'Oskar'),
      ScriptRole(id: 'MIRA', name: 'Mira', personId: 7),
    ];

    test('role labels use names and a correct plural', () {
      expect(roleLabel({'LENA'}, roles), 'Lena');
      expect(roleLabel({'lena'}, roles), 'Lena');
      expect(roleLabel({'LENA', 'MIRA'}, roles), '2 Rollen');
      expect(roleLabel(<String>{}, roles), '');
      expect(roleNames({'GAST'}, roles), ['GAST']);
      expect(roleNames({'MIRA', 'LENA'}, roles), ['Lena', 'Mira']);
    });

    test('production cards fall back to the cast list', () {
      const production = Production(id: 'p', title: 'Stück', roles: roles);
      expect(cardRoleNames(production, {}, 7), ['Lena', 'Mira']);
      expect(cardRoleNames(production, {}, 8), isEmpty);
      expect(
        cardRoleNames(production, {
          'reader.p.roles': ['OSKAR'],
        }, 7),
        ['Oskar'],
      );
      expect(
        cardRoleNames(production, {'reader.p.assignedRoles': false}, 7),
        isEmpty,
      );
    });

    test('comment times read naturally', () {
      final now = DateTime(2026, 9, 12, 12);
      expect(
        commentTime(now.subtract(const Duration(seconds: 20)), now),
        'gerade eben',
      );
      expect(
        commentTime(now.subtract(const Duration(minutes: 1)), now),
        'vor 1 Minute',
      );
      expect(
        commentTime(now.subtract(const Duration(minutes: 5)), now),
        'vor 5 Minuten',
      );
      expect(
        commentTime(now.subtract(const Duration(hours: 3)), now),
        'vor 3 Stunden',
      );
      expect(commentTime(DateTime(2026, 9, 11, 18, 5), now), 'gestern, 18:05');
      expect(commentTime(DateTime(2026, 8, 1, 9), now), '1.8.2026');
    });

    test('notes and bookmarks group by scene in script order', () {
      final document = DemoData(now: fixedNow).script(_productionId);
      final late = document.cues.lastWhere((c) => c.kind == 'dialogue');
      final early = document.cues.firstWhere((c) => c.kind == 'dialogue');
      final grouped = groupByScene(document, [late.id, 'gone', early.id]);
      expect(grouped.groups.first.cues.first.id, early.id);
      expect(grouped.groups.last.cues.last.id, late.id);
      expect(grouped.groups.first.title, 'Ein Schlüssel fehlt');
      expect(grouped.orphans, ['gone']);
    });

    test('reader preferences keep the persisted keys and mode codes', () {
      final legacy = ReaderPreferences.read({
        'reader.x.actorMode': true,
        'reader.x.role': 'LENA',
      }, 'x');
      expect(legacy.mode, ReaderMode.actor);
      expect(legacy.roles, {'LENA'});
      expect(legacy.assignedRoles, isFalse);
      expect(
        ReaderPreferences.read({'reader.x.mode': 'bogus'}, 'x').mode,
        ReaderMode.read,
      );
      expect(ReaderMode.values.map((m) => m.code), [
        'read',
        'practice',
        'actor',
        'technical',
        'cues',
        'stage',
      ]);
      expect(ReaderPreferences.key('x', 'mode'), 'reader.x.mode');
    });
  });

  testWidgets('a scene click in "Meine Texte" keeps the mode on desktop', (
    tester,
  ) async {
    final controller = await _demo(tester, size: const Size(1440, 900));
    await _prefs(controller, {
      'roles': ['LENA'],
      'role': 'LENA',
      'assignedRoles': false,
      'mode': 'actor',
    });
    await _open(tester, controller);
    final scenes = controller.scripts[_productionId]!.scenes;
    await tester.tap(find.byKey(ValueKey('reader-scene-${scenes.last.id}')));
    await tester.pumpAndSettle();
    expect(controller.preferences['reader.$_productionId.mode'], 'actor');
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('reader-mode-actor')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(ValueKey('reader-scene-${scenes.last.id}')),
          )
          .selected,
      isTrue,
    );
    expect(find.textContaining('umgestellt'), findsNothing);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('an automatic switch to "Lesen" can be undone', (tester) async {
    final controller = await _demo(tester);
    final light = _cueId(controller, (c) => c.text == _lightText);
    await _prefs(controller, {
      'roles': ['LENA'],
      'role': 'LENA',
      'assignedRoles': false,
      'mode': 'actor',
      'bookmarks': [light],
    });
    await _open(tester, controller);
    await tester.tap(find.byTooltip('Lesezeichen öffnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_lightText));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Ansicht auf „Lesen“ umgestellt, damit die Textstelle sichtbar ist',
      ),
      findsOneWidget,
    );
    expect(controller.preferences['reader.$_productionId.mode'], 'read');
    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(controller.preferences['reader.$_productionId.mode'], 'actor');
    expect(controller.preferences['reader.$_productionId.categories'], [
      'direction',
    ]);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('a search hit in a hidden category says what was shown', (
    tester,
  ) async {
    final controller = await _demo(tester);
    await _open(tester, controller);
    await tester.tap(find.byTooltip('Im Drehbuch suchen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'LX 01');
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Weitere Hinweise eingeblendet, damit die Textstelle sichtbar ist',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('a secondary click opens the cue actions', (tester) async {
    final controller = await _demo(tester, size: const Size(1440, 900));
    await _open(tester, controller);
    await tester.tap(
      find.text(_lenaText).first,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Lesezeichen setzen'), findsOneWidget);
    expect(find.text('Text kopieren'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('the phone hint about cue actions can be dismissed for good', (
    tester,
  ) async {
    final controller = await _demo(tester);
    await _open(tester, controller);
    expect(
      find.textContaining('Halte eine Textstelle gedrückt'),
      findsOneWidget,
    );
    await tester.tap(find.text('Verstanden'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Halte eine Textstelle gedrückt'), findsNothing);
    expect(controller.preferences[ReaderPreferences.hintCueActionsKey], isTrue);
    await _open(tester, controller);
    expect(find.text('Verstanden'), findsNothing);
    await _close(tester, controller);
  });

  testWidgets('the note icon opens the note editor directly', (tester) async {
    final controller = await _demo(tester);
    final cue = _cueId(controller, (c) => c.text == _lenaText);
    await _prefs(controller, {
      'notes': {
        cue: {'text': 'Langsamer', 'revision': 'demo-1', 'sceneId': '1'},
      },
    });
    await _open(tester, controller);
    await tester.tap(find.byTooltip('Notiz zur Textstelle').first);
    await tester.pumpAndSettle();
    expect(find.text('Nur für dich auf diesem Gerät.'), findsOneWidget);
    expect(find.text('Notiz löschen'), findsOneWidget);
    await _close(tester, controller);
  });

  testWidgets('notes are grouped by scene and a deletion can be undone', (
    tester,
  ) async {
    final controller = await _demo(tester);
    final first = _cueId(controller, (c) => c.text == _lenaText);
    final later = _cueId(
      controller,
      (c) => c.sceneId == '2' && c.kind == 'dialogue',
    );
    await _prefs(controller, {
      'notes': {
        later: {'text': 'Notiz B', 'revision': 'demo-1', 'sceneId': '2'},
        first: {'text': 'Notiz A', 'revision': 'demo-1', 'sceneId': '1'},
      },
    });
    await _open(tester, controller);
    await tester.tap(find.byTooltip('Private Notizen'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    Finder inSheet(String text) =>
        find.descendant(of: sheet, matching: find.text(text));
    expect(
      tester.getTopLeft(inSheet('Notiz A')).dy,
      lessThan(tester.getTopLeft(inSheet('Notiz B')).dy),
    );
    expect(inSheet('Ein Schlüssel fehlt'), findsOneWidget);
    expect(inSheet('Hinter dem Vorhang'), findsOneWidget);
    await tester.tap(find.byTooltip('Notiz löschen').first);
    await tester.pumpAndSettle();
    expect(inSheet('Notiz gelöscht'), findsOneWidget);
    expect(inSheet('Notiz A'), findsNothing);
    expect(
      (controller.preferences['reader.$_productionId.notes'] as Map).keys,
      [later],
    );
    await tester.tap(inSheet('Rückgängig'));
    await tester.pumpAndSettle();
    expect(inSheet('Notiz A'), findsOneWidget);
    expect(
      (controller.preferences['reader.$_productionId.notes'] as Map).keys,
      unorderedEquals([later, first]),
    );
    await _close(tester, controller);
  });

  testWidgets('roles sheet explains a missing assignment and labels roles', (
    tester,
  ) async {
    final controller = await _demo(tester);
    await _open(tester, controller);
    await tester.tap(find.text('Meine Rollen').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('noch keine Rolle zugewiesen'), findsOneWidget);
    await tester.tap(find.text('Lena'));
    await tester.tap(find.text('Mira'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Übernehmen'));
    await tester.pumpAndSettle();
    expect(find.text('2 Rollen'), findsOneWidget);
    expect(find.byTooltip('Nächster Einsatz'), findsOneWidget);
    await tester.tap(find.text('2 Rollen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mira'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Übernehmen'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Lena'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester, controller);
  });

  testWidgets('mode picker describes each mode', (tester) async {
    final controller = await _demo(tester);
    await _open(tester, controller);
    expect(find.text('Rolle wählen'), findsOneWidget);
    await tester.tap(find.byTooltip('Lesemodus'));
    await tester.pumpAndSettle();
    for (final mode in ReaderMode.values) {
      expect(find.text(mode.description), findsOneWidget);
    }
    await _close(tester, controller);
  });

  testWidgets('refreshing the version reports the result', (tester) async {
    final controller = await _demo(tester);
    await _open(tester, controller);
    await tester.tap(find.byTooltip('Weitere Aktionen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fassung aktualisieren'));
    await tester.pumpAndSettle();
    expect(find.text('Du hast bereits die aktuelle Fassung'), findsOneWidget);
    await _close(tester, controller);
  });

  group('comments', () {
    TestServer commentServer() {
      final server = TestServer();
      server.override = (request) {
        if (!request.url.path.endsWith('/comments/')) return null;
        return Future.value(
          jsonResponse({
            'comments': [
              {
                'id': 'c1',
                'productionId': _productionId,
                'cueId': 'demo-cue-4',
                'revision': 'demo-1',
                'text': 'Hier bitte lauter.',
                'authorName': 'Mira Muster',
                'createdAt': fixedNow
                    .subtract(const Duration(minutes: 5))
                    .toUtc()
                    .toIso8601String(),
              },
              {
                'id': 'c2',
                'productionId': _productionId,
                'cueId': 'demo-cue-4',
                'revision': 'alt',
                'text': 'Aus der Leseprobe.',
                'authorName': 'Robin',
                'createdAt': '2026-09-01T10:00:00Z',
              },
            ],
          }),
        );
      };
      return server;
    }

    testWidgets('cue cards count comments and the page confirms deletion', (
      tester,
    ) async {
      _phone(tester);
      final server = commentServer();
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      await controller.loadScript(_productionId);
      await tester.pumpWidget(
        MaterialApp(
          home: ScriptReaderScreen(
            controller: controller,
            productionId: _productionId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '2'));
      await tester.pumpAndSettle();
      expect(find.byType(CueCommentsScreen), findsOneWidget);
      expect(find.textContaining('Ein Schlüssel fehlt'), findsOneWidget);
      expect(
        find.textContaining('vor 5 Minuten', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Aus einer älteren Fassung'), findsOneWidget);

      final send = find.byTooltip('Kommentieren');
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.send_outlined),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), 'Neuer Hinweis');
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(server.actionBodies.last['action'], 'comment.save');
      expect(server.actionBodies.last['text'], 'Neuer Hinweis');
      expect(find.text('Kommentar gespeichert'), findsOneWidget);

      await tester.tap(find.byTooltip('Kommentar löschen').last);
      await tester.pumpAndSettle();
      expect(find.text('Kommentar löschen?'), findsOneWidget);
      await tester.tap(find.text('Löschen'));
      await tester.pumpAndSettle();
      expect(server.actionBodies.last['action'], 'comment.delete');
      expect(server.actionBodies.last['id'], 'c1');
      expect(find.text('Kommentar gelöscht'), findsOneWidget);
      expect(find.text('Hier bitte lauter.'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a cue without comments invites the first one', (tester) async {
      _phone(tester);
      final server = commentServer();
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      await controller.loadScript(_productionId);
      final document = controller.scripts[_productionId]!;
      await tester.pumpWidget(
        MaterialApp(
          home: CueCommentsScreen(
            controller: controller,
            document: document,
            cue: document.cues.firstWhere((c) => c.id == 'demo-cue-5'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Noch keine Kommentare – schreib den ersten für das Ensemble.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the demo replaces the composer with a hint', (tester) async {
      final controller = await _demo(tester);
      final document = controller.scripts[_productionId]!;
      await tester.pumpWidget(
        MaterialApp(
          home: CueCommentsScreen(
            controller: controller,
            document: document,
            cue: document.cues.firstWhere((c) => c.text == _lenaText),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('In der Demo kannst du keine Kommentare schreiben.'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      await _close(tester, controller);
    });
  });

  testWidgets('the library shows a separate error state with a retry', (
    tester,
  ) async {
    _phone(tester);
    final server = TestServer()..offline = true;
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProductionsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Drehbücher.'), findsOneWidget);
    expect(find.text('Aktuelle Produktionen'), findsOneWidget);
    expect(
      find.text('Drehbücher konnten nicht geladen werden.'),
      findsOneWidget,
    );
    server.offline = false;
    await tester.tap(find.text('Erneut versuchen'));
    await tester.pumpAndSettle();
    expect(find.text('Drehbücher konnten nicht geladen werden.'), findsNothing);
    expect(find.text('Neuestes Stück'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
