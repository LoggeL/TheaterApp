import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/missions_api.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/crate_choice.dart';
import 'package:theater_app/features/games/ui/missions_card.dart';
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

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerMissions',
  'runnerRoleFigures',
  'runnerCrateTargets',
];

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<AppController> _signedIn(
  Future<http.Response>? Function(http.Request) handle,
) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': _features};
  server.override = handle;
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  await tester.pump();
  await tester.pump();
}

JsonMap _wardrobeJson({
  List<String> owned = const ['c0', 'b0', 'o0', 'f0'],
  String? lockHint,
  String? lockDetail,
  bool generalCrateOnly = true,
  int gage = 500,
}) => {
  'roleFigures': true,
  'progress': {
    'meters': 500,
    'earned': 0,
    'opened': 0,
    'crates': 0,
    'previousAt': 0,
    'nextAt': 3000,
    'poolSize': 2,
    'complete': false,
    'dupes': true,
    'missionCrates': 0,
    'unit': 'points',
  },
  'gage': {'balance': gage, 'earned': gage},
  'trades': [
    {'from': 'rot', 'to': 'gold', 'cost': 400},
  ],
  'crateTargets': [
    {
      'id': 'random',
      'kind': 'random',
      'name': 'Zufallskiste',
      'owned': 0,
      'total': 3,
      'locked': 0,
      'complete': false,
      'available': true,
      'shinyChance': 0.05,
      'odds': [],
    },
    {
      'id': 'play:creepshow',
      'kind': 'play',
      'name': 'Creepshow',
      'play': 'Creepshow',
      'year': 2026,
      'owned': 0,
      'total': 1,
      'locked': 0,
      'complete': false,
      'available': true,
      'shinyChance': 0.03,
      'odds': [],
    },
  ],
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'dupes': {
      'shinyChance': {'costume': 0.05, 'targeted': 0.03, 'mission': 0.05},
      'tradeDupes': 5,
      'buyDupes': 10,
      'crateGage': 50,
    },
    'rarities': [
      {'id': 'hellblau', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 55, 'gage': 10},
      {
        'id': 'legacy',
        'name': 'Legacy',
        'color': '#A47A4B',
        'weight': 21,
        'gage': 15,
        'requires': {'rarity': 'hellblau', 'kind': 'character', 'count': 10},
        'hint': 'Sammle 10 hellblaue Figuren',
      },
      {'id': 'pink', 'name': 'Pink', 'color': '#D32CE6', 'weight': 12, 'gage': 40},
      {
        'id': 'gold',
        'name': 'Gold',
        'color': '#E4AE39',
        'weight': 1.5,
        'gage': 200,
        'buyable': false,
      },
    ],
    'departments': [],
    'items': [
      {'id': 'c0', 'kind': 'character', 'name': 'Engel Logge', 'rarity': 'hellblau', 'default': true},
      {'id': 'b0', 'kind': 'backdrop', 'name': 'Bühne', 'rarity': 'hellblau', 'default': true},
      {'id': 'o0', 'kind': 'obstacles', 'name': 'Lager', 'rarity': 'hellblau', 'default': true},
      {'id': 'f0', 'kind': 'fx', 'name': 'Ohne', 'rarity': 'hellblau', 'default': true},
      {
        'id': 'character.regular',
        'kind': 'character',
        'name': 'Elena',
        'role': 'Lucy',
        'play': 'Creepshow',
        'year': 2026,
        'rarity': 'hellblau',
        'personId': 6,
      },
      {
        'id': 'character.special-pink',
        'kind': 'character',
        'name': 'Yunus',
        'role': 'Dr. Düsterwald (Explosion)',
        'play': 'Creepshow',
        'year': 2026,
        'rarity': 'pink',
        'personId': 2,
        'generalCrateOnly': generalCrateOnly,
        'lockHint': ?lockHint,
        'lockDetail': ?lockDetail,
      },
      {
        'id': 'character.special-gold',
        'kind': 'character',
        'name': 'Elena',
        'role': 'Lucy im Bademantel',
        'play': 'Creepshow',
        'year': 2026,
        'rarity': 'gold',
        'personId': 6,
        'generalCrateOnly': generalCrateOnly,
        'lockHint': ?lockHint,
        'lockDetail': ?lockDetail,
      },
      {
        'id': 'character.special-legacy',
        'kind': 'character',
        'name': 'Theo',
        'role': 'Dorfbewohner',
        'play': 'Anno 1146',
        'year': 2025,
        'rarity': 'legacy',
        'personId': 48,
        'generalCrateOnly': generalCrateOnly,
        'lockHint': ?lockHint,
        'lockDetail': ?lockDetail,
      },
    ],
  },
  'lockedRarities': ['legacy'],
  'owned': owned,
  'selected': {'character': 'c0', 'backdrop': 'b0', 'obstacles': 'o0', 'fx': 'f0'},
  'stats': {'rounds': 3, 'best': 300, 'meters': 200},
};

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('WardrobeItem lock and generalCrateOnly rules', () {
    test('locked daily item suppresses buyCost and surfaces server hints until owned', () {
      final locked = Wardrobe.fromJson(
        _wardrobeJson(
          lockHint: 'Heute über Tagesmissionen',
          lockDetail: 'Heute exklusiv über alle drei Tagesmissionen freischaltbar.',
        ),
      );
      final pink = locked.catalog.item('character.special-pink')!;
      expect(pink.generalCrateOnly, isTrue);
      expect(locked.lockHint(pink), 'Heute über Tagesmissionen');
      expect(
        locked.lockDetail(pink),
        'Heute exklusiv über alle drei Tagesmissionen freischaltbar.',
      );
      expect(locked.buyCost(pink), isNull);

      final owned = Wardrobe.fromJson(
        _wardrobeJson(
          owned: const ['c0', 'b0', 'o0', 'f0', 'character.special-pink'],
          lockHint: 'Heute über Tagesmissionen',
        ),
      );
      final ownedPink = owned.catalog.item('character.special-pink')!;
      expect(owned.lockHint(ownedPink), isNull);
      expect(owned.lockDetail(ownedPink), isNull);

      final general = Wardrobe.fromJson(_wardrobeJson());
      final generalPink = general.catalog.item('character.special-pink')!;
      final generalGold = general.catalog.item('character.special-gold')!;
      expect(general.lockHint(generalPink), isNull);
      expect(general.buyCost(generalPink), 400);
      expect(general.buyCost(generalGold), isNull);
    });

    testWidgets('locked item shows lock hint in card & sheet, hides buy button & crate sources', (
      tester,
    ) async {
      final controller = await _signedIn((request) {
        if (_path(request).endsWith('/wardrobe')) {
          return Future.value(
            jsonResponse(
              _wardrobeJson(
                lockHint: 'Heute über Tagesmissionen',
                lockDetail:
                    'Heute exklusiv über alle drei Tagesmissionen freischaltbar – nicht in Kisten.',
              ),
            ),
          );
        }
        return null;
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final pinkCard = find.byKey(const ValueKey('wardrobe-character.special-pink'));
      expect(pinkCard, findsOneWidget);
      expect(
        find.descendant(of: pinkCard, matching: find.text('Heute über Tagesmissionen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('card-price-character.special-pink')),
        findsNothing,
      );
      // Only character.regular (100 G) is buyable; locked character.special-pink (400 G) is excluded.
      expect(find.text('Kaufbar (1)'), findsOneWidget);

      await tester.ensureVisible(pinkCard);
      await tester.tap(pinkCard);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Heute exklusiv über alle drei Tagesmissionen freischaltbar – nicht in Kisten.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('wardrobe-buy')), findsNothing);
      expect(find.byKey(const ValueKey('wardrobe-to-crates')), findsNothing);
      expect(find.byKey(const ValueKey('wardrobe-source')), findsNothing);
      Navigator.of(tester.element(find.text('Noch nicht gefunden'))).pop();
      await tester.pumpAndSettle();

      // Locked Legacy daily item suppresses rarity lockProgress while item lockHint is active.
      final legacyCard = find.byKey(const ValueKey('wardrobe-character.special-legacy'));
      await tester.ensureVisible(legacyCard);
      await tester.tap(legacyCard);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wardrobe-lock-progress')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unlocked generalCrateOnly item shows Zufallskiste and never play-specific crate', (
      tester,
    ) async {
      final controller = await _signedIn((request) {
        if (_path(request).endsWith('/wardrobe')) {
          return Future.value(jsonResponse(_wardrobeJson()));
        }
        return null;
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Both regular (100 G) and unlocked special-pink (400 G) are affordable with 500 G.
      expect(find.text('Kaufbar (2)'), findsOneWidget);

      final pinkCard = find.byKey(const ValueKey('wardrobe-character.special-pink'));
      await tester.ensureVisible(pinkCard);
      await tester.tap(pinkCard);
      await tester.pumpAndSettle();

      final sourceText = tester.widget<Text>(
        find.byKey(const ValueKey('wardrobe-source')),
      );
      expect(sourceText.data, contains('Zufallskiste'));
      expect(sourceText.data, isNot(contains('Kiste „Creepshow“')));
      expect(find.byKey(const ValueKey('wardrobe-buy')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const ValueKey('wardrobe-buy')))).pop();
      await tester.pumpAndSettle();

      // Gold generalCrateOnly item keeps standard Gold copy and Zufallskiste + Tauschvertrag only.
      final goldCard = find.byKey(const ValueKey('wardrobe-character.special-gold'));
      await tester.ensureVisible(goldCard);
      await tester.tap(goldCard);
      await tester.pumpAndSettle();

      final goldSource = tester.widget<Text>(
        find.byKey(const ValueKey('wardrobe-source')),
      );
      expect(goldSource.data, contains('Zufallskiste'));
      expect(goldSource.data, contains('Tauschvertrag'));
      expect(goldSource.data, isNot(contains('Kiste „Creepshow“')));
      expect(
        find.text('Gold gibt es nur aus Kisten und Tauschverträgen.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    test('crateTargetItems excludes generalCrateOnly from play crates and locked items from random', () {
      final locked = Wardrobe.fromJson(
        _wardrobeJson(lockHint: 'Heute über Tagesmissionen'),
      );
      final randomLocked = crateTargetItems(
        locked,
        locked.crateTarget('random')!,
      );
      expect(
        randomLocked.map((i) => i.id),
        ['character.regular'],
        reason: 'locked daily items must not count in random pool shiny totals',
      );
      final playLocked = crateTargetItems(
        locked,
        locked.crateTarget('play:creepshow')!,
      );
      expect(playLocked.map((i) => i.id), ['character.regular']);

      final unlocked = Wardrobe.fromJson(_wardrobeJson());
      final randomUnlocked = crateTargetItems(
        unlocked,
        unlocked.crateTarget('random')!,
      );
      expect(
        randomUnlocked.map((i) => i.id),
        containsAll([
          'character.regular',
          'character.special-pink',
          'character.special-gold',
          'character.special-legacy',
        ]),
      );
      final playUnlocked = crateTargetItems(
        unlocked,
        unlocked.crateTarget('play:creepshow')!,
      );
      expect(
        playUnlocked.map((i) => i.id),
        ['character.regular'],
        reason: 'generalCrateOnly items must never inflate play crate shiny totals',
      );
    });

    testWidgets('Gage trade remaining count ignores locked daily items', (
      tester,
    ) async {
      final raw = _wardrobeJson(
        lockHint: 'Heute über Tagesmissionen',
        gage: 500,
      );
      // Add one regular (non-locked) gold figure so exactly 1 tradeable gold item remains
      // alongside the locked character.special-gold.
      (raw['catalog'] as Map<String, Object?>)['items'] = [
        ...(raw['catalog'] as Map<String, Object?>)['items'] as List,
        {
          'id': 'character.regular-gold',
          'kind': 'character',
          'name': 'Louis',
          'role': 'Graf',
          'play': 'Creepshow',
          'year': 2026,
          'rarity': 'gold',
          'personId': 15,
          'image': '/games/runner/skins/louis.webp',
        },
      ];
      final controller = await _signedIn((request) {
        if (_path(request).endsWith('/wardrobe')) {
          return Future.value(jsonResponse(raw));
        }
        return null;
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound(), initialTab: 1),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.text('Tauschvertrag · noch 1 offen (garantiert!)'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('DailyMissionReward UI', () {
    testWidgets('DailyMissionsCard and MissionRunNote use server-driven daily reward copy', (
      tester,
    ) async {
      final controller = await _signedIn((_) => null);
      final openMissions = DailyMissions.fromJson({
        'day': '2026-12-01',
        'rerollAvailable': true,
        'allDone': false,
        'crate': {'earned': false, 'shinyChance': 0.05},
        'dailyReward': {
          'kind': 'item',
          'earned': false,
          'itemId': 'character.special-pink',
          'summary':
              'Alle drei an einem Tag: heute schaltest du das Tageskostüm statt einer Missionskiste frei.',
          'earnedSummary':
              'Alle drei geschafft – „Yunus als Dr. Düsterwald“ ist jetzt in deiner Garderobe.',
          'runNote':
              'Alle drei Tagesmissionen geschafft! Freigeschaltet: Yunus als Dr. Düsterwald – jetzt in deiner Garderobe.',
        },
        'missions': [
          {
            'slot': 'easy',
            'type': 'distance',
            'text': 'Lauf 100 m in einem Durchgang',
            'unit': 'm',
            'target': 100,
            'progress': 0,
            'done': false,
            'reward': 450,
            'rewardUnit': 'points',
          },
        ],
      });

      await _pump(
        tester,
        Scaffold(
          body: DailyMissionsCard(
            controller: controller,
            missions: openMissions,
          ),
        ),
      );
      expect(
        find.textContaining(
          'heute schaltest du das Tageskostüm statt einer Missionskiste frei.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Missionskiste dazu'), findsNothing);

      final doneMissions = DailyMissions.fromJson({
        'day': '2026-12-01',
        'rerollAvailable': false,
        'allDone': true,
        'crate': {'earned': false, 'shinyChance': 0.05},
        'dailyReward': {
          'kind': 'item',
          'earned': true,
          'itemId': 'character.special-pink',
          'name': 'Yunus',
          'earnedSummary':
              'Alle drei geschafft – „Yunus als Dr. Düsterwald“ ist jetzt in deiner Garderobe.',
          'runNote':
              'Alle drei Tagesmissionen geschafft! Freigeschaltet: Yunus als Dr. Düsterwald – jetzt in deiner Garderobe.',
        },
        'missions': [
          {
            'slot': 'easy',
            'type': 'distance',
            'text': 'Lauf 100 m in einem Durchgang',
            'unit': 'm',
            'target': 100,
            'progress': 100,
            'done': true,
            'justDone': true,
            'reward': 450,
            'rewardUnit': 'points',
          },
        ],
      });

      await _pump(
        tester,
        Scaffold(
          body: Column(
            children: [
              DailyMissionsCard(controller: controller, missions: doneMissions),
              MissionRunNote(doneMissions),
            ],
          ),
        ),
      );
      expect(
        find.text(
          'Alle drei geschafft – „Yunus als Dr. Düsterwald“ ist jetzt in deiner Garderobe.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Alle drei Tagesmissionen geschafft! Freigeschaltet: Yunus als Dr. Düsterwald – jetzt in deiner Garderobe.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Missionskiste wartet'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('StageRunnerScreen result hides Kiste öffnen when all three missions award a daily item', (
      tester,
    ) async {
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/leaderboard')) {
          return Future.value(
            jsonResponse({'players': 0, 'top': [], 'own': null}),
          );
        }
        if (path.endsWith('/wardrobe')) {
          return Future.value(jsonResponse(_wardrobeJson()));
        }
        if (path.endsWith('/missions')) {
          return Future.value(
            jsonResponse({
              'day': '2026-12-01',
              'rerollAvailable': false,
              'allDone': false,
              'crate': {'earned': false, 'shinyChance': 0.05},
              'dailyReward': {
                'kind': 'item',
                'earned': false,
                'itemId': 'character.special-pink',
                'summary': 'Alle drei an einem Tag: heute das Tageskostüm.',
              },
              'missions': [
                {
                  'slot': 'easy',
                  'type': 'distance',
                  'text': 'Lauf 1 m in einem Durchgang',
                  'unit': 'm',
                  'target': 1,
                  'progress': 0,
                  'done': false,
                  'reward': 450,
                  'rewardUnit': 'points',
                },
              ],
            }),
          );
        }
        if (path.endsWith('/rounds')) {
          return Future.value(jsonResponse({'roundId': 'r-daily'}));
        }
        if (path.endsWith('/scores')) {
          final body = jsonMap(jsonDecode(request.body));
          return Future.value(
            jsonResponse({
              'score': body['score'],
              'improved': false,
              'leaderboard': {'players': 0, 'top': [], 'own': null},
              'progress': {
                'meters': 500,
                'earned': 0,
                'opened': 0,
                'crates': 0,
                'previousAt': 0,
                'nextAt': 3000,
                'gained': 10,
                'missionBonus': 450,
                'missionCrates': 0,
                'newCrates': 0,
                'unit': 'points',
                'missions': {
                  'day': '2026-12-01',
                  'rerollAvailable': false,
                  'allDone': true,
                  'crate': {'earned': false, 'shinyChance': 0.05},
                  'dailyReward': {
                    'kind': 'item',
                    'earned': true,
                    'itemId': 'character.special-pink',
                    'name': 'Yunus',
                    'runNote':
                        'Alle drei Tagesmissionen geschafft! Freigeschaltet: Yunus – jetzt in deiner Garderobe.',
                  },
                  'missions': [
                    {
                      'slot': 'easy',
                      'type': 'distance',
                      'text': 'Lauf 1 m in einem Durchgang',
                      'unit': 'm',
                      'target': 1,
                      'progress': 1,
                      'done': true,
                      'justDone': true,
                      'reward': 450,
                      'rewardUnit': 'points',
                    },
                  ],
                },
              },
            }),
          );
        }
        return null;
      });
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
      await tester.tap(find.text('Vorhang auf'));
      for (
        var i = 0;
        i < 60 * 20 && find.text('Nochmal').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.text(
          'Alle drei Tagesmissionen geschafft! Freigeschaltet: Yunus – jetzt in deiner Garderobe.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('runner-result-open-crate')),
        findsNothing,
      );
      expect(sound.played, contains(RunnerSfx.jackpot));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
