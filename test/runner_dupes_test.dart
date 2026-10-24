import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/crate_opening.dart';
import 'package:theater_app/features/games/ui/ensemble_card.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_cards.dart';
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
  'runnerEnsemble',
];

JsonMap _item(
  String id,
  String kind,
  String name,
  String rarity, {
  bool isDefault = false,
  JsonMap extra = const {},
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'rarity': rarity,
  'rarities': [rarity],
  if (isDefault) 'default': true,
  ...extra,
};

/// What the server sends of a milestone not reached yet: a surprise.
JsonMap _hiddenGoal(num km) => {
  'km': km,
  'name': '???',
  'hidden': true,
  'reward': null,
  'reached': false,
};

/// The 25 km goal (Anno 1146) once reached.
JsonMap _anno({bool ready = true}) => {
  'km': 25,
  'name': 'Anno 1146',
  'reward': {'itemId': 'bd.anno', 'ready': ready, 'kind': 'backdrop'},
  'reached': true,
};

/// A wardrobe as a server with duplicates and the ensemble sends it: the
/// rewards are a surprise until their milestone is reached; [legacyServer]
/// names them anyway, as servers before 0.11.4 did.
JsonMap _json({
  List<String> owned = const ['h1'],
  List<String> shiny = const [],
  List<String> variants = const [],
  JsonMap selected = const {},
  JsonMap selectedVariants = const {},
  int gage = 120,
  int ensembleMeters = 6800,
  List<num> unseen = const [],
  int ensembleCrates = 0,
  bool complete = false,
  bool annoReady = true,
  bool legacyServer = false,
}) {
  final reached = ensembleMeters >= 25000;
  final legacyAnno = {
    'km': 25,
    'name': 'Anno 1146',
    'reward': {'itemId': 'bd.anno', 'ready': true},
    'reached': false,
  };
  return {
    'progress': {
      'meters': 2900,
      'earned': 1,
      'opened': 0,
      'crates': 1,
      'previousAt': 2000,
      'nextAt': 4100,
      'poolSize': 2,
      'complete': complete,
      'ensembleCrates': ensembleCrates,
      'dupes': true,
    },
    'catalog': {
      'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
      'rarities': [
        {
          'id': 'hellblau',
          'name': 'Hellblau',
          'color': '#5E98D9',
          'weight': 60,
          'gage': 10,
          'buyable': true,
        },
        {
          'id': 'pink',
          'name': 'Pink',
          'color': '#D32CE6',
          'weight': 30,
          'gage': 40,
          'buyable': true,
        },
        {
          'id': 'gold',
          'name': 'Gold',
          'color': '#E4AE39',
          'weight': 10,
          'gage': 200,
          'buyable': false,
        },
      ],
      'departments': [],
      'dupes': {
        'shinyChance': {'costume': .03, 'ensemble': .03},
        'tradeDupes': 5,
        'buyDupes': 10,
      },
      'ensembleRarity': {
        'id': 'ensemble',
        'name': 'Ensemble',
        'color': '#F28C28',
      },
      'items': [
        _item('c0', 'character', 'Engel Logge', 'hellblau', isDefault: true),
        _item('b0', 'backdrop', 'Bühnenwand', 'hellblau', isDefault: true),
        _item(
          'o0',
          'obstacles',
          'Requisitenlager',
          'hellblau',
          isDefault: true,
        ),
        _item('f0', 'fx', 'Ohne Effekt', 'hellblau', isDefault: true),
        _item(
          'h1',
          'character',
          'Elena',
          'hellblau',
          extra: {
            'variants': [
              {
                'id': 'h1.julia',
                'name': 'Julia (Romeo und Julia, 2026)',
                'image': '/games/runner/skins/julia.webp?v=1',
                'harness': {
                  'fly': [90, 30],
                },
              },
              {
                'id': 'h1.amme',
                'name': 'Amme (Romeo und Julia, 2026)',
                'image': '/games/runner/skins/amme.webp?v=1',
              },
            ],
          },
        ),
        _item('p1', 'character', 'Nela', 'pink'),
        _item('g1', 'character', 'Theresa', 'gold'),
      ],
      'rewards': [
        if (reached || legacyServer)
          _item(
            'bd.anno',
            'backdrop',
            'Anno 1146',
            'ensemble',
            extra: {'reward': true},
          ),
      ],
    },
    'lockedRarities': [],
    'owned': [
      'c0',
      'b0',
      'o0',
      'f0',
      ...owned,
      if (reached && annoReady) 'bd.anno',
    ],
    'selected': {
      'character': 'c0',
      'backdrop': 'b0',
      'obstacles': 'o0',
      'fx': 'f0',
      ...selected,
    },
    'stats': {'rounds': 3, 'best': 100, 'meters': 2900},
    'shiny': shiny,
    'variants': variants,
    'selectedVariants': selectedVariants,
    'gage': {'balance': gage, 'earned': gage},
    'trades': [
      {'from': 'hellblau', 'to': 'pink', 'cost': 50},
      {'from': 'pink', 'to': 'gold', 'cost': 200},
    ],
    'ensemble': {
      'meters': ensembleMeters,
      'previousKm': reached ? 25 : 0,
      'next': reached
          ? _hiddenGoal(1000)
          : legacyServer
          ? legacyAnno
          : _hiddenGoal(25),
      'milestones': [
        reached
            ? _anno(ready: annoReady)
            : legacyServer
            ? legacyAnno
            : _hiddenGoal(25),
        legacyServer
            ? {
                'km': 1000,
                'name': 'Romeo und Julia',
                'note': 'Premiere am 27.12.2026',
                'reward': {'itemId': 'backdrop.romeo-julia', 'ready': true},
                'reached': false,
              }
            : _hiddenGoal(1000),
        {
          'km': 1250,
          'name': 'Ensemble-Kiste',
          'reward': null,
          'reached': false,
        },
      ],
      'crates': ensembleCrates,
      'unseen': unseen,
      'section': {'from': 0, 'own': 3400, 'players': 7},
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

  group('duplicates and the ensemble in the data', () {
    test('gage, shine, roles, trades and the shop come from the server', () {
      final w = Wardrobe.fromJson(
        _json(
          shiny: ['h1'],
          variants: ['h1.julia'],
          selectedVariants: {'h1': 'h1.julia'},
          ensembleMeters: 26000,
          annoReady: false,
        ),
      );
      final elena = w.catalog.item('h1')!;
      expect(w.isShiny(elena), isTrue);
      expect(w.variantOf(elena)?.name, 'Julia (Romeo und Julia, 2026)');
      expect(elena.inRole(w.variantOf(elena)).image, contains('julia.webp'));
      expect(elena.inRole(w.variantOf(elena)).harness['fly'], (90.0, 30.0));
      expect(w.gage, 120);
      expect(w.trades.map((t) => (t.to, t.cost)), [
        ('pink', 50),
        ('gold', 200),
      ]);
      // Ten pink duplicates; gold is not for sale; owned is not either.
      expect(w.buyCost(w.catalog.item('p1')!), 400);
      expect(w.buyCost(w.catalog.item('g1')!), isNull);
      expect(w.buyCost(elena), isNull);
      // Rewards are items, but no crate brings them.
      final anno = w.catalog.item('bd.anno')!;
      expect(anno.reward, isTrue);
      expect(w.catalog.collectible.map((i) => i.id), ['h1', 'p1', 'g1']);
      expect(w.collectible, 3);
      expect(w.catalog.rarityOf(anno).name, 'Ensemble');
      expect(w.buyCost(anno), isNull);
      expect(
        w.catalog.chance(w.catalog.rarities.last),
        closeTo(10 / 100, 1e-9),
      );
      expect(rewardHint(w, anno), 'Belohnung wird vorbereitet');
      expect(w.progress.waiting, 1);
      expect(w.progress.canOpen, isTrue);
    });

    test('the chance of a shine comes per crate kind', () {
      final old = DupeRules.fromJson({'shinyChance': .05});
      expect((old.shinyChance, old.shinyChanceOf('ensemble')), (.05, .05));
      final kinds = DupeRules.fromJson({
        'shinyChance': {'costume': .03, 'ensemble': .03, 'mission': .05},
      });
      expect(kinds.shinyChance, .03);
      expect(kinds.shinyChanceOf('ensemble'), .03);
      expect(kinds.shinyChanceOf('mission'), .05);
      expect(kinds.shinyChanceOf('unknown'), .03);
      expect(DupeRules.fromJson({}).shinyChanceOf('ensemble'), .03);
    });

    test('the ensemble shows the way to the next milestone', () {
      final e = Wardrobe.fromJson(_json()).ensemble!;
      expect(e.remaining, 18200);
      expect(e.fraction, closeTo(6800 / 25000, 1e-9));
      expect(e.sectionOwn, 3400);
      expect(e.next.hidden, isTrue);
      expect(e.milestone(1000)?.note, isNull);
      expect(kmText(1234), '1,2 km');
      expect(kmText(25000), '25 km');
      final run = EnsembleRun.fromJson({
        'gained': 1200,
        'meters': 6800,
        'next': _hiddenGoal(25),
        'reached': [],
      });
      expect(
        ensembleRunText(run),
        '+1,2 km fürs Ensemble · noch 18,2 km bis zur nächsten Überraschung',
      );
      // A goal with only the crate keeps its name.
      final crate = EnsembleRun.fromJson({
        'gained': 1200,
        'meters': 1240000,
        'next': {'km': 1250, 'name': 'Ensemble-Kiste', 'reached': false},
        'reached': [],
      });
      expect(
        ensembleRunText(crate),
        '+1,2 km fürs Ensemble · noch 10 km bis Ensemble-Kiste',
      );
    });

    test('a complete collection still opens crates with duplicates', () {
      final w = Wardrobe.fromJson(_json(complete: true));
      expect(w.progress.canOpen, isTrue);
      expect(nextCrateText(w.progress), 'noch 1.200 m bis zur nächsten Kiste');
      expect(crateWaiting(w), isTrue);
      // An older server: complete means closed.
      final old = RunnerProgress.fromJson({
        'crates': 1,
        'complete': true,
        'nextAt': 4100,
        'meters': 2900,
      });
      expect(old.canOpen, isFalse);
      expect(nextCrateText(old), startsWith('Fundus komplett'));
    });

    test('outcomes name what a duplicate brought', () {
      CrateOutcome o(JsonMap json) => CrateOutcome.fromJson(json);
      expect(o({'type': 'gage', 'gage': 40}).line, 'Duplikat → +40 Gage');
      expect(
        o({
          'type': 'variant',
          'variant': {'id': 'v', 'name': 'Julia (Romeo und Julia, 2026)'},
        }).line,
        'Neue Rolle: Julia · Romeo und Julia 2026',
      );
      expect(o({'type': 'shine', 'shiny': true}).shineNew, isTrue);
      expect(o({'type': 'gage', 'shiny': true}).shineNew, isFalse);
      expect(o({'type': 'new'}).line, isNull);
      expect(o({'crate': 'ensemble'}).ensemble, isTrue);
    });
  });

  group('shine and roles in the game', () {
    test(
      'the worn role replaces the atlas, a shiny character shines',
      () async {
        final role = await createTestImage(width: 1124, height: 577);
        final png = (await role.toByteData(format: ui.ImageByteFormat.png))!;
        final fetched = <String>[];
        final controller = await _signedIn((request) {
          if (!_path(request).contains('/games/runner/skins/')) return null;
          fetched.add(_path(request).split('/').last);
          return Future.value(
            http.Response.bytes(
              png.buffer.asUint8List(),
              200,
              headers: {'content-type': 'image/png'},
            ),
          );
        });
        final atlas = await createTestImage(width: 1124, height: 577);
        final backdrop = await createTestImage(width: 64, height: 32);
        final w = Wardrobe.fromJson(
          _json(
            shiny: ['h1'],
            variants: ['h1.julia'],
            selected: {'character': 'h1'},
            selectedVariants: {'h1': 'h1.julia'},
          ),
        );
        final art = await dressArt(
          RunnerArt.test(atlas, backdrop),
          w,
          controller,
        );
        expect(fetched, ['julia.webp']);
        expect(art.imageOf(RunnerSprite.cheer), isNot(atlas));
        expect(art.harnessOf(RunnerSprite.fly), const ui.Offset(90, 30));
        expect(art.effect?.shine, isTrue);
        expect(art.effect?.trail, '');
        // Without shine and effect nothing is drawn.
        final plain = await dressArt(
          RunnerArt.test(atlas, backdrop),
          Wardrobe.fromJson(_json(selected: {'character': 'h1'})),
          controller,
        );
        expect(plain.effect, isNull);
      },
    );

    test('the shine alone leaves no trail and glints on the figure', () {
      final game = StageRunner(random: Random(1))..update(.016);
      final trail = RunnerTrail(random: Random(2));
      const style = RunnerEffectStyle('', [], shine: true);
      for (var i = 0; i < 60; i++) {
        trail.update(1 / 60, game, style);
      }
      expect(trail.life.every((l) => l <= 0), isTrue);
      // Running, every glint sits on the figure.
      final glints = [
        for (var i = 0; i < RunnerTrail.glints; i++)
          if (trail.glintLife[i] > 0) i,
      ];
      expect(glints, isNotEmpty);
      expect(glints.every((i) => trail.glintLeft[i] == 0), isTrue);
      // In flight some are left behind as a short trail; the pool stays.
      game
        ..y = .4
        ..vy = -.6;
      for (var i = 0; i < 120; i++) {
        trail.update(1 / 60, game, style);
      }
      final left = [
        for (var i = 0; i < RunnerTrail.glints; i++)
          if (trail.glintLife[i] > 0 && trail.glintLeft[i] == 1)
            trail.glintX[i],
      ];
      expect(left, isNotEmpty);
      expect(left.every((x) => x < StageRunner.runnerX), isTrue);
      expect(
        left.every((x) => x > StageRunner.runnerX - .25),
        isTrue,
        reason: 'a short trail',
      );
      expect(trail.glintLife.length, RunnerTrail.glints);
      // Without the shine no new glints come.
      for (var i = 0; i < 60; i++) {
        trail.update(1 / 60, game, null);
      }
      expect(trail.glintLife.every((l) => l <= 0), isTrue);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      trail
        ..paint(canvas, 400, style)
        ..paintGlints(canvas, const Rect.fromLTWH(140, 300, 60, 60), 400);
      recorder.endRecording().dispose();
    });
  });

  group('screens', () {
    testWidgets('the wardrobe shows the ensemble, gage, shine and the shop', (
      tester,
    ) async {
      final calls = <String>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (!path.contains('/games/runner/')) return null;
        calls.add(
          '${request.method} ${path.split('/games/runner/').last} ${request.body}',
        );
        if (path.endsWith('/buy')) {
          return Future.value(
            jsonResponse({
              'item': _item('p1', 'character', 'Nela', 'pink'),
              'outcome': {'type': 'buy', 'cost': 400, 'rarity': 'pink'},
              'wardrobe': _json(owned: ['h1', 'p1'], gage: 0),
            }),
          );
        }
        return Future.value(jsonResponse(_json(shiny: ['h1'], gage: 420)));
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('ensemble-card')), findsOneWidget);
      expect(find.text('6,8 km'), findsOneWidget);
      expect(
        find.text('noch 18,2 km bis zur nächsten Überraschung'),
        findsOneWidget,
      );
      expect(
        find.text('Dein Beitrag in diesem Abschnitt: 3,4 km · 7 Mitspielende'),
        findsOneWidget,
      );
      expect(find.text('420 Gage'), findsOneWidget);
      expect(find.text('Glanz: 3,0 %'), findsOneWidget);
      // The ensemble's reward is a surprise: no card, name or milestone.
      expect(find.byKey(const ValueKey('ensemble-surprise')), findsOneWidget);
      expect(find.byKey(const ValueKey('wardrobe-bd.anno')), findsNothing);
      expect(find.textContaining('Anno'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Elena, Hellblau, Glanz')),
        findsOneWidget,
      );

      // A missing pink item: ten pink duplicates.
      await tester.tap(find.byKey(const ValueKey('wardrobe-p1')));
      await _settle(tester);
      expect(find.text('Gezielt holen · 400 Gage'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wardrobe-buy')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('deal-confirm')));
      await _settle(tester);
      expect(calls.where((c) => c.startsWith('POST buy')), [
        'POST buy {"itemId":"p1"}',
      ]);
      expect(find.text('Gekauft für 400 Gage'), findsOneWidget);
      await tester.tap(find.text('Fertig'));
      await _settle(tester);

      // Gold cannot be bought.
      await tester.tap(find.byKey(const ValueKey('wardrobe-g1')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('wardrobe-buy')), findsNothing);
      expect(
        find.text('Gold gibt es nur aus Kisten und Tauschverträgen.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a trade is chosen, signed and confirmed', (tester) async {
      final bodies = <JsonMap>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/trade')) {
          bodies.add(jsonMap(jsonDecode(request.body)));
          return Future.value(
            jsonResponse({
              'item': _item('p1', 'character', 'Nela', 'pink'),
              'outcome': {'type': 'trade', 'cost': 50, 'rarity': 'pink'},
              'wardrobe': _json(owned: ['h1', 'p1'], gage: 70),
            }),
          );
        }
        if (path.endsWith('/wardrobe')) {
          return Future.value(jsonResponse(_json()));
        }
        return null;
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('wardrobe-trade')));
      await _settle(tester);
      expect(find.text('→ zufällig Pink'), findsOneWidget);
      // Gold costs more than there is.
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('trade-gold')))
            .enabled,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('trade-pink')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('trade-sign')));
      await _settle(tester);
      expect(find.text('Tauschvertrag unterschreiben?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('deal-confirm')));
      await _settle(tester);
      expect(bodies, [
        {'rarity': 'hellblau'},
      ]);
      expect(find.text('Aus dem Tauschvertrag (−50 Gage)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a reached milestone is celebrated once and marked seen', (
      tester,
    ) async {
      final seen = <JsonMap>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/ensemble/seen')) {
          seen.add(jsonMap(jsonDecode(request.body)));
          return Future.value(
            jsonResponse(_json(ensembleMeters: 26000, ensembleCrates: 1)),
          );
        }
        if (path.endsWith('/wardrobe')) {
          return Future.value(
            jsonResponse(
              _json(ensembleMeters: 26000, unseen: [25], ensembleCrates: 1),
            ),
          );
        }
        return null;
      });
      final sound = _Sound();
      await _pump(tester, WardrobeScreen(controller: controller, sound: sound));
      await _settle(tester);
      expect(find.text('Ensemble-Ziel erreicht!'), findsOneWidget);
      expect(find.text('Gemeinsam 25 km gelaufen'), findsOneWidget);
      // The surprise is revealed: the curtain opens on what it unlocked.
      expect(
        find.text('Freigeschaltet: Bühnenbild „Anno 1146“'),
        findsOneWidget,
      );
      expect(find.text('Für dich wartet 1 Ensemble-Kiste.'), findsOneWidget);
      expect(sound.played, contains(RunnerSfx.jackpot));
      await tester.tap(find.text('Weiter'));
      await _settle(tester);
      expect(seen, [
        {'km': 25},
      ]);
      expect(find.text('Ensemble-Ziel erreicht!'), findsNothing);
      expect(find.byKey(const ValueKey('ensemble-open')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    // Role figures: every role is a figure of its own, so the card offers
    // no role to choose any more, also when an older server sends variants.
    testWidgets('the card offers no role choice', (tester) async {
      final bodies = <JsonMap>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/outfit')) {
          bodies.add(jsonMap(jsonDecode(request.body)));
        }
        if (path.contains('/games/runner/skins/')) {
          return Future.value(http.Response('', 404));
        }
        if (path.contains('/games/runner/')) {
          return Future.value(
            jsonResponse(
              _json(variants: ['h1.julia'], selected: {'character': 'h1'}),
            ),
          );
        }
        return null;
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('wardrobe-h1')));
      await _settle(tester);
      expect(find.text('Rolle'), findsNothing);
      expect(find.text('? (Duplikat)'), findsNothing);
      expect(find.byKey(const ValueKey('variant-h1.julia')), findsNothing);
      expect(find.byKey(const ValueKey('variant-plain')), findsNothing);
      expect(bodies, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    // "Von Statistik auf Kostüme: ein weißer Block": the goals' tile and the
    // costumes' scroll view kept their state under the same storage id.
    testWidgets('back from the statistics the costumes keep goals and scroll', (
      tester,
    ) async {
      final controller = await _signedIn(
        (request) => _path(request).contains('/games/runner/')
            ? Future.value(jsonResponse(_json()))
            : null,
      );
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      tester.view.physicalSize = const Size(400, 800);
      await _settle(tester);
      await tester.tap(find.text('Alle Ziele'));
      await _settle(tester);
      expect(find.text('1.000 km · ???'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await _settle(tester);
      final scrolled = tester.getTopLeft(find.text('Alle Ziele')).dy;

      for (final tab in ['Statistik', 'Kostüme', 'Statistik', 'Kostüme']) {
        await tester.tap(find.text(tab));
        await _settle(tester);
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.byKey(const ValueKey('ensemble-card')), findsOneWidget);
      expect(find.text('1.000 km · ???'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Alle Ziele')).dy, scrolled);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the features there is no gage, trade or ensemble', (
      tester,
    ) async {
      final controller = await _signedIn(
        (request) => _path(request).endsWith('/wardrobe')
            ? Future.value(jsonResponse(_json()))
            : null,
        features: const ['stageRunner', 'runnerUnlocks'],
      );
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('ensemble-card')), findsNothing);
      expect(find.byKey(const ValueKey('wardrobe-trade')), findsNothing);
      expect(find.byKey(const ValueKey('wardrobe-gage')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    Future<_Sound> reveal(
      WidgetTester tester,
      AppController controller,
      JsonMap outcome,
      String won,
    ) async {
      final w = Wardrobe.fromJson(_json());
      final item = w.catalog.item(won)!;
      final sound = _Sound();
      await _pump(
        tester,
        CrateOpeningPage(
          controller: controller,
          wardrobe: w,
          sound: sound,
          open: () async => CrateOpening(
            item: item,
            reel: List.filled(56, item),
            winnerIndex: 48,
            wardrobe: Wardrobe.fromJson(_json(shiny: ['h1'])),
            outcome: CrateOutcome.fromJson(outcome),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(400, 200));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      return sound;
    }

    testWidgets('a duplicate shows its gage', (tester) async {
      final controller = await _signedIn((_) => null);
      await reveal(tester, controller, {
        'type': 'gage',
        'gage': 40,
        'duplicate': true,
      }, 'p1');
      expect(find.text('Duplikat → +40 Gage'), findsOneWidget);
      expect(find.byKey(const ValueKey('crate-shine')), findsNothing);
      // Complete or not, with duplicates the next crate opens.
      expect(find.text('Nächste Kiste (1)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a shine gets its own reveal', (tester) async {
      final controller = await _signedIn((_) => null);
      final sound = await reveal(tester, controller, {
        'type': 'shine',
        'shiny': true,
        'duplicate': true,
      }, 'h1');
      expect(find.byKey(const ValueKey('crate-shine')), findsOneWidget);
      expect(find.text('Duplikat → jetzt in Glanz!'), findsOneWidget);
      expect(sound.played.last, RunnerSfx.jackpot);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('after a run the ensemble line shows', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: EnsembleRunNote(
            EnsembleRun.fromJson({
              'gained': 1200,
              'meters': 25400,
              'next': _hiddenGoal(50),
              'reached': [_anno()],
            }),
          ),
        ),
      );
      expect(
        find.text(
          '+1,2 km fürs Ensemble · noch 24,6 km bis zur nächsten Überraschung',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Ensemble-Ziel erreicht – freigeschaltet: Bühnenbild „Anno 1146“! Eine Ensemble-Kiste wartet in der Garderobe.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Goldregen'), findsNothing);
    });
  });

  group('ensemble rewards stay a surprise until reached', () {
    test('a hidden goal has only its distance', () {
      final w = Wardrobe.fromJson(_json());
      final next = w.ensemble!.next;
      expect(
        (next.km, next.name, next.hidden, next.rewardId, next.note),
        (25, '???', true, null, null),
      );
      expect(w.catalog.item('bd.anno'), isNull);
      expect(w.catalog.items.where((i) => i.reward), isEmpty);
      // A goal with only the crate is no secret.
      final crate = w.ensemble!.milestone(1250)!;
      expect((crate.name, crate.hidden), ('Ensemble-Kiste', false));
    });

    test('the boundary is the milestone: 24.999 m hide it, 25.000 m not', () {
      final before = Wardrobe.fromJson(_json(ensembleMeters: 24999));
      expect(before.ensemble!.milestone(25)!.hidden, isTrue);
      expect(before.catalog.item('bd.anno'), isNull);
      final at = Wardrobe.fromJson(_json(ensembleMeters: 25000));
      final anno = at.ensemble!.milestone(25)!;
      expect(
        (anno.name, anno.hidden, anno.rewardId, anno.rewardKind),
        ('Anno 1146', false, 'bd.anno', WardrobeKind.backdrop),
      );
      expect(at.catalog.item('bd.anno')?.name, 'Anno 1146');
      expect(at.owns(at.catalog.item('bd.anno')!), isTrue);
    });

    test('a server from before names the rewards: the app hides them', () {
      final w = Wardrobe.fromJson(_json(legacyServer: true));
      final next = w.ensemble!.next;
      expect((next.name, next.hidden, next.rewardId), ('???', true, null));
      final romeo = w.ensemble!.milestone(1000)!;
      expect((romeo.name, romeo.note, romeo.hidden), ('???', null, true));
      expect(w.catalog.item('bd.anno'), isNull, reason: 'not in the grid');
      expect(w.catalog.item('h1'), isNotNull);
    });

    testWidgets('the card shows a curtain, then what was unlocked', (
      tester,
    ) async {
      final controller = await _signedIn((_) => null);
      Future<void> card(JsonMap json) async {
        await tester.pumpWidget(const SizedBox());
        await _pump(
          tester,
          Scaffold(
            body: SingleChildScrollView(
              child: EnsembleCard(
                wardrobe: Wardrobe.fromJson(json),
                controller: controller,
              ),
            ),
          ),
        );
        await tester.tap(find.text('Alle Ziele'));
        await _settle(tester);
      }

      await card(_json());
      expect(find.byKey(const ValueKey('ensemble-surprise')), findsOneWidget);
      expect(
        find.text('noch 18,2 km bis zur nächsten Überraschung'),
        findsOneWidget,
      );
      expect(
        find.text('Eine Überraschung + 1 Ensemble-Kiste für jede:n'),
        findsOneWidget,
      );
      expect(find.text('25 km · ???'), findsOneWidget);
      expect(find.text('1.000 km · ???'), findsOneWidget);
      expect(find.text('Überraschung + Ensemble-Kiste'), findsNWidgets(2));
      expect(find.text('1.250 km · Ensemble-Kiste'), findsOneWidget);
      for (final secret in ['Anno', 'Romeo', 'Bühnenbild', 'Premiere']) {
        expect(find.textContaining(secret), findsNothing, reason: secret);
      }

      await card(_json(ensembleMeters: 26000));
      expect(find.text('25 km · Anno 1146'), findsOneWidget);
      expect(find.text('Bühnenbild · für alle freigeschaltet'), findsOneWidget);
      // The next one is the next surprise.
      expect(find.byKey(const ValueKey('ensemble-surprise')), findsOneWidget);
      expect(find.text('1.000 km · ???'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
