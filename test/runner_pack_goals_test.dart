import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/crate_opening.dart';
import 'package:theater_app/features/games/ui/pack_goals_card.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerRoleFigures',
  'runnerPackGoals',
];

JsonMap _goal({
  String id = 'hell-2026',
  String name = 'Eine höllische Herausforderung',
  int meters = 32000,
  int own = 1200,
  bool reached = false,
  int crates = 0,
}) => {
  'releaseId': id,
  'name': name,
  'startsAt': '2026-11-08T17:00:00Z',
  'goalMeters': 100000,
  'meters': meters,
  'contributionMeters': own,
  'contributors': 7,
  'reached': reached,
  if (reached) 'reachedAt': '2026-11-10T18:00:00Z',
  'crateCount': 3,
  'crates': crates,
  'eligible': own > 0,
};

JsonMap _item(String id, String kind, {bool isDefault = false}) => {
  'id': id,
  'kind': kind,
  'name': id,
  'rarity': 'hell',
  'rarities': ['hell'],
  if (isDefault) 'default': true,
};

JsonMap _wardrobe({List<JsonMap> goals = const [], int ownCrates = 0}) => {
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hell', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
    ],
    'items': [
      _item('c0', 'character', isDefault: true),
      _item('b0', 'backdrop', isDefault: true),
      _item('o0', 'obstacles', isDefault: true),
      _item('f0', 'fx', isDefault: true),
      _item('character.elena--hell', 'character'),
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0'],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'progress': {
    'crates': ownCrates,
    'packCrates': goals.fold<int>(0, (n, g) => n + intValue(g['crates'])),
    'dupes': true,
    'poolSize': 1,
  },
  'packGoals': goals,
};

