import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/unique_figures.dart';
import 'package:theater_app/features/games/ui/wardrobe_cards.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// Unique figures (`runnerUniqueFigures`): one non-human character per play,
// unlocked by all of the play's role figures; "???" with the play's progress
// until then, a holographic card, a celebration once unlocked.

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

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerRoleFigures',
  'runnerUniqueFigures',
];

JsonMap _default(String id, String kind) => {
  'id': id,
  'kind': kind,
  'name': id,
  'rarity': 'hellblau',
  'rarities': ['hellblau'],
  'default': true,
};

JsonMap _figure(String id, String rarity, int personId) => {
  'id': id,
  'kind': 'character',
  'name': 'Person $personId',
  'rarity': rarity,
  'rarities': [rarity],
  'role': 'Rolle $id',
  'play': 'Creepshow',
  'year': 2026,
  'personId': personId,
};

const _kuschel = {
  'id': 'character.unique-captain-kuschel',
  'kind': 'character',
  'name': 'Captain Kuschel',
  'rarity': 'unique',
  'rarities': ['unique'],
  'unique': true,
  'unlock': {'play': 'Creepshow'},
  'role': 'Captain Kuschel',
  'play': 'Creepshow',
  'year': 2026,
  'rarityReason': 'Seit 2022 dabei.',
};

/// A wardrobe as a server with unique figures sends it: Creepshow with
/// three role figures; [unlocked] with Captain Kuschel unlocked ([unseen]:
/// not celebrated yet), else hidden with 2 of 3.
JsonMap _json({
  bool unlocked = false,
  bool unseen = true,
  bool withPlays = true,
  String worn = 'c0',
}) => {
  'progress': {
    'meters': 2900,
    'earned': 1,
    'opened': 1,
    'crates': 0,
    'previousAt': 2000,
    'nextAt': 4100,
    'poolSize': 1,
    'dupes': true,
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
        'gage': 200,
        'buyable': false,
      },
    ],
    'departments': [],
    'dupes': {
      'shinyChance': {'costume': .03},
      'tradeDupes': 5,
      'buyDupes': 10,
    },
    'items': [
      _default('c0', 'character'),
      _default('b0', 'backdrop'),
      _default('o0', 'obstacles'),
      _default('f0', 'fx'),
      _figure('r1', 'gold', 1),
      _figure('r2', 'hellblau', 2),
      _figure('r3', 'hellblau', 3),
    ],
    'rewards': [],
    'uniqueRarity': {
      'id': 'unique',
      'name': 'Unique',
      'color': '#B388FF',
      'style': 'holo',
    },
    'uniques': [if (unlocked) _kuschel],
  },
  'lockedRarities': [],
  'owned': [
    'c0',
    'b0',
    'o0',
    'f0',
    'r1',
    'r2',
    if (unlocked) ...['r3', _kuschel['id']],
  ],
  'selected': {
    'character': worn,
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'stats': {'rounds': 3, 'best': 100, 'meters': 2900},
  'shiny': [],
  'variants': [],
  'selectedVariants': {},
  'gage': {'balance': 0, 'earned': 0},
  'trades': [],
  'roleFigures': true,
  'uniqueFigures': {
    'plays': [
      if (withPlays)
        unlocked
            ? {
                'play': 'Creepshow',
                'year': 2026,
                'have': 3,
                'total': 3,
                'unlocked': true,
                'itemId': _kuschel['id'],
                'name': 'Captain Kuschel',
              }
            : {
                'play': 'Creepshow',
                'year': 2026,
                'have': 2,
                'total': 3,
                'unlocked': false,
                'hidden': true,
                'name': '???',
              },
    ],
    'unseen': [if (unlocked && unseen) _kuschel['id']],
  },
};

