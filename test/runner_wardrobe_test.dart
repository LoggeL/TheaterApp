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
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/domain/crate_reel.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/crate_opening.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;

/// Records what would sound.
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

JsonMap _item(
  String id,
  String kind,
  String name,
  Object rarity, {
  bool isDefault = false,
  JsonMap extra = const {},
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'rarity': rarity is List ? rarity.first : rarity,
  'rarities': rarity is List ? rarity : [rarity],
  if (isDefault) 'default': true,
  ...extra,
};

/// A wardrobe as the server sends it.
JsonMap _wardrobeJson({
  List<String> owned = const [],
  JsonMap selected = const {},
  int meters = 2900,
  int crates = 1,
  List<String> locked = const ['legacy'],
  JsonMap? stats,
}) => {
  'progress': {
    'meters': meters,
    'earned': 1,
    'opened': 1 - crates,
    'crates': crates,
    'previousAt': 2000,
    'nextAt': 4100,
    'poolSize': 4,
    'complete': false,
  },
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hellblau', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
      {'id': 'technik', 'name': 'Technik', 'color': '#2FBF71', 'weight': 14},
      {
        'id': 'legacy',
        'name': 'Legacy',
        'color': '#A47A4B',
        'weight': 8,
        'style': 'antique',
        'hint': 'Sammle alle hellblauen Figuren',
      },
      {'id': 'gold', 'name': 'Gold', 'color': '#E4AE39', 'weight': 1.5},
    ],
    'departments': [
      {'id': 'buehne', 'name': 'Bühne', 'icon': 'stage'},
    ],
    'items': [
      _item('c0', 'character', 'Engel Logge', 'hellblau', isDefault: true),
      _item('b0', 'backdrop', 'Bühnenwand', 'hellblau', isDefault: true),
      _item('o0', 'obstacles', 'Requisitenlager', 'hellblau', isDefault: true),
      _item('f0', 'fx', 'Ohne Effekt', 'hellblau', isDefault: true),
      _item(
        'maren',
        'character',
        'Maren',
        ['technik', 'hellblau'],
        extra: {
          'label': 'Bühnentechnik · Ensemble',
          'departments': ['buehne'],
          'placeholder': true,
          'tint': {'hue': 120},
        },
      ),
      _item(
        'elena',
        'character',
        'Elena',
        'gold',
        extra: {'rarityReason': '152 Textstellen', 'placeholder': true},
      ),
      _item('anton', 'character', 'Anton', 'legacy'),
      _item(
        'funken',
        'fx',
        'Funkenflug',
        'hellblau',
        extra: {
          'effect': {
            'trail': 'sparkle',
            'colors': ['#FFD86B'],
          },
        },
      ),
    ],
  },
  'lockedRarities': locked,
  'owned': ['c0', 'b0', 'o0', 'f0', ...owned],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
    ...selected,
  },
  'stats':
      stats ??
      {
        'rounds': 12,
        'best': 830,
        'meters': meters,
        'creditedMeters': 300,
        'deaths': [
          {'kind': 'lamp', 'count': 2},
          {'kind': 'crate', 'count': 5},
        ],
        'unknown': 1,
        'untracked': 4,
      },
};

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<AppController> _signedIn(
  WidgetTester tester,
  Future<http.Response>? Function(http.Request) handle, {
  List<String> features = const ['stageRunner', 'runnerUnlocks'],
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
  tester.view.physicalSize = const Size(800, 1600);
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
  setUp(WardrobePictures.clear);

  group('reel', () {
    test('starts fast, brakes long, slides past and settles on the card', () {
      final reel = CrateReel(winner: 48, landing: .3);
      expect(reel.position(0), 0);
      // Most of the way is covered early, the rest takes long.
      expect(reel.position(1), greaterThan(48 * .5));
      expect(reel.position(reel.duration * .5), greaterThan(45));
      var last = 0.0, peak = 0.0;
      for (
        var t = 0.0;
        t <= reel.duration * (1 - CrateReel.settleShare);
        t += .01
      ) {
        final p = reel.position(t);
        expect(p, greaterThanOrEqualTo(last - 1e-9));
        last = p;
        peak = max(peak, p);
      }
      // Past the stop, by a little …
      expect(peak, closeTo(reel.stop + CrateReel.overshoot, .01));
      // … and back to rest on the won card.
      expect(reel.position(reel.duration), reel.stop);
      expect(reel.cardAt(reel.duration), 48);
      expect(reel.done(reel.duration), isTrue);
    });

    test('lands somewhere on the won card, never on a neighbour', () {
      final random = Random(1);
      for (var i = 0; i < 200; i++) {
        final reel = CrateReel(winner: 10, random: random);
        expect(reel.landing.abs(), lessThanOrEqualTo(.35));
        expect(reel.cardAt(reel.duration), 10);
      }
    });
  });

  group('wardrobe data', () {
    test(
      'hybrids, labels, locks, counter and chances come from the server',
      () {
        final w = Wardrobe.fromJson(_wardrobeJson(owned: ['maren']));
        final maren = w.catalog.item('maren')!;
        expect(w.catalog.raritiesOf(maren).map((r) => r.name), [
          'Technik',
          'Hellblau',
        ]);
        expect(w.catalog.labelOf(maren), 'Bühnentechnik · Ensemble');
        expect(w.collected, 1);
        expect(w.collectible, 4);
        expect(
          w.lockHint(w.catalog.item('anton')!),
          'Sammle alle hellblauen Figuren',
        );
        expect(w.lockHint(w.catalog.item('elena')!), isNull);
        expect(w.progress.remaining, 1200);
        expect(w.progress.fraction, closeTo(900 / 2100, 1e-9));
        final gold = w.catalog.rarities.last;
        // Locked legacy does not count: 1.5 of 45 + 14 + 1.5.
        expect(
          w.catalog.chance(gold, w.lockedRarities),
          closeTo(1.5 / 60.5, 1e-9),
        );
        expect(w.stats.deaths.first, (ObstacleKind.crate, 5));
        expect(
          nextCrateText(w.progress),
          'noch 1.200 m bis zur nächsten Kiste',
        );
        expect(metersText(12345), '12.345 m');
      },
    );

    test('a hue of zero changes nothing; a turn keeps grey grey', () {
      expect(tintFilter(const WardrobeTint()), isNull);
      final m = tintMatrix(const WardrobeTint(hue: 120));
      // Each row sums to one: grey stays grey.
      for (var r = 0; r < 3; r++) {
        expect(m[r * 5] + m[r * 5 + 1] + m[r * 5 + 2], closeTo(1, 1e-9));
      }
      final dark = tintMatrix(const WardrobeTint(brightness: .5));
      expect(dark[0], closeTo(.5, 1e-9));
    });
  });

  group('costumes in the game', () {
    test('only the poses come from the character, pickups stay', () async {
      final atlas = await createTestImage(width: 1124, height: 577);
      final other = await createTestImage(width: 1124, height: 577);
      final backdrop = await createTestImage(width: 64, height: 32);
      final base = RunnerArt.test(atlas, backdrop);
      final dressed = base.dressed(
        runner: other,
        harness: {RunnerSprite.fly: const ui.Offset(1, 2)},
      );
      expect(dressed.imageOf(RunnerSprite.cheer), other);
      expect(dressed.imageOf(RunnerSprite.crate), atlas);
      expect(dressed.imageOf(RunnerSprite.rose), atlas);
      expect(dressed.harnessOf(RunnerSprite.fly), const ui.Offset(1, 2));
      expect(dressed.harnessOf(RunnerSprite.cheer), RunnerSprite.cheer.harness);
      // Without its own atlas a costume keeps the default wire points.
      expect(
        base
            .dressed(harness: {RunnerSprite.fly: const ui.Offset(1, 2)})
            .harnessOf(RunnerSprite.fly),
        RunnerSprite.fly.harness,
      );
    });

    test('a missing picture falls back to the tinted default art', () async {
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner', 'runnerUnlocks'],
      };
      server.override = (request) =>
          _path(request).contains('/games/runner/skins/')
          ? Future.value(http.Response('', 404))
          : null;
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      {
        final atlas = await createTestImage(width: 1124, height: 577);
        final backdrop = await createTestImage(width: 64, height: 32);
        final base = RunnerArt.test(atlas, backdrop);
        final json = _wardrobeJson(
          owned: ['maren', 'funken'],
          selected: {'character': 'maren', 'fx': 'funken'},
        );
        // Maren gets a picture that the server does not have.
        final items = jsonList(jsonMap(json['catalog'])['items']);
        (items[4] as Map)['image'] = '/games/runner/skins/character-maren.webp';
        final dressed = await dressArt(
          base,
          Wardrobe.fromJson(json),
          controller,
        );
        expect(dressed.imageOf(RunnerSprite.cheer), atlas);
        expect(dressed.runnerPaint.colorFilter, isNotNull);
        expect(dressed.obstaclePaint.colorFilter, isNull);
        expect(dressed.effect?.trail, 'sparkle');
      }
    });

    test('a worn atlas is fetched once and replaces the poses', () async {
      final own = await createTestImage(width: 1124, height: 577);
      final png = (await own.toByteData(format: ui.ImageByteFormat.png))!;
      var fetched = 0;
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner', 'runnerUnlocks'],
      };
      server.override = (request) {
        if (!_path(request).contains('/games/runner/skins/')) return null;
        fetched++;
        return Future.value(
          http.Response.bytes(
            png.buffer.asUint8List(),
            200,
            headers: {'content-type': 'image/png'},
          ),
        );
      };
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      final atlas = await createTestImage(width: 1124, height: 577);
      final backdrop = await createTestImage(width: 64, height: 32);
      final json = _wardrobeJson(
        owned: ['maren'],
        selected: {'character': 'maren'},
      );
      final items = jsonList(jsonMap(json['catalog'])['items']);
      (items[4] as Map)['image'] =
          '/games/runner/skins/character-maren.webp?v=1';
      (items[4] as Map)['harness'] = {
        'fly': [100, 40],
      };
      final w = Wardrobe.fromJson(json);
      final base = RunnerArt.test(atlas, backdrop);
      final both = await Future.wait([
        dressArt(base, w, controller),
        dressArt(base, w, controller),
      ]);
      expect(fetched, 1);
      final runner = both.first.imageOf(RunnerSprite.cheer);
      expect(runner, isNot(atlas));
      expect(runner.width, 1124);
      expect(both.first.imageOf(RunnerSprite.crate), atlas);
      expect(both.first.harnessOf(RunnerSprite.fly), const ui.Offset(100, 40));
      await dressArt(base, w, controller);
      expect(fetched, 1, reason: 'kept for the session');
    });

    test('the trail follows a worn effect and stays behind', () {
      final game = StageRunner(random: Random(1))..update(.016);
      final trail = RunnerTrail(random: Random(2));
      for (var i = 0; i < 30; i++) {
        trail.update(1 / 60, game, null);
      }
      expect(trail.life.every((l) => l <= 0), isTrue);
      const style = RunnerEffectStyle('confetti', [Color(0xFFFF0000)]);
      for (var i = 0; i < 30; i++) {
        trail.update(1 / 60, game, style);
      }
      final alive = [
        for (var i = 0; i < RunnerTrail.size; i++)
          if (trail.life[i] > 0) trail.x[i],
      ];
      expect(alive, isNotEmpty);
      expect(alive.every((x) => x < StageRunner.runnerX), isTrue);
    });
  });

  group('screens', () {
    testWidgets('the wardrobe shows crates, the collection and statistics', (
      tester,
    ) async {
      final calls = <String>[];
      final controller = await _signedIn(tester, (request) {
        final path = _path(request);
        if (!path.contains('/games/runner/')) return null;
        calls.add('${request.method} ${path.split('/games/runner/').last}');
        if (path.endsWith('/outfit')) {
          final body = jsonMap(jsonDecode(request.body));
          return Future.value(
            jsonResponse(
              _wardrobeJson(
                owned: ['maren'],
                selected: {'character': body['itemId']},
              ),
            ),
          );
        }
        return Future.value(jsonResponse(_wardrobeJson(owned: ['maren'])));
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('1 Kostümkiste bereit'), findsOneWidget);
      expect(find.text('1/4 gesammelt'), findsOneWidget);
      expect(
        find.text('2.900 m gelaufen · noch 1.200 m bis zur nächsten Kiste'),
        findsOneWidget,
      );
      expect(find.text('Gold: 2,5 %'), findsOneWidget);
      expect(find.text('Legacy: gesperrt'), findsOneWidget);
      expect(find.text('Sammle alle hellblauen Figuren'), findsOneWidget);
      // Kinds with nothing to collect but their default stay hidden.
      expect(find.text('Figuren'), findsOneWidget);
      expect(find.text('Effekte'), findsOneWidget);
      expect(find.text('Bühnenbilder'), findsNothing);
      expect(find.text('Hindernisse'), findsNothing);
      expect(find.byKey(const ValueKey('wardrobe-o0')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('wardrobe-maren')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Charakter · Technik · Hellblau'), findsNothing);
      expect(find.text('Figur · Technik · Hellblau'), findsOneWidget);
      await tester.tap(find.text('Anlegen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, contains('PUT outfit'));

      await tester.tap(find.text('Statistik'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('12'), findsOneWidget);
      expect(find.text('Bestwert'), findsOneWidget);
      expect(find.text('4 frühere Läufe ohne Aufschlüsselung'), findsOneWidget);
      expect(find.text('Unbekannt (ältere App)'), findsOneWidget);
      // Most often first.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('death-crate'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('death-lamp'))).dy,
        ),
      );
      expect(find.text('Requisitenkiste'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a crate rolls, ticks, stops on the won item and dresses', (
      tester,
    ) async {
      final controller = await _signedIn(tester, (_) => null);
      final w = Wardrobe.fromJson(_wardrobeJson());
      final won = w.catalog.item('elena')!;
      final opening = CrateOpening(
        item: won,
        reel: [
          for (var i = 0; i < 56; i++)
            i == 48 ? won : w.catalog.item(i.isEven ? 'maren' : 'funken')!,
        ],
        winnerIndex: 48,
        wardrobe: Wardrobe.fromJson(_wardrobeJson(owned: ['elena'], crates: 0)),
      );
      final sound = _Sound();
      await _pump(
        tester,
        CrateOpeningPage(
          controller: controller,
          wardrobe: w,
          sound: sound,
          open: () async => opening,
          random: Random(4),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('crate-reel')), findsOneWidget);
      for (var i = 0; i < 70; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final ticks = sound.played.where((s) => s == RunnerSfx.tick).length;
      expect(ticks, greaterThan(20));
      expect(ticks, lessThanOrEqualTo(49));
      // Gold is the rarest: the big reveal.
      expect(sound.played.last, RunnerSfx.jackpot);
      expect(find.text('GOLD!'), findsOneWidget);
      expect(find.text('Elena'), findsWidgets);
      expect(find.text('152 Textstellen'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tap skips to the result without ticking on', (tester) async {
      final controller = await _signedIn(tester, (_) => null);
      final w = Wardrobe.fromJson(_wardrobeJson());
      final won = w.catalog.item('funken')!;
      final sound = _Sound();
      await _pump(
        tester,
        CrateOpeningPage(
          controller: controller,
          wardrobe: w,
          sound: sound,
          open: () async => CrateOpening(
            item: won,
            reel: List.filled(56, won),
            winnerIndex: 48,
            wardrobe: Wardrobe.fromJson(_wardrobeJson(owned: ['funken'])),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final before = sound.played.length;
      await tester.tapAt(const Offset(400, 200));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(sound.played.length - before, 1);
      expect(sound.played.last, RunnerSfx.reveal);
      expect(find.text('Anlegen'), findsOneWidget);
      expect(find.text('Nächste Kiste (1)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('after a run the way to the next crate shows', (tester) async {
      JsonMap? submitted;
      final controller = await _signedIn(tester, (request) {
        final path = _path(request);
        if (path.endsWith('/leaderboard')) {
          return Future.value(
            jsonResponse({'players': 0, 'top': [], 'own': null}),
          );
        }
        if (path.endsWith('/wardrobe')) {
          return Future.value(jsonResponse(_wardrobeJson(crates: 0)));
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
                'meters': 4150,
                'earned': 2,
                'opened': 1,
                'crates': 1,
                'previousAt': 4100,
                'nextAt': 6300,
                'poolSize': 3,
                'complete': false,
                'gained': 250,
                'newCrates': 1,
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
      expect(find.byKey(const ValueKey('runner-wardrobe')), findsOneWidget);
      await tester.tap(find.text('Vorhang auf'));
      for (
        var i = 0;
        i < 60 * 20 && find.text('Nochmal').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(submitted!['meters'], isA<int>());
      expect(submitted!['hitBy'], isA<String>());
      expect(
        find.text('+250 m · noch 2.150 m bis zur nächsten Kiste'),
        findsOneWidget,
      );
      expect(
        find.text('Neue Kostümkiste! Ab in die Garderobe.'),
        findsOneWidget,
      );
      expect(sound.played, contains(RunnerSfx.reveal));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the intro names the worn character', (tester) async {
      final controller = await _signedIn(tester, (request) {
        final path = _path(request);
        if (path.endsWith('/leaderboard')) {
          return Future.value(
            jsonResponse({'players': 0, 'top': [], 'own': null}),
          );
        }
        if (path.endsWith('/wardrobe')) {
          return Future.value(
            jsonResponse(
              _wardrobeJson(
                owned: ['maren'],
                selected: {'character': 'maren'},
              ),
            ),
          );
        }
        return null;
      });
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.textContaining('Maren hängt zum ersten Mal am Flugseil'),
        findsOneWidget,
      );
      expect(find.textContaining('Engel Logge hängt'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the feature or in the demo there is no wardrobe', (
      tester,
    ) async {
      final controller = await _signedIn(
        tester,
        (_) => null,
        features: const ['stageRunner'],
      );
      expect(wardrobeAvailable(controller), isFalse);
      final demo = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
        clock: () => fixedNow,
      );
      addTearDown(demo.dispose);
      await demo.startDemo();
      expect(wardrobeAvailable(demo), isFalse);
      await _pump(tester, StageRunnerScreen(controller: demo, sound: _Sound()));
      expect(find.byKey(const ValueKey('runner-wardrobe')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