JsonMap _opening(JsonMap wardrobe) => {
  'item': _item('character.elena--hell', 'character'),
  'reel': List.filled(56, 'character.elena--hell'),
  'winnerIndex': 48,
  'outcome': {
    'type': 'new',
    'crate': 'pack',
    'packId': 'hell-2026',
    'name': 'Eine höllische Herausforderung',
  },
  'wardrobe': wardrobe,
};

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

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<AppController> _signedIn({
  Future<http.Response>? Function(http.Request)? handle,
  List<String> features = _features,
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = handle;
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

void main() {
  test('pack rewards contribute to the waiting badge without own crates', () {
    final w = Wardrobe.fromJson(
      _wardrobe(goals: [_goal(reached: true, meters: 100000, crates: 3)]),
    );
    final goal = w.packGoals.single;
    expect(goal.releaseId, 'hell-2026');
    expect(goal.name, 'Eine höllische Herausforderung');
    expect(goal.goalMeters, 100000);
    expect(goal.meters, 100000);
    expect(goal.contributionMeters, 1200);
    expect(goal.contributors, 7);
    expect(goal.reached, isTrue);
    expect(goal.eligible, isTrue);
    expect(goal.crateCount, 3);
    expect(goal.crates, 3);
    expect(w.progress.crates, 0);
    expect(w.progress.packCrates, 3);
    expect(w.progress.waiting, 3);
    expect(crateWaiting(w), isTrue);

    final old = _wardrobe()..remove('packGoals');
    jsonMap(old['progress']).remove('packCrates');
    final older = Wardrobe.fromJson(old);
    expect(older.packGoals, isEmpty);
    expect(older.progress.packCrates, 0);
    expect(crateWaiting(older), isFalse);
  });

  testWidgets('pack goals require the server capability and duplicate crates', (
    tester,
  ) async {
    expect(packGoalsAvailable(await _signedIn()), isTrue);
    expect(
      packGoalsAvailable(
        await _signedIn(
          features: _features.where((f) => f != 'runnerPackGoals').toList(),
        ),
      ),
      isFalse,
    );
    expect(
      packGoalsAvailable(
        await _signedIn(
          features: _features.where((f) => f != 'runnerDupes').toList(),
        ),
      ),
      isFalse,
    );
  });

  testWidgets(
    'opening a set crate sends its release rather than a chosen pool',
    (tester) async {
      final requests = <http.Request>[];
      final controller = await _signedIn(
        handle: (request) {
          if (!_path(request).endsWith('/games/runner/crates')) return null;
          requests.add(request);
          return Future.value(jsonResponse(_opening(_wardrobe())));
        },
      );
      await openCrate(
        controller,
        key: 'pack-opening-test',
        dupes: true,
        packId: 'hell-2026',
        target: 'play:unrelated',
      );
      expect(jsonDecode(requests.single.body), {
        'dupes': true,
        'crate': 'pack',
        'packId': 'hell-2026',
        'roles': true,
      });
      expect(requests.single.headers['Idempotency-Key'], 'pack-opening-test');
    },
  );

  testWidgets(
    'active goals show progress and only earned set crates can open',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      PackGoal? selected;
      final active = PackGoal.fromJson(_goal());
      final ready = PackGoal.fromJson(
        _goal(
          id: 'romeo-julia-2026',
          name: 'Romeo und Julia',
          reached: true,
          meters: 100000,
          crates: 3,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(
            body: PackGoalsCard(
              goals: [active, ready],
              onOpen: (goal) => selected = goal,
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('pack-goal-hell-2026')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pack-goal-romeo-julia-2026')),
        findsOneWidget,
      );
      expect(find.text('Eine höllische Herausforderung'), findsOneWidget);
      expect(find.text('Romeo und Julia'), findsOneWidget);
      final progress = tester.widgetList<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(progress.any((bar) => bar.value == .32), isTrue);
      final pendingButton = find.byKey(const ValueKey('open-pack-hell-2026'));
      if (pendingButton.evaluate().isNotEmpty) {
        expect(
          tester.widget<ButtonStyleButton>(pendingButton).onPressed,
          isNull,
        );
      }
      await tester.tap(
        find.byKey(const ValueKey('open-pack-romeo-julia-2026')),
      );
      expect(selected, same(ready));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a lost reply retries the same set crate, then next uses a new key',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final requests = <http.Request>[];
      final controller = await _signedIn(
        handle: (request) {
          if (!_path(request).endsWith('/games/runner/crates')) return null;
          requests.add(request);
          if (requests.length == 1) {
            return Future.error(http.ClientException('Reply lost'));
          }
          return Future.value(
            jsonResponse(
              _opening(
                _wardrobe(
                  goals: [
                    _goal(
                      reached: true,
                      meters: 100000,
                      crates: requests.length == 2 ? 1 : 0,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
      final before = Wardrobe.fromJson(
        _wardrobe(goals: [_goal(reached: true, meters: 100000, crates: 2)]),
      );
      final sound = _Sound();
      addTearDown(sound.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: CrateOpeningPage(
            controller: controller,
            wardrobe: before,
            sound: sound,
            packGoal: before.packGoals.single,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(requests, hasLength(1));
      expect(find.text('Erneut versuchen'), findsOneWidget);
      await tester.tap(find.text('Erneut versuchen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(requests, hasLength(2));
      final firstKey = requests[0].headers['Idempotency-Key'];
      expect(firstKey, isNotEmpty);
      expect(requests[1].headers['Idempotency-Key'], firstKey);
      expect(jsonDecode(requests[1].body), jsonDecode(requests[0].body));
      expect(jsonMap(jsonDecode(requests[1].body))['packId'], 'hell-2026');

      await tester.tapAt(const Offset(400, 200));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Nächste Kiste (1)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(requests, hasLength(3));
      expect(requests[2].headers['Idempotency-Key'], isNot(firstKey));
      expect(jsonMap(jsonDecode(requests[2].body))['packId'], 'hell-2026');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'next set crate never switches to a different release or own pool',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final before = Wardrobe.fromJson(
        _wardrobe(goals: [_goal(reached: true, meters: 100000, crates: 1)]),
      );
      final after = _wardrobe(
        ownCrates: 8,
        goals: [
          _goal(reached: true, meters: 100000),
          _goal(
            id: 'romeo-julia-2026',
            name: 'Romeo und Julia',
            reached: true,
            meters: 100000,
            crates: 3,
          ),
        ],
      );
      final controller = await _signedIn();
      final sound = _Sound();
      addTearDown(sound.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: CrateOpeningPage(
            controller: controller,
            wardrobe: before,
            sound: sound,
            packGoal: before.packGoals.single,
            open: () async => CrateOpening.fromJson(_opening(after)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.text('Set-Kiste · Eine höllische Herausforderung'),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(400, 200));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Nächste Kiste'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('unavailable rewards do not erase a recorded contribution', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final contributed = PackGoal.fromJson(
      _goal(reached: true, meters: 100000)..['eligible'] = false,
    );
    final didNotContribute = PackGoal.fromJson(
      _goal(
        id: 'romeo-julia-2026',
        name: 'Romeo und Julia',
        reached: true,
        meters: 100000,
        own: 0,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PackGoalsCard(goals: [contributed, didNotContribute]),
        ),
      ),
    );
    await tester.tap(find.byKey(const PageStorageKey('pack-completed-goals')));
    await tester.pumpAndSettle();
    final ownGoal = find.byKey(const ValueKey('pack-goal-hell-2026'));
    expect(
      find.descendant(
        of: ownGoal,
        matching: find.text(
          'Für dieses abgeschlossene Ziel sind keine Set-Kisten verfügbar.',
        ),
      ),
      findsOneWidget,
    );
    const noContribution =
        'Für dieses abgeschlossene Ziel ist kein eigener Beitrag erfasst.';
    expect(
      find.descendant(of: ownGoal, matching: find.text(noContribution)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pack-goal-romeo-julia-2026')),
        matching: find.text(noContribution),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'completed goals collapse while active goals and rewards stay visible',
    (tester) async {
      tester.view.physicalSize = const Size(390, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final active = PackGoal.fromJson(_goal());
      final awaiting = PackGoal.fromJson(
        _goal(
          id: 'romeo-julia-2026',
          name: 'Romeo und Julia',
          reached: true,
          meters: 100000,
          crates: 3,
        ),
      );
      final completed = PackGoal.fromJson(
        _goal(
          id: 'archive-2026',
          name: 'Archivstück',
          reached: true,
          meters: 100000,
          own: 4200,
        )..['eligible'] = false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PackGoalsCard(
              // Old completed entries can precede current goals in the response.
              goals: [completed, active, awaiting],
              onOpen: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('Eine höllische Herausforderung'), findsOneWidget);
      expect(find.text('Romeo und Julia'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('open-pack-romeo-julia-2026')),
        findsOneWidget,
      );
      expect(find.text('Abgeschlossene Ziele'), findsOneWidget);
      expect(find.text('Archivstück'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Eine höllische Herausforderung')).dy,
        lessThan(tester.getTopLeft(find.text('Abgeschlossene Ziele')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Romeo und Julia')).dy,
        lessThan(tester.getTopLeft(find.text('Abgeschlossene Ziele')).dy),
      );

      await tester.tap(
        find.byKey(const PageStorageKey('pack-completed-goals')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Archivstück'), findsOneWidget);
      final history = find.byKey(const ValueKey('pack-goal-archive-2026'));
      expect(
        find.descendant(of: history, matching: find.textContaining('4,2 km')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: history,
          matching: find.text(
            'Für dieses abgeschlossene Ziel sind keine Set-Kisten verfügbar.',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
