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
import 'package:theater_app/features/games/ui/wardrobe_cards.dart';
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
  JsonMap progress = const {},
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
    ...progress,
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
      WardrobePictures.retryDelay = Duration.zero;
      addTearDown(
        () => WardrobePictures.retryDelay = const Duration(seconds: 1),
      );
      var asked = 0;
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner', 'runnerUnlocks'],
      };
      server.override = (request) {
        if (!_path(request).contains('/games/runner/skins/')) return null;
        asked++;
        return Future.value(http.Response('', 404));
      };
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
        expect(asked, 2, reason: 'asked once more before falling back');
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

    test('a role whose atlas fails once is asked again, not Logge', () async {
      WardrobePictures.retryDelay = Duration.zero;
      addTearDown(
        () => WardrobePictures.retryDelay = const Duration(seconds: 1),
      );
      final own = await createTestImage(width: 1124, height: 577);
      final png = (await own.toByteData(format: ui.ImageByteFormat.png))!;
      final asked = <String>[];
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner', 'runnerUnlocks'],
      };
      server.override = (request) {
        if (!_path(request).contains('/games/runner/skins/')) return null;
        asked.add(_path(request));
        // A dropped connection the first time, the picture the second.
        return Future.value(
          asked.length == 1
              ? http.Response('', 503)
              : http.Response.bytes(
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
        owned: ['elena'],
        selected: {'character': 'elena'},
      );
      // Elena as Johanna: the role's atlas, not her own.
      final items = jsonList(jsonMap(json['catalog'])['items']);
      (items[5] as Map)
        ..['image'] = '/games/runner/skins/character-elena.webp?v=1'
        ..['variants'] = [
          {
            'id': 'elena--anno',
            'role': 'Johanna',
            'play': 'Anno 1146',
            'year': 2025,
            'image': '/games/runner/skins/character-elena--anno.webp?v=2',
            'harness': {
              'fly': [106, 42],
            },
          },
        ];
      json['variants'] = ['elena--anno'];
      json['selectedVariants'] = {'elena': 'elena--anno'};
      final dressed = await dressArt(
        RunnerArt.test(atlas, backdrop),
        Wardrobe.fromJson(json),
        controller,
      );
      expect(asked, [
        '/api/mobile/v1/games/runner/skins/character-elena--anno.webp',
        '/api/mobile/v1/games/runner/skins/character-elena--anno.webp',
      ]);
      expect(dressed.imageOf(RunnerSprite.cheer), isNot(atlas));
      expect(dressed.harnessOf(RunnerSprite.fly), const ui.Offset(106, 42));
    });

    testWidgets('a card shows the pictures of the role chosen on it', (
      tester,
    ) async {
      final asked = <String>[];
      final controller = await _signedIn(tester, (request) {
        if (!_path(request).contains('/games/runner/skins/')) return null;
        asked.add(_path(request).split('/').last);
        return Future.value(http.Response('', 404));
      });
      const role = WardrobeVariant(
        id: 'elena--anno',
        name: 'Johanna (Anno 1146, 2025)',
        image: '/games/runner/skins/character-elena--anno.webp',
        portrait: '/games/runner/skins/character-elena--anno-portrait.webp',
      );
      const elena = WardrobeItem(
        id: 'elena',
        kind: WardrobeKind.character,
        name: 'Elena',
        rarity: 'gold',
        image: '/games/runner/skins/character-elena.webp',
        portrait: '/games/runner/skins/character-elena-portrait.webp',
        variants: [role],
      );
      Widget card(WardrobeVariant? variant) => Directionality(
        textDirection: TextDirection.ltr,
        child: WardrobeItemArt(
          item: elena.inRole(variant),
          controller: controller,
        ),
      );
      await tester.pumpWidget(card(null));
      await tester.pump();
      await tester.pump();
      expect(asked, contains('character-elena-portrait.webp'));
      // Same figure, other role: its own pictures are fetched.
      await tester.pumpWidget(card(role));
      await tester.pump();
      await tester.pump();
      expect(asked, contains('character-elena--anno-portrait.webp'));
    });

    test('the picture cache keeps by bytes, drops the least used first and '
        'the game decodes a dropped atlas again from its kept file', () async {
      final maxBytes = WardrobePictures.maxBytes;
      addTearDown(() => WardrobePictures.maxBytes = maxBytes);
      final own = await createTestImage(width: 1124, height: 577);
      final png = (await own.toByteData(format: ui.ImageByteFormat.png))!;
      const size = 1124 * 577 * 4;
      // Room for two atlases.
      WardrobePictures.maxBytes = 2 * size + 1000;
      final asked = <String>[];
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner', 'runnerUnlocks'],
      };
      server.override = (request) {
        if (!_path(request).contains('/games/runner/skins/')) return null;
        asked.add(_path(request).split('/').last);
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
      const a = '/games/runner/skins/a.webp', b = '/games/runner/skins/b.webp';
      const c = '/games/runner/skins/c.webp';
      await WardrobePictures.load(controller, a);
      await WardrobePictures.load(controller, b);
      // Used again: b is now the least used one.
      expect(WardrobePictures.cached(a), isNotNull);
      await WardrobePictures.load(controller, c);
      expect(WardrobePictures.cached(b), isNull);
      expect(WardrobePictures.cached(a), isNotNull);
      expect(WardrobePictures.cached(c), isNotNull);
      expect(WardrobePictures.bytes, 2 * size);

      // Maren's atlas was dropped: the game decodes it again instead of
      // dressing her as Engel Logge, from the file kept from before.
      final atlas = await createTestImage(width: 1124, height: 577);
      final backdrop = await createTestImage(width: 64, height: 32);
      final json = _wardrobeJson(
        owned: ['maren'],
        selected: {'character': 'maren'},
      );
      final items = jsonList(jsonMap(json['catalog'])['items']);
      (items[4] as Map)['image'] = b;
      final dressed = await dressArt(
        RunnerArt.test(atlas, backdrop),
        Wardrobe.fromJson(json),
        controller,
      );
      expect(asked, ['a.webp', 'b.webp', 'c.webp']);
      expect(dressed.imageOf(RunnerSprite.cheer), isNot(atlas));
      expect(dressed.runnerPaint.colorFilter, isNotNull, reason: 'her tint');
      expect(WardrobePictures.cached(b), isNotNull);
    });

    test('dropped pictures come back without the server while their files '
        'fit; a failed one is not asked for on every rebuild', () async {
      final (maxBytes, maxFiles) = (
        WardrobePictures.maxBytes,
        WardrobePictures.maxFileBytes,
      );
      final pause = WardrobePictures.failurePause;
      addTearDown(() {
        WardrobePictures.maxBytes = maxBytes;
        WardrobePictures.maxFileBytes = maxFiles;
        WardrobePictures.failurePause = pause;
      });
      final portrait = await createTestImage(width: 64, height: 64);
      final png = (await portrait.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      // A long wardrobe: decoded, only one portrait fits; as files, two.
      WardrobePictures.maxBytes = 64 * 64 * 4;
      WardrobePictures.maxFileBytes = 2 * png.length;
      final asked = <String>[];
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner', 'runnerUnlocks'],
      };
      server.override = (request) {
        if (!_path(request).contains('/games/runner/skins/')) return null;
        final name = _path(request).split('/').last;
        asked.add(name);
        return Future.value(
          name == 'gone.webp'
              ? http.Response('', 404)
              : http.Response.bytes(
                  png,
                  200,
                  headers: {'content-type': 'image/png'},
                ),
        );
      };
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      const a = '/games/runner/skins/a.webp', b = '/games/runner/skins/b.webp';
      const c = '/games/runner/skins/c.webp';
      // Scrolled down and up again: a and b are decoded anew, not fetched.
      for (final path in [a, b, a, b, a]) {
        expect(await WardrobePictures.load(controller, path), isNotNull);
      }
      expect(asked, ['a.webp', 'b.webp']);
      expect(WardrobePictures.fileBytes, 2 * png.length);
      // A third file drops the least used one (b); only that is asked
      // for again.
      await WardrobePictures.load(controller, c);
      await WardrobePictures.load(controller, a);
      await WardrobePictures.load(controller, b);
      expect(asked, ['a.webp', 'b.webp', 'c.webp', 'b.webp']);
      expect(WardrobePictures.fileBytes, 2 * png.length);

      // A missing picture: a card rebuilding without it does not ask again
      // and again; after the pause it is tried anew.
      const gone = '/games/runner/skins/gone.webp';
      asked.clear();
      for (var i = 0; i < 5; i++) {
        expect(await WardrobePictures.load(controller, gone), isNull);
      }
      expect(asked, ['gone.webp']);
      WardrobePictures.failurePause = Duration.zero;
      expect(await WardrobePictures.load(controller, gone), isNull);
      expect(asked, ['gone.webp', 'gone.webp']);
    });

    test(
      'a card waits on a neutral placeholder, never on Engel Logge',
      () async {
        final atlas = await createTestImage(width: 1124, height: 577);
        final backdrop = await createTestImage(width: 64, height: 32);
        final base = RunnerArt.test(atlas, backdrop);
        const elena = WardrobeItem(
          id: 'elena',
          kind: WardrobeKind.character,
          name: 'Elena',
          rarity: 'gold',
          image: '/games/runner/skins/character-elena.webp',
          portrait: '/games/runner/skins/character-elena-portrait.webp',
        );
        const rect = Rect.fromLTWH(0, 0, 120, 150);
        // Her pictures are not there (yet, or dropped): a placeholder.
        final waiting = _DrawnImages();
        paintItemArt(waiting, rect, elena, base);
        expect(waiting.images, isEmpty);
        expect(waiting.rrects, hasLength(1));
        // Once held, her portrait.
        final portrait = await createTestImage(width: 512, height: 512);
        final shown = _DrawnImages();
        paintItemArt(shown, rect, elena, base, portrait: portrait);
        expect(shown.images, [portrait]);
        // A stand-in without pictures keeps the default art in its tint.
        final standIn = _DrawnImages();
        paintItemArt(
          standIn,
          rect,
          const WardrobeItem(
            id: 'maren',
            kind: WardrobeKind.character,
            name: 'Maren',
            rarity: 'technik',
            placeholder: true,
          ),
          base,
        );
        expect(standIn.images, [atlas]);
      },
    );

    testWidgets('a card keeps its picture when the cache drops it', (
      tester,
    ) async {
      final png = (await tester.runAsync(() async {
        final image = await createTestImage(width: 512, height: 512);
        return image.toByteData(format: ui.ImageByteFormat.png);
      }))!;
      var fetched = 0;
      final controller = await _signedIn(tester, (request) {
        if (!_path(request).contains('/games/runner/skins/')) return null;
        fetched++;
        return Future.value(
          http.Response.bytes(
            png.buffer.asUint8List(),
            200,
            headers: {'content-type': 'image/png'},
          ),
        );
      });
      const elena = WardrobeItem(
        id: 'elena',
        kind: WardrobeKind.character,
        name: 'Elena',
        rarity: 'gold',
        portrait: '/games/runner/skins/character-elena-portrait.webp',
      );
      final portrait = await tester.runAsync(
        () => WardrobePictures.load(controller, elena.portrait),
      );
      expect(portrait, isNotNull);
      Widget card() => Directionality(
        textDirection: TextDirection.ltr,
        child: WardrobeItemArt(item: elena, controller: controller),
      );
      ui.Image? drawn() {
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(WardrobeItemArt),
            matching: find.byType(CustomPaint),
          ),
        );
        final canvas = _DrawnImages();
        paint.painter!.paint(canvas, const Size(120, 150));
        return canvas.images.firstOrNull;
      }

      await tester.pumpWidget(card());
      expect(drawn(), portrait);
      // Many other pictures later the cache has dropped hers; a rebuild
      // still shows her.
      WardrobePictures.clear();
      await tester.pumpWidget(card());
      expect(drawn(), portrait);
      expect(fetched, 1);
    });

    test(
      'a backdrop brings its obstacles and the colour of its border',
      () async {
        final own = await createTestImage(width: 1124, height: 577);
        final png = (await own.toByteData(format: ui.ImageByteFormat.png))!;
        final asked = <String>[];
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['stageRunner', 'runnerUnlocks'],
        };
        server.override = (request) {
          if (!_path(request).contains('/games/runner/skins/')) return null;
          asked.add(_path(request));
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
        final base = RunnerArt.test(atlas, backdrop);
        JsonMap wearing(String? stage) {
          final json = _wardrobeJson(
            owned: ['gruft'],
            selected: {'backdrop': ?stage},
          );
          jsonList(jsonMap(json['catalog'])['items']).add(
            _item(
              'gruft',
              'backdrop',
              'Gruft',
              'hellblau',
              extra: {
                'image': '/games/runner/skins/backdrop-gruft.webp?v=1',
                'obstacles': '/games/runner/skins/obstacles-gruft.webp?v=1',
                'borderColor': '#3E2A5C',
                'collectibles':
                    '/games/runner/skins/collectibles-gruft.webp?v=1',
                'collectibleNames': {'rose': 'Bonbon', 'star': 'Vollmond'},
              },
            ),
          );
          return json;
        }

        final item = Wardrobe.fromJson(wearing('gruft')).catalog.items.last;
        expect(item.obstacles, '/games/runner/skins/obstacles-gruft.webp?v=1');
        expect(item.borderColor, const Color(0xFF3E2A5C));
        final dressed = await dressArt(
          base,
          Wardrobe.fromJson(wearing('gruft')),
          controller,
        );
        expect(asked, contains(contains('obstacles-gruft.webp')));
        expect(dressed.imageOf(RunnerSprite.crate), isNot(atlas));
        expect(dressed.imageOf(RunnerSprite.cheer), atlas);
        expect(dressed.border, const Color(0xFF3E2A5C));
        // Its collectibles replace rose, mask and star, with their names.
        expect(asked, contains(contains('collectibles-gruft.webp')));
        expect(dressed.imageOf(RunnerSprite.star), isNot(atlas));
        expect(dressed.pickupNames, {
          PickupKind.rose: 'Bonbon',
          PickupKind.star: 'Vollmond',
        });
        // The default stage keeps the game's own obstacles and red border.
        final plain = await dressArt(
          base,
          Wardrobe.fromJson(wearing(null)),
          controller,
        );
        expect(plain.imageOf(RunnerSprite.crate), atlas);
        expect(plain.border, isNull);
        expect(plain.imageOf(RunnerSprite.rose), atlas);
        expect(plain.pickupNames, isEmpty);
        // Older servers send neither; a broken colour is no colour.
        final old = WardrobeItem.fromJson({
          ..._item('b1', 'backdrop', 'Alt', 'hellblau'),
          'borderColor': 'red',
        })!;
        expect(old.obstacles, isNull);
        expect(old.borderColor, isNull);
      },
    );

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
              _wardrobeJson(owned: ['maren'], selected: {'character': 'maren'}),
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

    group('Tagesbonus', () {
      // What a server with the bonus sends, whether or not it announces it.
      final bonusWardrobe = _wardrobeJson(
        crates: 0,
        progress: {'runMeters': 2488, 'bonusMeters': 412, 'bonusOpen': true},
        stats: {'rounds': 5, 'best': 900, 'meters': 2488, 'bonusMeters': 412},
      );
      final runReply = {
        'meters': 4524,
        'earned': 2,
        'opened': 1,
        'crates': 1,
        'previousAt': 4100,
        'nextAt': 6300,
        'poolSize': 3,
        'complete': false,
        'runMeters': 3300,
        'bonusMeters': 1224,
        'bonusOpen': false,
        'gained': 812,
        'bonus': 812,
        'newCrates': 1,
      };
      Future<AppController> server(
        WidgetTester tester,
        List<String> features,
      ) => _signedIn(tester, (request) {
        final path = _path(request);
        if (path.endsWith('/leaderboard')) {
          return Future.value(
            jsonResponse({'players': 0, 'top': [], 'own': null}),
          );
        }
        if (path.endsWith('/wardrobe')) {
          return Future.value(jsonResponse(bonusWardrobe));
        }
        if (path.endsWith('/rounds')) {
          return Future.value(jsonResponse({'roundId': 'r-1'}));
        }
        if (path.endsWith('/scores')) {
          return Future.value(
            jsonResponse({
              'score': 10,
              'improved': false,
              'leaderboard': {'players': 0, 'top': [], 'own': null},
              'progress': runReply,
            }),
          );
        }
        return null;
      }, features: features);

      Future<void> run(WidgetTester tester) async {
        await tester.tap(find.text('Vorhang auf'));
        for (
          var i = 0;
          i < 60 * 20 && find.text('Nochmal').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pump(const Duration(milliseconds: 100));
      }

      test('reads the bonus; older servers leave it out', () {
        final p = RunnerProgress.fromJson(runReply);
        expect(
          [p.meters, p.runMeters, p.bonusMeters, p.bonus],
          [4524, 3300, 1224, 812],
        );
        expect(p.bonusOpen, isFalse);
        expect(p.fraction, closeTo(424 / 2200, 1e-9));
        final old = RunnerProgress.fromJson({'meters': 2900, 'gained': 250});
        expect([old.runMeters, old.bonusMeters, old.bonus], [2900, 0, 0]);
        expect(old.bonusOpen, isFalse);
      });

      testWidgets('with the feature: a hint before the run, the bonus after', (
        tester,
      ) async {
        final controller = await server(tester, const [
          'stageRunner',
          'runnerUnlocks',
          'runnerDailyBonus',
        ]);
        await _pump(
          tester,
          StageRunnerScreen(
            controller: controller,
            random: Random(3),
            sound: _Sound(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text(dailyBonusHint), findsOneWidget);
        await run(tester);
        expect(
          find.text(
            '+812 m · Tagesbonus +812 m · noch 1.776 m bis zur nächsten Kiste',
          ),
          findsOneWidget,
        );
        final bar = tester.widget<LinearProgressIndicator>(
          find.descendant(
            of: find.byKey(const ValueKey('runner-progress')),
            matching: find.byType(LinearProgressIndicator),
          ),
        );
        expect(bar.value, closeTo(424 / 2200, 1e-9));
        // Used up: no more hint after the run.
        expect(find.text(dailyBonusHint), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('without the feature nothing of it shows', (tester) async {
        final controller = await server(tester, const [
          'stageRunner',
          'runnerUnlocks',
        ]);
        await _pump(
          tester,
          StageRunnerScreen(
            controller: controller,
            random: Random(3),
            sound: _Sound(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text(dailyBonusHint), findsNothing);
        await run(tester);
        expect(
          find.text('+812 m · noch 1.776 m bis zur nächsten Kiste'),
          findsOneWidget,
        );
        expect(find.textContaining('Tagesbonus'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });

      for (final supported in [true, false]) {
        testWidgets(
          'the wardrobe lists the bonus only with the feature ($supported)',
          (tester) async {
            final controller = await server(tester, [
              'stageRunner',
              'runnerUnlocks',
              if (supported) 'runnerDailyBonus',
            ]);
            await _pump(
              tester,
              WardrobeScreen(controller: controller, sound: _Sound()),
            );
            await tester.pump(const Duration(milliseconds: 100));
            expect(
              find.text(
                supported
                    ? '2.488 m gelaufen + 412 m Tagesbonus · noch 1.200 m bis zur nächsten Kiste'
                    : '2.900 m gelaufen · noch 1.200 m bis zur nächsten Kiste',
              ),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('wardrobe-daily-bonus')),
              supported ? findsOneWidget : findsNothing,
            );
            await tester.tap(find.text('Statistik'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            // The Gesamtstrecke stays the real metres.
            expect(find.text('2.488 m'), findsOneWidget);
            expect(
              find.text(
                'Tagesbonus gesamt: 412 m · zählt nur für die Kisten (Kistenstrecke 2.900 m).',
              ),
              supported ? findsOneWidget : findsNothing,
            );
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
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

/// Records the pictures and rounded boxes drawn; everything else is ignored.
class _DrawnImages implements Canvas {
  final images = <ui.Image>[];
  final rrects = <RRect>[];

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) =>
      images.add(image);

  @override
  void drawRRect(RRect rrect, Paint paint) => rrects.add(rrect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