/// The figure across plays (from 0.11.5) as the server sends it: one entry
/// for Creepshow and Nexus, hidden with 23 of 40 role figures, or unlocked.
JsonMap _across({bool unlocked = false}) => {
  'play': 'Creepshow und Nexus',
  'plays': [
    {
      'play': 'Creepshow',
      'year': 2026,
      'have': unlocked ? 22 : 15,
      'total': 22,
    },
    {'play': 'Nexus', 'year': 2024, 'have': unlocked ? 18 : 8, 'total': 18},
  ],
  'have': unlocked ? 40 : 23,
  'total': 40,
  'unlocked': unlocked,
  if (unlocked) ...{
    'itemId': 'character.unique-captain-kuschel',
    'name': 'Captain Kuschel',
  } else ...{
    'hidden': true,
    'name': '???',
  },
};

/// [json] with the figure across plays added after the play's own one.
JsonMap _withAcross(JsonMap json, {bool unlocked = false}) {
  final figures = jsonMap(json['uniqueFigures']);
  return {
    ...json,
    'uniqueFigures': {
      ...figures,
      'plays': [...jsonList(figures['plays']), _across(unlocked: unlocked)],
    },
  };
}

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<AppController> _signedIn(
  Future<http.Response>? Function(http.Request) handle, {
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(WardrobePictures.clear);

  test('a unique figure: its own holographic look, never collectible', () {
    final w = Wardrobe.fromJson(
      _json(unlocked: true, worn: 'character.unique-captain-kuschel'),
    );
    final kuschel = w.catalog.item('character.unique-captain-kuschel')!;
    expect(kuschel.unique, isTrue);
    expect(w.catalog.rarityOf(kuschel).holo, isTrue);
    expect(w.catalog.rarityOf(kuschel).name, 'Unique');
    expect(w.catalog.uniques.map((i) => i.id), [kuschel.id]);
    // Not among what crates bring, not counted, not for sale.
    expect(w.catalog.collectible.contains(kuschel), isFalse);
    expect('${w.collected}/${w.collectible}', '3/3');
    expect(w.buyCost(kuschel), isNull);
    // Worn: the character itself, not "Captain Kuschel als Captain Kuschel".
    expect(w.wornCharacterName(), 'Captain Kuschel');
    expect(uniqueRoleLine(kuschel.role!), 'Unique · Creepshow 2026');
    expect(w.uniqueFigures!.plays.single.unlocked, isTrue);
    expect(w.uniqueFigures!.unseen, [kuschel.id]);
  });

  test('a hidden one has neither id nor name, even if a server sent one', () {
    final json = _json();
    final play = jsonMap(
      jsonList(jsonMap(json['uniqueFigures'])['plays']).single,
    );
    play['itemId'] = 'character.unique-captain-kuschel';
    play['name'] = 'Captain Kuschel';
    final w = Wardrobe.fromJson(json);
    final p = w.uniqueFigures!.plays.single;
    expect([p.unlocked, p.itemId, p.name], [false, null, '???']);
    expect(p.line, '2/3 Rollen aus Creepshow');
    expect(w.catalog.uniques, isEmpty);
    final standIn = uniqueStandIn(w.catalog, p);
    expect(w.owns(standIn), isFalse);
    expect(uniqueHint(w, standIn), '2/3 Rollen aus Creepshow');
  });

  test('the technician collection has its own progress and label', () {
    final p = UniqueFigureProgress.fromJson({
      'play': 'Technik',
      'allTechnicians': true,
      'have': 5,
      'total': 8,
      'unlocked': false,
      'plays': [
        {'play': 'Technik', 'have': 5, 'total': 8},
      ],
    })!;
    expect(p.allTechnicians, isTrue);
    expect(p.production, 'Technik');
    expect(p.line, '5/8 Techniker gesammelt');
    expect(
      uniqueRoleLine(const WardrobeRole('Adolph Kolping'), p),
      'Unique · Technik',
    );
    expect(
      UniqueFigureProgress.fromJson({'play': 'Creepshow'})!.allTechnicians,
      isFalse,
    );
  });

  test('across plays: one entry, the plays named together, per play too', () {
    final w = Wardrobe.fromJson(_withAcross(_json()));
    final [own, across] = w.uniqueFigures!.plays;
    // A single play as before: no parts.
    expect(
      [own.several, own.parts, own.line],
      [false, isEmpty, '2/3 Rollen aus Creepshow'],
    );
    expect(across.several, isTrue);
    expect([across.unlocked, across.itemId, across.name], [false, null, '???']);
    expect(across.year, isNull);
    expect(across.production, 'Creepshow und Nexus');
    expect(across.line, '23/40 Rollen aus Creepshow und Nexus');
    expect(across.parts.map((p) => p.line), [
      'Creepshow 2026: 15/22',
      'Nexus 2024: 8/18',
    ]);
    // Two hidden cards, each with its own way.
    final cards = uniqueCards(w);
    expect(cards.map((c) => c.id), [
      'unique-hidden:Creepshow 2026',
      'unique-hidden:Creepshow und Nexus',
    ]);
    expect(cards.map((c) => uniqueHint(w, c)), [
      '2/3 Rollen aus Creepshow',
      '23/40 Rollen aus Creepshow und Nexus',
    ]);
    expect(cards.every((c) => c.name == '???' && !w.owns(c)), isTrue);
    // Unlocked: its line names both plays, not only its own.
    final json = _withAcross(_json(), unlocked: true);
    final catalog = jsonMap(json['catalog']);
    json['catalog'] = {
      ...catalog,
      'uniques': [
        {
          ..._kuschel,
          'unlock': {
            'plays': ['Creepshow', 'Nexus'],
          },
        },
      ],
    };
    json['owned'] = [...jsonList(json['owned']), _kuschel['id']];
    final unlocked = Wardrobe.fromJson(json);
    final kuschel = unlocked.catalog.item('character.unique-captain-kuschel')!;
    final p = uniqueProgressOf(unlocked, kuschel)!;
    expect([p.unlocked, p.several], [true, true]);
    expect(uniqueHint(unlocked, kuschel), isNull);
    expect(uniqueRoleLine(kuschel.role!, p), 'Unique · Creepshow und Nexus');
    expect(uniqueRoleLine(kuschel.role!), 'Unique · Creepshow 2026');
  });

  test('older servers: no unique figures, nothing breaks', () {
    final json = _json()..remove('uniqueFigures');
    json['catalog'] = {...jsonMap(json['catalog'])}
      ..remove('uniques')
      ..remove('uniqueRarity');
    final w = Wardrobe.fromJson(json);
    expect(w.uniqueFigures, isNull);
    expect(w.catalog.uniqueRarity, isNull);
    expect(w.catalog.uniques, isEmpty);
  });

  group('the app asks for unique figures only when the server has them', () {
    for (final unique in [true, false]) {
      test('runnerUniqueFigures ${unique ? 'on' : 'off'}', () async {
        final requests = <(String, JsonMap)>[];
        final controller = await _signedIn((request) {
          final path = _path(request);
          if (!path.contains('/games/runner/')) return null;
          requests.add((
            '$path ${request.url.queryParameters}',
            request.body.isEmpty ? {} : jsonMap(jsonDecode(request.body)),
          ));
          final w = _json();
          final item = _figure('r3', 'hellblau', 3);
          return Future.value(
            jsonResponse(
              path.endsWith('/crates') || path.endsWith('/buy')
                  ? {
                      'item': item,
                      'reel': [for (var i = 0; i < 56; i++) item['id']],
                      'winnerIndex': 48,
                      'outcome': {'type': 'new'},
                      'wardrobe': w,
                    }
                  : w,
            ),
          );
        }, features: unique ? _features : _features.take(4).toList());
        expect(uniqueFiguresAvailable(controller), unique);
        final w = await loadWardrobe(controller);
        await openCrate(controller, dupes: true);
        await wearItem(controller, w.catalog.item('r2')!);
        await buyItem(controller, w.catalog.item('r2')!);
        await markEnsembleSeen(controller, 25);
        expect(
          requests[0].$1.endsWith(
            '/games/runner/wardrobe ${unique ? '{roles: 1, unique: 1}' : '{roles: 1}'}',
          ),
          isTrue,
          reason: requests[0].$1,
        );
        for (final (_, body) in requests.skip(1)) {
          expect(body['unique'], unique ? true : isNull, reason: '$body');
          expect(body['roles'], isTrue);
        }
      });
    }
  });

  group('the wardrobe', () {
    Future<List<(String, JsonMap)>> open(
      WidgetTester tester,
      JsonMap Function() json,
    ) async {
      final calls = <(String, JsonMap)>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.contains('/games/runner/skins/')) {
          return Future.value(http.Response('', 404));
        }
        if (path.contains('/games/runner/')) {
          if (request.method != 'GET') {
            calls.add((path, jsonMap(jsonDecode(request.body))));
          }
          if (path.endsWith('/unique/seen')) {
            return Future.value(
              jsonResponse(_json(unlocked: true, unseen: false)),
            );
          }
          return Future.value(jsonResponse(json()));
        }
        return null;
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);
      return calls;
    }

    const hidden = ValueKey('wardrobe-unique-hidden:Creepshow 2026');

    testWidgets('before: a holographic "???" card with the play\'s progress', (
      tester,
    ) async {
      await open(tester, _json);
      expect(
        find.byKey(const ValueKey('wardrobe-group-unique')),
        findsOneWidget,
      );
      final card = find.byKey(hidden);
      expect(card, findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.text('2/3 Rollen aus Creepshow'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('???')),
        findsWidgets,
      );
      expect(find.text('Captain Kuschel'), findsNothing);
      // Above the rarities of the draw.
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('wardrobe-group-unique')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('wardrobe-group-gold')))
              .dy,
        ),
      );
      expect(find.byKey(const ValueKey('unique-celebration')), findsNothing);
      // The details explain the way, no purchase.
      await tester.tap(card);
      await _settle(tester);
      expect(find.textContaining('nicht aus Kisten'), findsOneWidget);
      expect(find.byKey(const ValueKey('wardrobe-buy')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('across plays: "???" with the progress of both plays', (
      tester,
    ) async {
      await open(tester, () => _withAcross(_json()));
      const across = ValueKey('wardrobe-unique-hidden:Creepshow und Nexus');
      final card = find.byKey(across);
      expect(card, findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.text('23/40 Rollen aus Creepshow und Nexus'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('???')),
        findsWidgets,
      );
      expect(find.byKey(hidden), findsOneWidget);
      expect(find.text('Captain Kuschel'), findsNothing);
      expect(find.textContaining('Unique · Creepshow'), findsNothing);
      // The details: both plays, each with its progress.
      await tester.tap(card);
      await _settle(tester);
      expect(find.textContaining('alle Rollen dieser Stücke'), findsOneWidget);
      expect(
        find.text('Creepshow 2026: 15/22 · Nexus 2024: 8/18'),
        findsOneWidget,
      );
      expect(find.text('Captain Kuschel'), findsNothing);
      expect(find.byKey(const ValueKey('wardrobe-buy')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'all technicians: progress and details explain the collection',
      (tester) async {
        await open(tester, () {
          final json = _json();
          final p = jsonMap(
            jsonList(jsonMap(json['uniqueFigures'])['plays']).single,
          );
          p.addAll({
            'allTechnicians': true,
            'play': 'Technik',
            'year': null,
            'total': 4,
            'plays': [
              {'play': 'Technik', 'have': 2, 'total': 4},
            ],
          });
          json['uniqueFigures'] = {
            ...jsonMap(json['uniqueFigures']),
            'plays': [p],
          };
          return json;
        });
        final card = find.byKey(
          const ValueKey('wardrobe-unique-hidden:Technik'),
        );
        expect(card, findsOneWidget);
        expect(find.text('2/4 Techniker gesammelt'), findsOneWidget);
        await tester.tap(card);
        await _settle(tester);
        expect(find.textContaining('alle Techniker'), findsOneWidget);
        expect(find.textContaining('Rollen aus Creepshow'), findsNothing);
        expect(find.byKey(const ValueKey('wardrobe-buy')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'all technicians: the celebration names the technician collection',
      (tester) async {
        await open(tester, () {
          final json = _json(unlocked: true);
          final p = jsonMap(
            jsonList(jsonMap(json['uniqueFigures'])['plays']).single,
          );
          p.addAll({'allTechnicians': true, 'play': 'Technik', 'year': null});
          json['uniqueFigures'] = {
            ...jsonMap(json['uniqueFigures']),
            'plays': [p],
          };
          return json;
        });
        expect(find.text('Alle 3 Techniker gesammelt'), findsOneWidget);
        expect(find.text('Unique · Technik'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('no group without a play that has one (all still waiting)', (
      tester,
    ) async {
      await open(tester, () => _json(withPlays: false));
      expect(find.byKey(const ValueKey('wardrobe-group-unique')), findsNothing);
      expect(find.byKey(hidden), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('unlocked: celebrated once, then marked seen and worn', (
      tester,
    ) async {
      final calls = await open(tester, () => _json(unlocked: true));
      expect(find.byKey(const ValueKey('unique-celebration')), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('unique-unlocked-character.unique-captain-kuschel'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Alle 3 Rollen aus Creepshow gesammelt'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('unique-wear')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('unique-celebration')), findsNothing);
      expect(calls.first.$1, endsWith('/games/runner/unique/seen'));
      expect(calls.first.$2, {
        'itemIds': ['character.unique-captain-kuschel'],
        'roles': true,
        'unique': true,
      });
      expect(calls[1].$2, {
        'kind': 'character',
        'itemId': 'character.unique-captain-kuschel',
        'roles': true,
        'unique': true,
      });
      // The card itself now, with its name.
      expect(
        find.byKey(const ValueKey('wardrobe-character.unique-captain-kuschel')),
        findsOneWidget,
      );
      expect(find.byKey(hidden), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the card style: a holographic shimmer and a rainbow bar, '
      'unlike gold', (tester) async {
    final controller = await _signedIn(
      (request) => request.url.path.contains('/games/runner/skins/')
          ? Future.value(http.Response('', 404))
          : null,
    );
    final w = Wardrobe.fromJson(_json(unlocked: true));
    Future<void> show(String id) => _pump(
      tester,
      Center(
        child: SizedBox(
          width: 120,
          height: 170,
          child: WardrobeCard(
            item: w.catalog.item(id)!,
            wardrobe: w,
            controller: controller,
          ),
        ),
      ),
    );
    Gradient? bar() => [
      for (final box in tester.widgetList<Container>(find.byType(Container)))
        if (box.decoration case BoxDecoration(:final gradient?)) gradient,
    ].lastOrNull;

    await show('character.unique-captain-kuschel');
    expect(find.byKey(const ValueKey('holo-overlay')), findsOneWidget);
    expect(find.text('Captain Kuschel'), findsOneWidget);
    expect(find.text('Unique · Creepshow 2026'), findsOneWidget);
    expect(bar(), holoGradient);
    final unique = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(WardrobeCard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(unique.color, holoInk);

    await show('r1');
    expect(find.byKey(const ValueKey('holo-overlay')), findsNothing);
    expect(bar(), isNot(holoGradient));
    final gold = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(WardrobeCard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(gold.color, wardrobeInk);
    await tester.pumpWidget(const SizedBox());
  });
}
