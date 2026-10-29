import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/shell/app_shell.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/games/data/leaderboard_api.dart';
import 'package:theater_app/features/games/data/runner_menu_preferences.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart'
    show runnerCoversRail;
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;
import 'shell_navigation_test.dart' show finish, pumpDemo;

class _Sound implements RunnerSound {
  final _enabled = ValueNotifier(true);
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  void prepare() {}
  @override
  void play(RunnerSfx sfx) {}
  @override
  void startMusic() {}
  @override
  void stopMusic() {}
  @override
  void dispose() => _enabled.dispose();
}

JsonMap _item(String id, String kind, String name, {bool isDefault = false}) =>
    {
      'id': id,
      'kind': kind,
      'name': name,
      'rarity': 'hellblau',
      'rarities': ['hellblau'],
      if (isDefault) 'default': true,
    };

/// A wardrobe with four of six figures owned and an Ensemble-Strecke.
JsonMap _wardrobe() => {
  'progress': {
    'meters': 2900,
    'earned': 2,
    'opened': 1,
    'crates': 1,
    'missionCrates': 1,
    'previousAt': 2000,
    'nextAt': 4100,
    'poolSize': 4,
    'complete': false,
    'dupes': true,
  },
  'gage': {'balance': 1250, 'earned': 3000},
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hellblau', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
    ],
    'departments': [],
    'items': [
      _item('c0', 'character', 'Engel Logge', isDefault: true),
      _item('b0', 'backdrop', 'Bühnenwand', isDefault: true),
      _item('o0', 'obstacles', 'Requisitenlager', isDefault: true),
      _item('f0', 'fx', 'Ohne Effekt', isDefault: true),
      for (final (i, name) in ['Maren', 'Elena', 'Anton', 'Lea'].indexed)
        _item('p$i', 'character', name),
      _item('b1', 'backdrop', 'Anno 1146'),
      _item('f1', 'fx', 'Funkenflug'),
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0', 'p0', 'p1', 'b1', 'f1'],
  'selected': {
    'character': 'p0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'stats': {'rounds': 12, 'best': 830, 'meters': 2900},
  'ensemble': {
    'meters': 18400,
    'previousKm': 10,
    'next': {
      'km': 25,
      'name': 'Ensemble-Kiste',
      'reward': null,
      'reached': false,
    },
    'milestones': [
      {'km': 10, 'name': 'Ensemble-Kiste', 'reward': null, 'reached': true},
      {'km': 25, 'name': 'Ensemble-Kiste', 'reward': null, 'reached': false},
    ],
    'crates': 0,
    'section': {'own': 1200, 'players': 4},
  },
};

JsonMap _entry(
  int rank,
  int person,
  String name,
  int owned, {
  bool me = false,
}) => {
  'personId': person,
  'name': name,
  'owned': owned,
  'shiny': rank == 1 ? 2 : 0,
  'percent': owned / 6 * 100,
  'rank': rank,
  'me': me,
};

JsonMap _mission(String slot, String text, {bool done = false}) => {
  'slot': slot,
  'type': 'distance',
  'target': 100,
  'progress': done ? 100 : 20,
  'done': done,
  'reward': 300,
  'text': text,
  'unit': 'm',
  'scope': 'run',
};

JsonMap _missions({int done = 2}) => {
  'day': '2026-10-29',
  'missions': [
    _mission('easy', 'Lauf 100 m', done: done > 0),
    _mission('medium', 'Lauf 200 m', done: done > 1),
    _mission('hard', 'Lauf 300 m', done: done > 2),
  ],
  'rerollAvailable': true,
  'allDone': done == 3,
  'crate': {'earned': done == 3, 'shinyChance': 0.05},
};

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerEnsemble',
  'runnerMissions',
  'runnerCollection',
];

