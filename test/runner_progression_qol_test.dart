import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/crate_choice.dart';
import 'package:theater_app/features/games/ui/crate_opening.dart';
import 'package:theater_app/features/games/ui/gala.dart';
import 'package:theater_app/features/games/ui/missions_card.dart';
import 'package:theater_app/features/games/ui/next_drop.dart';
import 'package:theater_app/features/games/ui/runner_weekly.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

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
  'runnerCratePoints',
  'runnerCrateTargets',
  'runnerGageCrates',
  'runnerUniqueFigures',
  'runnerMonthlyGala',
  'runnerWeekly',
  'runnerWeeklyRewards',
];

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<AppController> _signedIn(
  Future<http.Response>? Function(http.Request) handle, {
  List<String> features = _features,
  DateTime? now,
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = handle;
  final controller = now == null
      ? server.controller()
      : AppController(
          apiClient: ApiClient(client: MockClient(server.handle)),
          localStore: MemoryLocalStore(),
          credentialStore: MemoryCredentialStore(),
          clock: () => now,
        );
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

JsonMap _item(
  String id,
  String kind,
  String name,
  String rarity, [
  JsonMap extra = const {},
]) => {
  'id': id,
  'kind': kind,
  'name': name,
  'rarity': rarity,
  'rarities': [rarity],
  ...extra,
};

JsonMap _wardrobeJson({
  int crates = 2,
  int missionCrates = 0,
  int weeklyCrates = 0,
  int gage = 60,
  List<String> owned = const ['c0', 'b0', 'o0', 'f0', 't1', 't2'],
  List<String> shiny = const [],
  List<JsonMap> trades = const [
    {'from': 'hellblau', 'to': 'gold', 'cost': 120},
  ],
  int? crateGage = 50,
  int creepshowOwned = 2,
  int creepshowTotal = 3,
  int uniqueHave = 2,
  int uniqueTotal = 3,
  bool uniqueUnlocked = false,
  JsonMap? gala,
}) => {
  'progress': {
    'meters': 7400,
    'earned': 2,
    'opened': 2 - crates,
    'crates': crates,
    'missionCrates': missionCrates,
    'weeklyCrates': weeklyCrates,
    'galaCrates': gala?['crates'] ?? 0,
    'previousAt': 6300,
    'nextAt': 9720,
    'poolSize': 4,
    'complete': false,
    'dupes': true,
    'unit': 'points',
  },
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {
        'id': 'hellblau',
        'name': 'Hellblau',
        'color': '#5E98D9',
        'weight': 45,
        'gage': 10,
      },
      {
        'id': 'gold',
        'name': 'Gold',
        'color': '#E4AE39',
        'weight': 1.5,
        'gage': 40,
      },
    ],
    'departments': [],
    'dupes': {
      'shinyChance': {'costume': .05, 'targeted': .03, 'mission': .05},
      'crateGage': ?crateGage,
    },
    'items': [
      _item('c0', 'character', 'Engel Logge', 'hellblau', {'default': true}),
      _item('b0', 'backdrop', 'Bühnenwand', 'hellblau', {'default': true}),
      _item('o0', 'obstacles', 'Requisitenlager', 'hellblau', {
        'default': true,
      }),
      _item('f0', 'fx', 'Ohne Effekt', 'hellblau', {'default': true}),
      _item('t1', 'character', 'Florian', 'hellblau', {'role': 'Lichttechnik'}),
      _item('t2', 'character', 'Lukas', 'hellblau', {'role': 'Tontechnik'}),
      _item('lucy', 'character', 'Elena', 'gold', {
        'role': 'Lucy',
        'play': 'Creepshow',
        'year': 2026,
        'placeholder': true,
      }),
      _item('mina', 'character', 'Mina', 'hellblau', {
        'role': 'Mina',
        'play': 'Creepshow',
        'year': 2026,
      }),
      _item('ren', 'character', 'Ren', 'hellblau', {
        'role': 'Ren',
        'play': 'Creepshow',
        'year': 2026,
      }),
    ],
  },
  'owned': owned,
  'shiny': shiny,
  'gage': {'balance': gage, 'earned': gage},
  'trades': trades,
  'collection': {'owned': owned.length - 4, 'total': 5, 'shiny': shiny.length},
  'uniqueFigures': {
    'plays': [
      {
        'play': 'Creepshow',
        'year': 2026,
        'have': uniqueHave,
        'total': uniqueTotal,
        'unlocked': uniqueUnlocked,
        if (uniqueUnlocked) 'itemId': 'u-creep',
        if (uniqueUnlocked) 'name': 'Graf Nebel',
      },
    ],
    'unseen': <String>[],
  },
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'crateTargets': [
    {
      'id': 'random',
      'kind': 'random',
      'name': 'Zufallskiste',
      'animation': 'burst',
      'owned': owned.length - 4,
      'total': 5,
      'complete': false,
      'available': true,
      'shinyChance': .05,
      'odds': [
        {'rarity': 'hellblau', 'chance': .66},
        {'rarity': 'gold', 'chance': .34},
      ],
    },
    {
      'id': 'tech',
      'kind': 'tech',
      'name': 'Technik-Kiste',
      'animation': 'flightcase',
      'owned': 2,
      'total': 2,
      'complete': true,
      'available': true,
      'shinyChance': .03,
      'odds': [
        {'rarity': 'hellblau', 'chance': 1.0},
      ],
    },
    {
      'id': 'play:creepshow',
      'kind': 'play',
      'name': 'Creepshow',
      'play': 'Creepshow',
      'year': 2026,
      'animation': 'maw',
      'owned': creepshowOwned,
      'total': creepshowTotal,
      'complete': creepshowOwned >= creepshowTotal,
      'available': true,
      'shinyChance': .03,
      'odds': [
        {'rarity': 'hellblau', 'chance': .66},
        {'rarity': 'gold', 'chance': .34},
      ],
    },
  ],
  'gala': ?gala,
  'weekly': {
    'crates': weeklyCrates,
    'trophies': {'gold': 0, 'silver': 0, 'bronze': 0},
  },
};

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(800, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('NextDropCard contract', () {
    final now = DateTime.utc(2026, 11, 8, 16, 0);
    final drop = NextDrop(
      id: 'hell-2026',
      name: 'Höllische Herausforderung',
      startsAt: now,
      ready: true,
      serverNow: now,
      receivedAt: Duration.zero,
    );

    testWidgets('is tappable with chevron when onTap is provided', (
      tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        Scaffold(
          body: NextDropCard(
            drop: drop,
            clock: () => Duration.zero,
            onTap: () => taps++,
          ),
        ),
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('runner-next-drop-tap')));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('renders static card without InkWell when onTap is null', (
      tester,
    ) async {
      await _pump(
        tester,
        Scaffold(
          body: NextDropCard(drop: drop, clock: () => Duration.zero),
        ),
      );
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(find.byKey(const ValueKey('runner-next-drop-tap')), findsNothing);
    });
  });

  group('CrateOpeningPage & CrateTargetCard QoL', () {
    testWidgets(
      '1-tap skip from unboxing jumps straight to reveal, repeats same target and chains into waiting category',
      (tester) async {
        final opened = <JsonMap>[];
        var chooseCalls = 0;
        final controller = await _signedIn((request) {
          if (!_path(request).endsWith('/games/runner/crates')) return null;
          final body = jsonMap(jsonDecode(request.body));
          opened.add(body);
          final isMission = body['crate'] == 'mission';
          final after = _wardrobeJson(
            crates: isMission ? 0 : (opened.length == 1 ? 1 : 0),
            missionCrates: isMission ? 0 : 1,
            owned: const ['c0', 'b0', 'o0', 'f0', 't1', 't2', 'lucy', 'mina'],
            creepshowOwned: 2,
            creepshowTotal: 3,
            uniqueHave: 2,
            uniqueTotal: 3,
          );
          return Future.value(
            jsonResponse({
              'item': _item('lucy', 'character', 'Elena', 'gold', {
                'role': 'Lucy',
                'play': 'Creepshow',
                'year': 2026,
                'placeholder': true,
              }),
              'reel': List.filled(56, 'lucy'),
              'winnerIndex': 48,
              'outcome': {
                'type': 'new',
                'duplicate': false,
                'shiny': false,
                'rarity': 'gold',
                'crate': isMission ? 'mission' : 'costume',
                if (!isMission) 'target': body['target'] ?? 'random',
              },
              'wardrobe': after,
            }),
          );
        });
        final before = Wardrobe.fromJson(
          _wardrobeJson(crates: 2, missionCrates: 1),
        );
        final target = before.crateTarget('play:creepshow')!;
        final sound = _Sound();
        addTearDown(sound.dispose);
        await _pump(
          tester,
          CrateOpeningPage(
            controller: controller,
            wardrobe: before,
            sound: sound,
            target: target,
            chooseTarget: (_) async {
              chooseCalls++;
              return before.crateTarget('random');
            },
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          find.byKey(const ValueKey('crate-unboxing-play:creepshow')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('crate-skip-hint')), findsOneWidget);
        expect(find.text('Antippen zum Überspringen'), findsOneWidget);

        // One single tap during unboxing jumps straight to reveal.
        await tester.tapAt(const Offset(400, 300));
        await tester.pump();
        expect(find.byKey(const ValueKey('crate-won')), findsOneWidget);
        // Context chips show target, collection, and unique progress.
        expect(find.byKey(const ValueKey('crate-context')), findsOneWidget);
        expect(find.text('Creepshow 2026: 2/3'), findsOneWidget);
        expect(find.text('Sammlung: 4/5'), findsOneWidget);
        expect(
          find.text('Noch 1 Figur bis Unique (Creepshow 2026)'),
          findsOneWidget,
        );

        // Repeat same target without invoking chooseTarget!
        expect(find.byKey(const ValueKey('crate-next-same')), findsOneWidget);
        expect(find.text('Nächste Kiste (1)'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('crate-next-same')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(chooseCalls, 0);
        expect(opened.map((b) => b['target']), [
          'play:creepshow',
          'play:creepshow',
        ]);

        // Toggle "Schnell öffnen" during unboxing -> skips straight to reveal
        // and remembers the choice.
        await tester.tap(find.byKey(const ValueKey('crate-fast-open')));
        await tester.pump();
        expect(find.byKey(const ValueKey('crate-won')), findsOneWidget);
        expect(find.text('Schnell öffnen: An'), findsOneWidget);

        // No own crates left -> cross-category chain button offers Missionskiste!
        expect(
          find.byKey(const ValueKey('crate-next-category')),
          findsOneWidget,
        );
        expect(find.text('Nächste: Missionskiste'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('crate-next-category')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(opened.last['crate'], 'mission');
        // Fast open jumped directly to reveal without reel/unboxing!
        expect(find.byKey(const ValueKey('crate-won')), findsOneWidget);
        expect(find.byKey(const ValueKey('crate-next-category')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'gage duplicate reveal shows updated balance and affordable / missing offer',
      (tester) async {
        final controller = await _signedIn((_) => null);
        final wAffordable = Wardrobe.fromJson(
          _wardrobeJson(
            crates: 0,
            gage: 60,
            crateGage: 50,
            trades: const [
              {'from': 'hellblau', 'to': 'gold', 'cost': 120},
            ],
          ),
        );
        final item = wAffordable.catalog.item('t1')!;
        final sound = _Sound();
        addTearDown(sound.dispose);
        await _pump(
          tester,
          CrateOpeningPage(
            controller: controller,
            wardrobe: wAffordable,
            sound: sound,
            open: () async => CrateOpening(
              item: item,
              reel: List.filled(56, item),
              winnerIndex: 48,
              wardrobe: wAffordable,
              outcome: const CrateOutcome(
                type: 'gage',
                duplicate: true,
                gage: 10,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tapAt(const Offset(400, 200));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Kontostand: 60 Gage'), findsOneWidget);
        expect(find.text('Reicht für Kostümkiste'), findsOneWidget);

        // When not yet affordable: tells how much is missing for the cheapest offer.
        final wShort = Wardrobe.fromJson(
          _wardrobeJson(
            crates: 0,
            gage: 30,
            crateGage: 50,
            trades: const [
              {'from': 'hellblau', 'to': 'gold', 'cost': 120},
            ],
          ),
        );
        await tester.pumpWidget(const SizedBox());
        await _pump(
          tester,
          CrateOpeningPage(
            key: const ValueKey('short-gage'),
            controller: controller,
            wardrobe: wShort,
            sound: sound,
            open: () async => CrateOpening(
              item: item,
              reel: List.filled(56, item),
              winnerIndex: 48,
              wardrobe: wShort,
              outcome: const CrateOutcome(
                type: 'gage',
                duplicate: true,
                gage: 10,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tapAt(const Offset(400, 200));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Kontostand: 30 Gage'), findsOneWidget);
        expect(find.text('Noch 20 Gage bis Kostümkiste'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'CrateTargetCard shows odds legend and shiny progress on completed pools',
      (tester) async {
        final controller = await _signedIn((_) => null);
        final partialShiny = Wardrobe.fromJson(
          _wardrobeJson(shiny: const ['t1']),
        );
        final fullShiny = Wardrobe.fromJson(
          _wardrobeJson(shiny: const ['t1', 't2']),
        );
        await _pump(
          tester,
          Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  SizedBox(
                    width: 240,
                    child: CrateTargetCard(
                      target: partialShiny.crateTarget('play:creepshow')!,
                      wardrobe: partialShiny,
                      controller: controller,
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    child: CrateTargetCard(
                      target: partialShiny.crateTarget('tech')!,
                      wardrobe: partialShiny,
                      controller: controller,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('crate-target-odds-play:creepshow')),
          findsOneWidget,
        );
        expect(find.text('Hellblau 66 %'), findsOneWidget);
        expect(find.text('Gold 34 %'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('crate-target-shiny-tech')),
          findsOneWidget,
        );
        expect(find.text('Glanz: 1/2'), findsOneWidget);

        await _pump(
          tester,
          Scaffold(
            body: SizedBox(
              width: 240,
              child: CrateTargetCard(
                target: fullShiny.crateTarget('tech')!,
                wardrobe: fullShiny,
                controller: controller,
              ),
            ),
          ),
        );
        expect(find.text('Glanz: 2/2 komplett (nur noch Gage)'), findsOneWidget);
      },
    );
  });

  group('DailyMissionsCard QoL', () {
    test('missionResetCountdown handles Berlin midnight and DST shifts', () {
      // Summer time (UTC+2): 18:45 Berlin = 16:45 UTC -> 5h 15m left.
      expect(
        missionResetCountdown(DateTime.utc(2026, 7, 10, 16, 45)),
        'noch 5 Std. 15 Min.',
      );
      // Winter time (UTC+1): 23:40 Berlin = 22:40 UTC -> 20 Min. left.
      expect(
        missionResetCountdown(DateTime.utc(2026, 11, 10, 22, 40)),
        'noch 20 Min.',
      );
      // Fall DST Sunday (2026-10-25, 25-hour day): 00:30 CEST (22:30 UTC on Oct 24)
      // -> 24h 30m until 2026-10-26 00:00 CET (2026-10-25 23:00 UTC).
      expect(
        missionResetCountdown(DateTime.utc(2026, 10, 24, 22, 30)),
        'noch 24 Std. 30 Min.',
      );
    });

    testWidgets(
      'shows reset countdown, perRun vs cumulative scopes, reroll progress warning and retry on load error',
      (tester) async {
        var failMissions = true;
        var rerolls = 0;
        final controller = await _signedIn(
          (request) {
            final p = _path(request);
            if (p.endsWith('/games/runner/missions')) {
              if (failMissions) {
                return Future.value(jsonResponse({'error': 'offline'}, 503));
              }
              return Future.value(
                jsonResponse({
                  'day': '2026-10-24',
                  'rerollAvailable': true,
                  'allDone': false,
                  'crate': {'earned': false, 'shinyChance': 0.05},
                  'missions': [
                    {
                      'slot': 'easy',
                      'type': 'distance',
                      'target': 300,
                      'progress': 120,
                      'done': false,
                      'reward': 450,
                      'rewardUnit': 'points',
                      'text': 'Lauf 300 m in einem Durchgang',
                      'unit': 'm',
                      'scope': 'run',
                    },
                    {
                      'slot': 'medium',
                      'type': 'dailyDistance',
                      'target': 900,
                      'progress': 250,
                      'done': false,
                      'reward': 900,
                      'rewardUnit': 'points',
                      'text': 'Lauf heute insgesamt 900 m',
                      'unit': 'm',
                      'scope': 'day',
                    },
                    {
                      'slot': 'hard',
                      'type': 'points',
                      'target': 500,
                      'progress': 0,
                      'done': false,
                      'reward': 1500,
                      'rewardUnit': 'points',
                      'text': 'Hol 500 Punkte in einem Lauf',
                      'unit': 'Punkte',
                      'scope': 'run',
                    },
                  ],
                }),
              );
            }
            if (p.endsWith('/games/runner/missions/reroll')) {
              rerolls++;
              return Future.value(
                jsonResponse({
                  'day': '2026-10-24',
                  'rerollAvailable': false,
                  'allDone': false,
                  'crate': {'earned': false, 'shinyChance': 0.05},
                  'missions': [
                    {
                      'slot': 'easy',
                      'type': 'ground',
                      'target': 50,
                      'progress': 0,
                      'done': false,
                      'reward': 450,
                      'rewardUnit': 'points',
                      'text': 'Bleib 50 m am Boden in einem Lauf',
                      'unit': 'm',
                      'scope': 'run',
                      'rerolled': true,
                    },
                  ],
                }),
              );
            }
            return null;
          },
          now: DateTime.utc(2026, 7, 10, 16, 45),
        );

        await _pump(
          tester,
          Scaffold(body: DailyMissionsCard(controller: controller)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('missions-reset')), findsOneWidget);
        expect(find.text('Reset: noch 5 Std. 15 Min.'), findsOneWidget);
        expect(find.byKey(const ValueKey('missions-retry')), findsOneWidget);

        // Retry recovers cleanly.
        failMissions = false;
        await tester.tap(find.byKey(const ValueKey('missions-retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('missions-retry')), findsNothing);
        expect(find.text('In einem Lauf · Bester: 120 m'), findsOneWidget);
        expect(find.text('Heute gesamt'), findsOneWidget);
        expect(find.text('In einem Lauf'), findsOneWidget);

        // Reroll on mission with progress warns and lets user cancel cleanly.
        await tester.tap(find.byKey(const ValueKey('mission-reroll-easy')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('mission-reroll-confirm')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('mission-reroll-confirm')),
            matching: find.textContaining('120/300 m'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('geht dabei verloren'), findsOneWidget);
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        expect(rerolls, 0);

        // Confirming executes the reroll.
        await tester.tap(find.byKey(const ValueKey('mission-reroll-easy')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('mission-reroll-confirm-ok')),
        );
        await tester.pumpAndSettle();
        expect(rerolls, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('RunnerWeeklyScreen QoL', () {
    JsonMap longWeek({JsonMap? lastWeek}) => {
      'week': '2026-W37',
      'seed': 31415,
      'startsAt': '2026-09-06T22:00:00.000Z',
      'endsAt': '2026-09-13T22:00:00.000Z',
      'attempts': {'used': 2, 'max': 3},
      'best': {'score': 400, 'meters': 350},
      'leaderboard': [
        for (var i = 1; i <= 15; i++)
          {
            'rank': i,
            'personId': i == 13 ? 3 : 100 + i,
            'name': i == 13 ? 'Testmitglied' : 'Spieler $i',
            'score': 1000 - i * 40,
            'meters': 950 - i * 40,
            'at': '2026-09-10T18:00:00.000Z',
            'me': i == 13,
            'trophies': {'gold': 0, 'silver': 0, 'bronze': 0},
          },
      ],
      'ghosts': <Object?>[],
      'lastWeek': lastWeek,
      'trophies': {'gold': 0, 'silver': 0, 'bronze': 0},
    };

    testWidgets(
      'folds ranking after 10 with pinned own row, jump button, gap and direct Wochenkiste open on tab 1',
      (tester) async {
        final calls = <String>[];
        final controller = await _signedIn((request) {
          final p = _path(request);
          if (!p.contains('/games/runner/')) return null;
          calls.add('${request.method} ${p.split('/games/runner/').last}');
          if (p.endsWith('/weekly')) {
            return Future.value(
              jsonResponse(
                longWeek(
                  lastWeek: {
                    'week': '2026-W36',
                    'rank': 2,
                    'score': 640,
                    'gage': 50,
                    'trophy': 'silver',
                    'crates': 1,
                  },
                ),
              ),
            );
          }
          if (p.endsWith('/wardrobe')) {
            return Future.value(jsonResponse(_wardrobeJson(weeklyCrates: 1)));
          }
          return Future.value(jsonResponse({'ok': true}));
        });
        final sound = _Sound();
        addTearDown(sound.dispose);
        await _pump(
          tester,
          RunnerWeeklyScreen(controller: controller, sound: sound),
          size: const Size(420, 900),
        );
        await tester.pumpAndSettle();

        // Not auto-marked seen on load.
        expect(calls, isNot(contains('PUT weekly/seen')));
        expect(
          find.byKey(const ValueKey('weekly-reward-open-crate')),
          findsOneWidget,
        );

        // Scroll down to the ranking card in the ListView.
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('weekly-ranking-all')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        // Ranking folds after rank 10, pins own row (#13) and shows gap to #12.
        expect(find.text('Spieler 10'), findsOneWidget);
        expect(find.text('Spieler 11'), findsNothing);
        expect(find.text('Testmitglied'), findsOneWidget);
        expect(find.byKey(const ValueKey('weekly-rank-gap')), findsOneWidget);
        expect(find.text('Noch 41 Punkte bis Platz 12'), findsOneWidget);
        expect(find.text('Alle 15 anzeigen'), findsOneWidget);

        // Jump to own rank expands list and reveals rank 12 beside own row.
        final jump = find.byKey(const ValueKey('weekly-jump-own'));
        await tester.ensureVisible(jump);
        await tester.tap(jump);
        await tester.pumpAndSettle();
        expect(find.text('Spieler 12'), findsOneWidget);
        expect(find.text('Weniger anzeigen'), findsOneWidget);

        // Tapping "Wochenkiste öffnen" marks reward seen and opens Wardrobe on Kisten tab (1).
        final openCrate = find.byKey(
          const ValueKey('weekly-reward-open-crate'),
        );
        await tester.scrollUntilVisible(
          openCrate,
          -300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(openCrate);
        await tester.pumpAndSettle();
        expect(calls, contains('PUT weekly/seen'));
        // Wardrobe opened directly on Tab 1 ("Kisten") with ready Wochenkiste!
        expect(
          find.byKey(const ValueKey('wardrobe-ready-weekly')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('GalaCelebration QoL', () {
    Future<List<RunnerSfx>> runGala(
      WidgetTester tester, {
      required JsonMap? own,
      required int crates,
      String? expectedButton,
    }) async {
      final controller = await _signedIn((request) {
        final p = _path(request);
        if (p.endsWith('/games/runner/gala')) {
          return Future.value(
            jsonResponse({
              'gala': {
                'month': '2026-10',
                'monthName': 'Oktober',
                'opensAt': '2026-11-01T09:00:00.000Z',
                'players': 5,
                'podium': [
                  {
                    'rank': 1,
                    'name': 'Anna',
                    'score': 1400,
                    'trophy': 'gold',
                    'me': own?['rank'] == 1,
                  },
                ],
                'own': own,
              },
            }),
          );
        }
        if (p.endsWith('/games/runner/gala/seen')) {
          return Future.value(
            jsonResponse(
              _wardrobeJson(
                gala: {
                  'crates': crates,
                  'unseen': null,
                  'trophies': const <JsonMap>[],
                },
              ),
            ),
          );
        }
        return null;
      });
      final w = Wardrobe.fromJson(
        _wardrobeJson(
          gala: {
            'crates': crates,
            'unseen': '2026-10',
            'trophies': const <JsonMap>[],
          },
        ),
      );
      final sound = _Sound();
      addTearDown(sound.dispose);
      await _pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => celebrateGala(
                context,
                controller: controller,
                wardrobe: w,
                sound: sound,
                onChanged: (_) {},
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      if (expectedButton != null) {
        expect(find.text(expectedButton), findsOneWidget);
      }
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byKey(const ValueKey('gala-celebration-close')));
      await tester.pumpAndSettle();
      return sound.played;
    }

    testWidgets(
      'shows crate count in button and plays jackpot only on placement/prize',
      (tester) async {
        // 3 crates (rank 1): "3 Kisten öffnen" + jackpot sound.
        final podiumSound = await runGala(
          tester,
          own: {
            'rank': 1,
            'score': 1400,
            'prize': 'gold',
            'crates': 3,
            'gage': 0,
            'trophy': 'gold',
          },
          crates: 3,
          expectedButton: '3 Kisten öffnen',
        );
        expect(podiumSound, [RunnerSfx.jackpot]);

        // 1 crate (climber): "Kiste öffnen" + jackpot sound.
        final singleSound = await runGala(
          tester,
          own: {
            'rank': 5,
            'score': 900,
            'prize': 'climber',
            'crates': 1,
            'gage': 0,
            'previous': 200,
          },
          crates: 1,
          expectedButton: 'Kiste öffnen',
        );
        expect(singleSound, [RunnerSfx.jackpot]);

        // Applause (Gage only): softer reveal sound, no jackpot.
        final applauseSound = await runGala(
          tester,
          own: {
            'rank': 6,
            'score': 500,
            'prize': 'applause',
            'crates': 0,
            'gage': 50,
          },
          crates: 0,
        );
        expect(applauseSound, [RunnerSfx.reveal]);

        // Not on the list: silent (no jackpot!).
        final unplacedSound = await runGala(tester, own: null, crates: 0);
        expect(unplacedSound, isEmpty);
      },
    );
  });
}
