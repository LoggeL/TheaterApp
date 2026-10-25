import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/missions_api.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

class _Sound implements RunnerSound {
  final played = <RunnerSfx>[];
  final _enabled = ValueNotifier(true);
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  void prepare() {}
  @override
  void play(RunnerSfx sfx) => played.add(sfx);
  @override
  void startMusic() {}
  @override
  void stopMusic() {}
  @override
  void dispose() => _enabled.dispose();
}

/// Steers around the obstacles like a careful player (as in
/// stage_runner_test.dart).
void _pilotStep(StageRunner game) {
  const f = StageRunner.floor, c = StageRunner.ceiling;
  const hw = StageRunner.hitHalfWidth + .01;
  const hh = StageRunner.hitHalfHeight + .015;
  const minY = c + StageRunner.runnerHeight / 2;
  const maxY = f - StageRunner.runnerHeight / 2;
  final x = game.runnerWorldX;
  final ahead = game.obstacles.where((o) => o.right > x - hw).toList()
    ..sort((a, b) => a.left.compareTo(b.left));
  var lo = minY, hi = maxY;
  if (ahead.isNotEmpty) {
    final first = ahead.first;
    for (final o in ahead.where((o) => o.left < first.right + hw)) {
      switch (o.kind) {
        case ObstacleKind.sandbag:
          hi = min(hi, f - (o.bottom - o.top) - hh);
        case ObstacleKind.drop:
          lo = max(lo, o.anchor + StageRunner.dropSwing + hh);
        case _ when o.top <= 0:
          lo = max(lo, o.bottom + hh);
        case _:
          hi = min(hi, o.top - hh);
      }
    }
  }
  final y = game.y;
  final target = lo > hi ? (lo + hi) / 2 : y.clamp(lo, hi).toDouble();
  final wanted = ((target - y) * 10)
      .clamp(-StageRunner.maxRise, StageRunner.maxFall)
      .toDouble();
  game.holding = game.vy > wanted;
  game.update(1 / 60);
}

/// The server's plausibility rules (`checkRunStats` in
/// server/src/runner-missions.mjs), to prove real runs pass them.
void _expectPlausible(StageRunner game) {
  final s = game.missionStats, meters = game.meters, score = game.score;
  final passed = s['passed']! as Map<String, int>;
  final rose = s['rose']! as int, mask = s['mask']! as int;
  final star = s['star']! as int;
  expect(
    (s['ground']! as int) + (s['ceiling']! as int),
    lessThanOrEqualTo(meters),
  );
  expect(rose * 5 + mask * 10 + star * 25, score - meters);
  expect(rose / 3 + mask / 2 + star, lessThanOrEqualTo(meters / 6 + 2));
  expect(
    passed.values.fold(0, (a, b) => a + b),
    lessThanOrEqualTo(meters / 6 + 2),
  );
  for (final (points, kind) in StageRunner.debuts) {
    if ((passed[kind.name] ?? 0) > 0) {
      expect(score, greaterThanOrEqualTo(points), reason: kind.name);
    }
  }
  if ((passed['border'] ?? 0) > 0) expect(meters, greaterThanOrEqualTo(70));
  if ((passed['sandbag'] ?? 0) > 0) expect(meters, greaterThanOrEqualTo(140));
}

JsonMap _mission(
  String slot,
  String type,
  String text,
  int target, {
  String? kind,
  int progress = 0,
  bool done = false,
  bool justDone = false,
  String unit = 'm',
}) => {
  'slot': slot,
  'type': type,
  'kind': ?kind,
  'target': target,
  'progress': progress,
  'done': done,
  'reward': {'easy': 300, 'medium': 600, 'hard': 1000}[slot],
  'text': text,
  'unit': unit,
  'scope': 'run',
  if (justDone) 'justDone': true,
};

JsonMap _missions({
  bool allDone = false,
  bool rerollAvailable = true,
  List<JsonMap>? missions,
}) => {
  'day': '2026-10-24',
  'missions':
      missions ??
      [
        _mission('easy', 'distance', 'Lauf 1 m in einem Durchgang', 1),
        _mission(
          'medium',
          'collect',
          'Sammle 25 Rosen in einem Lauf',
          25,
          kind: 'rose',
          unit: 'Rosen',
        ),
        _mission(
          'hard',
          'pass',
          'Unterquere 8 Traversen in einem Lauf',
          8,
          kind: 'truss',
          unit: 'Traversen',
        ),
      ],
  'rerollAvailable': rerollAvailable,
  'allDone': allDone,
  'crate': {'earned': allDone, 'shinyChance': 0.05},
};