/// A server with the whole menu; [collection] answers the collection
/// ranking (null: 404, as from servers without it).
Future<(AppController, List<String>)> _server({
  JsonMap? collection,
  JsonMap Function()? missions,
  List<String> features = _features,
}) async {
  final calls = <String>[];
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = (request) {
    final path = _path(request);
    if (!path.contains('/games/runner/')) return null;
    calls.add(path.split('/games/runner/').last);
    if (path.endsWith('/leaderboard')) {
      return Future.value(
        jsonResponse({
          'players': 14,
          'top': [
            for (var i = 1; i <= 10; i++)
              {
                'rank': i,
                'personId': 100 + i,
                'name': 'Person $i',
                'score': 2000 - i * 50,
              },
          ],
          'own': {
            'rank': 12,
            'personId': 3,
            'name': 'Testmitglied',
            'score': 830,
          },
        }),
      );
    }
    if (path.endsWith('/wardrobe')) {
      return Future.value(jsonResponse(_wardrobe()));
    }
    if (path.endsWith('/missions')) {
      return Future.value(jsonResponse((missions ?? _missions)()));
    }
    if (path.endsWith('/collection')) {
      return Future.value(
        collection == null
            ? jsonResponse({'error': 'not found'}, 404)
            : jsonResponse(collection),
      );
    }
    return null;
  };
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return (controller, calls);
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(390, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

final _collection = {
  'total': 6,
  'entries': [
    _entry(1, 6, 'Elena', 6),
    _entry(2, 7, 'Kim', 5),
    _entry(2, 8, 'Jonas', 5),
    for (var i = 4; i <= 11; i++) _entry(i, 20 + i, 'Mitglied $i', 4),
    _entry(12, 3, 'Testmitglied', 2, me: true),
  ],
};

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('collection ranking', () {
    test('reads ranks, shine and the own row', () {
      final board = CollectionBoard.fromJson(_collection);
      expect(board.total, 6);
      expect(board.entries, hasLength(12));
      expect(board.entries[1].rank, board.entries[2].rank);
      expect(board.entries.first.shiny, 2);
      expect(board.own?.name, 'Testmitglied');
      expect(board.own?.rank, 12);
    });

    test('a separate own row joins the list', () {
      final board = CollectionBoard.fromJson({
        'total': 6,
        'entries': [_entry(1, 6, 'Elena', 6)],
        'own': _entry(30, 3, 'Testmitglied', 1),
      });
      expect(board.own?.rank, 30);
      expect(board.entries, hasLength(2));
    });

    testWidgets('switches between points and collection, own row visible', (
      tester,
    ) async {
      final (controller, calls) = await _server(collection: _collection);
      final menu = RunnerMenuPreferences();
      addTearDown(menu.dispose);
      await _pump(
        tester,
        StageRunnerScreen(
          controller: controller,
          sound: _Sound(),
          menuPreferences: menu,
        ),
      );
      expect(calls, contains('collection'));
      // The points first: the own place after the ten best, highlighted.
      expect(find.text('Person 1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ranking-own')),
          matching: find.text('Testmitglied'),
        ),
        findsOneWidget,
      );
      expect(find.text('Platz 12 von 14'), findsOneWidget);
      // All ten best and the own place are shown: nothing more to open.
      expect(find.byKey(const ValueKey('ranking-all')), findsNothing);

      await tester.tap(find.text('Sammlung').last);
      await tester.pump();
      expect(menu.board, RunnerBoardView.collection);
      expect(find.text('Elena'), findsOneWidget);
      expect(find.text('6/6'), findsOneWidget);
      // Equal collections share their place.
      expect(
        find.descendant(
          of: find.byType(CircleAvatar),
          matching: find.text('2'),
        ),
        findsNWidgets(2),
      );
      // Rank 12 is beyond the first ten, yet the own row shows.
      expect(find.text('Mitglied 11'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ranking-own')),
          matching: find.text('2/6'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('ranking-all')));
      await tester.pump();
      expect(find.text('Mitglied 11'), findsOneWidget);

      // Remembered on the device.
      await menu.loaded;
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(RunnerMenuPreferences.boardKey), 'collection');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('servers without it leave the switch out quietly', (
      tester,
    ) async {
      final (controller, calls) = await _server();
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(calls, contains('collection'));
      expect(find.byKey(const ValueKey('ranking-switch')), findsNothing);
      expect(find.text('Person 1'), findsOneWidget);
      expect(find.textContaining('nicht gefunden'), findsNothing);
      expect(find.text('not found'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the announcement nothing is asked', (tester) async {
      final (controller, calls) = await _server(
        collection: _collection,
        features: [..._features]..remove('runnerCollection'),
      );
      expect(collectionBoardAvailable(controller), isFalse);
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(calls, isNot(contains('collection')));
      expect(find.byKey(const ValueKey('ranking-switch')), findsNothing);
      expect(find.text('Sammlung'), findsOneWidget, reason: 'the standing');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the demo asks nothing and shows no ranking switch', (
      tester,
    ) async {
      final controller = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
      );
      addTearDown(controller.dispose);
      await controller.startDemo();
      expect(collectionBoardAvailable(controller), isFalse);
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(find.byKey(const ValueKey('ranking-switch')), findsNothing);
      expect(find.text('In der Demo gibt es keine Bestenliste.'), findsOne);
      expect(find.byKey(const ValueKey('runner-stand')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('menu', () {
    testWidgets('hero, standing, ensemble, ranking and missions in order', (
      tester,
    ) async {
      final (controller, _) = await _server(collection: _collection);
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(find.text('Maren'), findsOneWidget);
      expect(find.text('Vorhang auf'), findsOneWidget);
      // Four of six figures and the other items: 4 of 6 collectible.
      expect(find.text('4 von 6'), findsOneWidget);
      expect(find.text('Sammlung · Platz 12'), findsOneWidget);
      expect(find.text('1.250'), findsOneWidget, reason: 'the gage');
      expect(find.text('Kisten'), findsOneWidget);
      expect(find.text('noch 1.200 m bis zur nächsten Kiste'), findsOneWidget);
      expect(
        find.text('Nächstes Ziel: noch 6,6 km bis Ensemble-Kiste'),
        findsOneWidget,
      );
      double top(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(top('runner-hero'), lessThan(top('runner-stand')));
      expect(top('runner-stand'), lessThan(top('ensemble-strip')));
      expect(top('ensemble-strip'), lessThan(top('runner-ranking')));
      expect(top('runner-ranking'), lessThan(top('runner-missions')));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sideways the hero stays beside the scrolling rest', (
      tester,
    ) async {
      final (controller, _) = await _server(collection: _collection);
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
        size: const Size(844, 390),
      );
      expect(tester.takeException(), isNull);
      final hero = tester.getRect(find.byKey(const ValueKey('runner-hero')));
      final stand = tester.getRect(find.byKey(const ValueKey('runner-stand')));
      expect(hero.right, lessThan(stand.left));
      expect(
        tester.getRect(find.text('Vorhang auf')).bottom,
        lessThan(390),
        reason: 'the start is in view',
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('missions', () {
    testWidgets('finished ones fold into one line, open ones stay', (
      tester,
    ) async {
      final (controller, _) = await _server();
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(find.text('2/3 geschafft'), findsOneWidget);
      expect(find.text('Schwer · Lauf 300 m'), findsOneWidget);
      expect(find.text('Leicht · Lauf 100 m'), findsNothing);
      expect(find.text('2 Missionen geschafft'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('missions-done-toggle')));
      await tester.pump();
      expect(find.text('Leicht · Lauf 100 m'), findsOneWidget);
      expect(find.text('Mittel · Lauf 200 m'), findsOneWidget);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getBool(RunnerMenuPreferences.doneMissionsKey), isTrue);

      // Opened again, the choice holds.
      await tester.pumpWidget(const SizedBox());
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(find.text('Leicht · Lauf 100 m'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('all done is one short line', (tester) async {
      final (controller, _) = await _server(missions: () => _missions(done: 3));
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(find.text('3/3 geschafft'), findsOneWidget);
      expect(find.text('Alle 3 geschafft'), findsOneWidget);
      expect(find.textContaining('Lauf 100 m'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('sideways on a phone', () {
    test('only phones cover the rail', () {
      expect(runnerCoversRail(const Size(932, 430)), isTrue);
      expect(runnerCoversRail(const Size(430, 932)), isTrue);
      expect(runnerCoversRail(const Size(1180, 820)), isFalse);
      expect(runnerCoversRail(const Size(1440, 900)), isFalse);
    });

    Future<void> open(WidgetTester tester, Size size) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
    }

    testWidgets('the game covers the rail and goes back to the app', (
      tester,
    ) async {
      // Wider than the rail's breakpoint, shorter side below 600. (At
      // 932 × 430 the shell's own rail does not fit its height yet.)
      await open(tester, const Size(1000, 560));
      final c = await pumpDemo(tester);
      expect(find.byType(NavigationRail), findsOneWidget);
      openStageRunner(tester.element(find.byType(AppShell)), c);
      await tester.pumpAndSettle();
      expect(find.byType(StageRunnerScreen), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(
        tester.getRect(find.byType(StageRunnerScreen)),
        const Rect.fromLTWH(0, 0, 1000, 560),
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(StageRunnerScreen), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      await finish(tester, c);
    });

    testWidgets('a tablet keeps the rail beside the game', (tester) async {
      await open(tester, const Size(1180, 820));
      final c = await pumpDemo(tester);
      openStageRunner(tester.element(find.byType(AppShell)), c);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      await finish(tester, c);
    });
  });
}