JsonMap _item(String id, String kind, String name) => {
  'id': id,
  'kind': kind,
  'name': name,
  'rarity': 'hellblau',
  'rarities': ['hellblau'],
  'default': true,
};

JsonMap _wardrobe({int missionCrates = 0}) => {
  'progress': {
    'meters': 500,
    'earned': 0,
    'opened': 0,
    'crates': 0,
    'previousAt': 0,
    'nextAt': 2000,
    'poolSize': 1,
    'complete': false,
    'dupes': true,
    'missionMeters': 300,
    'missionCrates': missionCrates,
  },
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hellblau', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
    ],
    'departments': [],
    'items': [
      _item('c0', 'character', 'Engel Logge'),
      _item('b0', 'backdrop', 'Bühnenwand'),
      _item('o0', 'obstacles', 'Requisitenlager'),
      _item('f0', 'fx', 'Ohne Effekt'),
      {..._item('c1', 'character', 'Maren'), 'default': false},
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0'],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'stats': {'rounds': 3, 'best': 300, 'meters': 200, 'missionMeters': 300},
};

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<AppController> _signedIn(
  Future<http.Response>? Function(http.Request) handle, {
  required List<String> features,
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = handle;
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  await tester.pump();
  await tester.pump();
}

const _all = ['stageRunner', 'runnerUnlocks', 'runnerDupes', 'runnerMissions'];

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('counting in the run', () {
    test('letting go runs along the floor, holding flies below the loft', () {
      final ground = StageRunner(random: Random(1))..invincible = true;
      for (var i = 0; i < 60 * 20; i++) {
        ground.update(1 / 60);
      }
      expect(ground.meters, greaterThan(100));
      expect(ground.groundMeters, ground.meters);
      expect(ground.ceilingMeters, 0);

      final loft = StageRunner(random: Random(1))..invincible = true;
      loft.holding = true;
      for (var i = 0; i < 60 * 20; i++) {
        loft.update(1 / 60);
      }
      // Only the short climb at the start is neither.
      expect(loft.ceilingMeters, greaterThan(loft.meters - 15));
      expect(loft.ceilingMeters, lessThan(loft.meters));
      expect(loft.groundMeters, lessThan(5));
    });

    test('pickups by kind add up to the pickup points', () {
      final game = StageRunner(random: Random(5))..invincible = true;
      for (var i = 0; i < 60 * 60; i++) {
        final ahead = game.pickups.where((p) => p.x > game.runnerWorldX - .02);
        final next = ahead.isEmpty
            ? null
            : ahead.reduce((a, b) => a.x < b.x ? a : b);
        game.holding = next != null && next.y < game.y;
        game.update(1 / 60);
      }
      expect(game.collected, greaterThan(20));
      expect(
        PickupKind.values.fold(0, (a, k) => a + game.collectedOf(k)),
        game.collected,
      );
      expect(
        PickupKind.values.fold(0, (a, k) => a + game.collectedOf(k) * k.points),
        game.pickupPoints,
      );
      _expectPlausible(game);
    });

    test('each section counts once when the runner is past it', () {
      final game = StageRunner(random: Random(4))..invincible = true;
      var passedBefore = 0;
      for (var i = 0; i < 60 * 90; i++) {
        game.update(1 / 60);
        final passed = game.passedBy.fold(0, (a, b) => a + b);
        expect(passed, greaterThanOrEqualTo(passedBefore));
        passedBefore = passed;
      }
      // A border's gap counts as one border, not also as a flat; a pile once.
      final sections = game.passedBy.fold(0, (a, b) => a + b);
      expect(sections, greaterThan(50));
      expect(sections, lessThanOrEqualTo(game.meters / 6 + 2));
      expect(game.passedOf(ObstacleKind.border), greaterThan(0));
      // 90 s with pickups gets far past every debut.
      expect(game.passedOf(ObstacleKind.drum), greaterThan(0));
      expect(game.missionStats['passed'], isA<Map<String, int>>());
      for (final o in game.obstacles) {
        if (o.counted && o.right < game.runnerWorldX - .03) {
          expect(o.passed, isTrue);
        }
      }
    });

    test('real runs of a careful player pass the server checks', () {
      for (var seed = 1; seed <= 12; seed++) {
        final game = StageRunner(random: Random(seed));
        for (var i = 0; i < 60 * 240 && !game.over; i++) {
          _pilotStep(game);
        }
        expect(game.meters, greaterThan(50), reason: 'seed $seed');
        _expectPlausible(game);
      }
    });

    test('the watch tells a made mission once, while running', () {
      final missions = DailyMissions.fromJson(
        _missions(
          missions: [
            _mission('easy', 'distance', 'Lauf 30 m', 30),
            _mission('medium', 'ground', 'Bleib 20 m am Boden', 20),
            _mission('hard', 'pass', 'Unterquere 1 Traverse', 1, kind: 'truss'),
          ],
        ),
      );
      expect(missions.missions.last.obstacle, ObstacleKind.truss);
      final watch = MissionWatch(missions);
      final game = StageRunner(random: Random(1))..invincible = true;
      final made = <String>[];
      for (var i = 0; i < 60 * 10; i++) {
        game.update(1 / 60);
        if (watch.check(game) case final m?) made.add(m.slot);
      }
      expect(made, ['medium', 'easy']);
      // Done ones are not watched.
      final done = DailyMissions.fromJson(
        _missions(
          missions: [_mission('easy', 'distance', 'Lauf 1 m', 1, done: true)],
        ),
      );
      expect(MissionWatch(done).check(game), isNull);
    });
  });

  group('names of the worn backdrop', () {
    test('plurals of the themed pickups', () {
      expect(
        [
          'Bonbon',
          'Kürbis',
          'Julias Rose',
          'Teufelsstern',
          'Glut',
          'Flämmchen',
          'Siegel',
          'Lorbeerkranz',
          'Datenchip',
        ].map(collectiblePlural),
        [
          'Bonbons',
          'Kürbisse',
          'Julias Rosen',
          'Teufelssterne',
          'Glutstücke',
          'Flämmchen',
          'Siegel',
          'Lorbeerkränze',
          'Datenchips',
        ],
      );
    });

    test('a collect mission says the backdrop’s name, singular for one', () {
      DailyMission collect(String kind, int target) => DailyMission.fromJson(
        _mission(
          'easy',
          'collect',
          'Sammle $target Rosen in einem Lauf',
          target,
          kind: kind,
          unit: 'Rosen',
        ),
      );
      const names = {'rose': 'Kürbis', 'star': 'Teufelsstern'};
      expect(
        collect('rose', 12).textFor(names),
        'Sammle 12 Kürbisse in einem Lauf',
      );
      expect(collect('rose', 12).unitFor(names), 'Kürbisse');
      expect(
        collect('star', 1).textFor(names),
        'Sammle 1 Teufelsstern in einem Lauf',
      );
      // Without a name of the backdrop (or a blank one) the server's text.
      expect(collect('mask', 3).textFor(names), 'Sammle 3 Rosen in einem Lauf');
      expect(
        collect('rose', 2).textFor({'rose': ' '}),
        'Sammle 2 Rosen in einem Lauf',
      );
      expect(collect('mask', 3).unitFor(names), 'Rosen');
      // Other types keep their text.
      final distance = DailyMission.fromJson(
        _mission('easy', 'distance', 'Lauf 300 m in einem Durchgang', 300),
      );
      expect(distance.textFor(names), 'Lauf 300 m in einem Durchgang');
    });
  });

  group('screens', () {
    testWidgets('with the feature: the card, a reroll, the banner, the note '
        'and the celebration', (tester) async {
      final calls = <String>[];
      JsonMap? submitted;
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (!path.contains('/games/runner/')) return null;
        calls.add('${request.method} ${path.split('/games/runner/').last}');
        if (path.endsWith('/leaderboard')) {
          return Future.value(
            jsonResponse({'players': 0, 'top': [], 'own': null}),
          );
        }
        if (path.endsWith('/wardrobe')) {
          return Future.value(jsonResponse(_wardrobe()));
        }
        if (path.endsWith('/missions/reroll')) {
          expect(jsonDecode(request.body), {'slot': 'hard'});
          expect(request.headers['idempotency-key'], isNotEmpty);
          return Future.value(
            jsonResponse(
              _missions(
                rerollAvailable: false,
                missions: [
                  _mission(
                    'easy',
                    'distance',
                    'Lauf 1 m in einem Durchgang',
                    1,
                  ),
                  _mission(
                    'medium',
                    'collect',
                    'Sammle 25 Rosen in einem Lauf',
                    25,
                    kind: 'rose',
                  ),
                  _mission('hard', 'ground', 'Bleib 2 m am Boden', 2),
                ],
              ),
            ),
          );
        }
        if (path.endsWith('/missions')) {
          return Future.value(jsonResponse(_missions()));
        }
        if (path.endsWith('/rounds')) {
          return Future.value(jsonResponse({'roundId': 'r-1'}));
        }
        if (path.endsWith('/scores')) {
          submitted = jsonMap(jsonDecode(request.body));
          return Future.value(
            jsonResponse({
              'score': submitted!['score'],
              'improved': false,
              'leaderboard': {'players': 0, 'top': [], 'own': null},
              'progress': {
                'meters': 2400,
                'earned': 1,
                'opened': 0,
                'crates': 1,
                'previousAt': 2000,
                'nextAt': 4100,
                'gained': 120,
                'missionBonus': 1300,
                'missionCrates': 1,
                'newCrates': 1,
                'missions': _missions(
                  allDone: true,
                  rerollAvailable: false,
                  missions: [
                    _mission(
                      'easy',
                      'distance',
                      'Lauf 1 m in einem Durchgang',
                      1,
                      progress: 1,
                      done: true,
                      justDone: true,
                    ),
                    _mission(
                      'medium',
                      'collect',
                      'Sammle 25 Rosen in einem Lauf',
                      25,
                      progress: 25,
                      done: true,
                      unit: 'Rosen',
                    ),
                    _mission(
                      'hard',
                      'ground',
                      'Bleib 2 m am Boden',
                      2,
                      progress: 2,
                      done: true,
                      justDone: true,
                    ),
                  ],
                ),
              },
            }),
          );
        }
        return null;
      }, features: _all);
      final sound = _Sound();
      await _pump(
        tester,
        StageRunnerScreen(
          controller: controller,
          random: Random(3),
          sound: sound,
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Tagesmissionen'), findsOneWidget);
      expect(find.text('Leicht · Lauf 1 m in einem Durchgang'), findsOneWidget);
      expect(find.text('0/25 Rosen · +600 m für die Kisten'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mission-reroll-hard')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, contains('POST missions/reroll'));
      expect(find.text('Schwer · Bleib 2 m am Boden'), findsOneWidget);
      expect(find.byKey(const ValueKey('mission-reroll-easy')), findsNothing);

      await tester.tap(find.text('Vorhang auf'));
      var banner = false;
      for (
        var i = 0;
        i < 60 * 20 && find.text('Nochmal').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        banner |= find
            .byKey(const ValueKey('runner-mission-banner'))
            .evaluate()
            .isNotEmpty;
      }
      await tester.pump(const Duration(milliseconds: 700));
      expect(banner, isTrue);
      final stats = jsonMap(submitted!['missionStats']);
      expect(stats.keys, containsAll(['rose', 'ground', 'ceiling', 'passed']));
      expect(
        find.text(
          'Mission geschafft: Lauf 1 m in einem Durchgang · +300 m für die Kisten',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('runner-missions-all')), findsOneWidget);
      expect(find.textContaining('Missionen +1.300 m'), findsOneWidget);
      expect(sound.played, contains(RunnerSfx.jackpot));
      expect(find.text('3/3 geschafft'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the feature nothing of it shows or is asked', (
      tester,
    ) async {
      final calls = <String>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (!path.contains('/games/runner/')) return null;
        calls.add(path.split('/games/runner/').last);
        if (path.endsWith('/leaderboard')) {
          return Future.value(
            jsonResponse({'players': 0, 'top': [], 'own': null}),
          );
        }
        if (path.endsWith('/wardrobe')) {
          return Future.value(jsonResponse(_wardrobe(missionCrates: 1)));
        }
        return null;
      }, features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes']);
      expect(missionsAvailable(controller), isFalse);
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Tagesmissionen'), findsNothing);
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('wardrobe-tab-crates')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('runner-missions')), findsNothing);
      expect(
        find.byKey(const PageStorageKey('wardrobe-missions-section')),
        findsNothing,
      );
      expect(calls.where((c) => c.startsWith('missions')), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the wardrobe shows the missions and opens a Missionskiste', (
      tester,
    ) async {
      final bodies = <Object?>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/wardrobe')) {
          return Future.value(jsonResponse(_wardrobe(missionCrates: 1)));
        }
        if (path.endsWith('/missions')) {
          return Future.value(
            jsonResponse(_missions(allDone: true, rerollAvailable: false)),
          );
        }
        if (path.endsWith('/crates')) {
          bodies.add(jsonDecode(request.body));
          return Future.value(jsonResponse({'error': 'gleich'}, 409));
        }
        return null;
      }, features: _all);
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('wardrobe-tab-crates')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.byKey(const PageStorageKey('wardrobe-missions-section')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('runner-missions')), findsOneWidget);
      expect(
        find.text('Alle drei geschafft – die Missionskiste ist verdient.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('mission-crate-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(bodies, [
        {'dupes': true, 'crate': 'mission'},
      ]);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
