import 'dart:ui' as ui;
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
import 'package:theater_app/features/games/ui/figure_detail.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_cards.dart';
import 'package:theater_app/features/games/ui/wardrobe_overview.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// The collection at a glance (totals, rarities, plays, the way to the
// unique figures), the page of an owned figure, and the present figure
// (`runnerGiftFigure`): Engel Logge only for accounts without one.

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
  'runnerGiftFigure',
  'runnerCollection',
];

JsonMap _figure(
  String id,
  String name,
  String rarity, {
  String? role,
  String? play,
  int? year,
  int? personId,
  String? reason,
}) => {
  'id': id,
  'kind': 'character',
  'name': name,
  'rarity': rarity,
  'rarities': [rarity],
  'role': ?role,
  'play': ?play,
  'year': ?year,
  'personId': ?personId,
  'rarityReason': ?reason,
};

JsonMap _default(String id, String kind, [String? name]) => {
  'id': id,
  'kind': kind,
  'name': name ?? id,
  'rarity': 'hellblau',
  'rarities': ['hellblau'],
  'default': true,
};

final _rarities = [
  for (final (id, name, color, weight) in [
    ('hellblau', 'Hellblau', '#5E98D9', 45),
    ('technik', 'Technik', '#2FBF71', 11),
    ('pink', 'Pink', '#D32CE6', 12),
    ('gold', 'Gold', '#E4AE39', 1.5),
  ])
    {'id': id, 'name': name, 'color': color, 'weight': weight, 'gage': 10},
];

final _figures = [
  _figure(
    'character.elena',
    'Elena',
    'gold',
    role: 'Lucy',
    play: 'Creepshow',
    year: 2026,
    personId: 6,
    reason: 'Die meisten Wörter des Stücks.',
  ),
  _figure(
    'character.elena--anno',
    'Elena',
    'hellblau',
    role: 'Johanna',
    play: 'Anno 1146',
    year: 2025,
    personId: 6,
  ),
  _figure(
    'character.sebastian',
    'Sebastian',
    'pink',
    role: 'Butler Wilson',
    play: 'Creepshow',
    year: 2026,
    personId: 4,
  ),
  _figure(
    'character.linak',
    'Lina K.',
    'hellblau',
    role: 'Portrait',
    play: 'Creepshow',
    year: 2026,
    personId: 15,
  ),
  _figure(
    'character.florian',
    'Florian',
    'technik',
    role: 'Lichttechnik',
    personId: 35,
  ),
];

/// A wardrobe as the server sends it; with [gift] the present figure and
/// Engel Logge among the `hiddenDefaults`.
JsonMap _json({
  List<String> owned = const ['character.elena--anno', 'character.linak'],
  String? gift = 'character.elena--anno',
  String worn = 'character.elena--anno',
  List<String> shiny = const [],
  JsonMap? dupeCounts,
}) => {
  'progress': {
    'meters': 2900,
    'earned': 4,
    'opened': 3,
    'crates': 1,
    'previousAt': 2000,
    'nextAt': 4100,
    'poolSize': 5,
    'dupes': true,
  },
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': _rarities,
    'departments': [],
    'dupes': {
      'shinyChance': {'costume': .03},
      'tradeDupes': 5,
      'buyDupes': 10,
    },
    'items': [
      _default('character.engel-logge', 'character', 'Engel Logge'),
      _default('b0', 'backdrop'),
      _default('o0', 'obstacles'),
      _default('f0', 'fx'),
      ..._figures,
    ],
    'rewards': [],
    'uniqueRarity': {'id': 'unique', 'name': 'Unique', 'color': '#B388FF'},
    'uniques': [],
  },
  'lockedRarities': [],
  'owned': [
    if (gift == null) 'character.engel-logge',
    'b0',
    'o0',
    'f0',
    ...owned,
  ],
  'gift': gift,
  'hiddenDefaults': [if (gift != null) 'character.engel-logge'],
  'selected': {
    'character': worn,
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'stats': {'rounds': 3, 'best': 100, 'meters': 2900},
  'shiny': shiny,
  'variants': [],
  'selectedVariants': {},
  'gage': {'balance': 30, 'earned': 120},
  'trades': [],
  'roleFigures': true,
  'dupeCounts': ?dupeCounts,
  'uniqueFigures': {
    'plays': [
      {'play': 'Creepshow', 'year': 2026, 'have': 1, 'total': 3},
    ],
    'unseen': [],
  },
};

/// [_json] with the server's numbers of the collection (`collection`):
/// the figures with pictures, a backdrop with one, one a release gives
/// everybody, one without a picture and an owned ensemble reward; the
/// server's total also holds a secret unique figure.
JsonMap _counted({bool collection = true}) {
  final json = _json(
    owned: [
      'character.elena--anno',
      'character.linak',
      'bd.pic',
      'bd.free',
      'bd.reward',
    ],
  );
  final catalog = {...jsonMap(json['catalog'])};
  JsonMap backdrop(String id, {bool image = true}) => {
    'id': id,
    'kind': 'backdrop',
    'name': id,
    'rarity': 'hellblau',
    'rarities': ['hellblau'],
    if (image) 'image': '/games/runner/skins/$id.webp',
  };
  catalog['items'] = [
    for (final i in jsonList(catalog['items']))
      if (jsonMap(i)['kind'] == 'character' && jsonMap(i)['default'] != true)
        {...jsonMap(i), 'image': '/games/runner/skins/figure.webp'}
      else
        i,
    backdrop('bd.pic'),
    backdrop('bd.free'),
    backdrop('bd.noimg', image: false),
  ];
  catalog['rewards'] = [
    {...backdrop('bd.reward'), 'reward': true, 'rarity': 'ensemble'},
  ];
  json['catalog'] = catalog;
  if (collection) {
    json['collection'] = {
      'owned': 3,
      'total': 7,
      'shiny': 0,
      'free': ['bd.free'],
    };
  }
  return json;
}

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

  group('the present figure', () {
    test('with a gift Engel Logge is not owned and the gift is worn', () {
      final w = Wardrobe.fromJson(_json(worn: ''));
      final engel = w.catalog.item('character.engel-logge')!;
      expect(w.gift, 'character.elena--anno');
      expect(w.hiddenDefaults, {'character.engel-logge'});
      expect(w.owns(engel), isFalse);
      expect(w.isGift(w.catalog.item('character.elena--anno')!), isTrue);
      expect(w.isGift(w.catalog.item('character.linak')!), isFalse);
      // The other defaults stay everybody's.
      expect(w.owns(w.catalog.item('b0')!), isTrue);
      // Nothing chosen: the present, not Engel Logge.
      expect(w.worn(WardrobeKind.character)?.id, 'character.elena--anno');
    });

    test('without a gift Engel Logge stays the default', () {
      final w = Wardrobe.fromJson(_json(gift: null, worn: ''));
      expect(w.gift, isNull);
      expect(w.owns(w.catalog.item('character.engel-logge')!), isTrue);
      expect(w.worn(WardrobeKind.character)?.id, 'character.engel-logge');
    });

    test('older servers: defaults owned without listing them', () {
      final json = _json(gift: null)
        ..remove('gift')
        ..remove('hiddenDefaults')
        ..['owned'] = ['character.linak'];
      final w = Wardrobe.fromJson(json);
      expect(w.owns(w.catalog.item('character.engel-logge')!), isTrue);
    });

    test('the gift is read tolerantly and only for a known item', () {
      JsonMap with_(Object? gift) => _json()..['gift'] = gift;
      expect(
        Wardrobe.fromJson(with_({'itemId': 'character.linak'})).gift,
        'character.linak',
      );
      expect(Wardrobe.fromJson(with_('character.nobody')).gift, isNull);
      expect(Wardrobe.fromJson(with_('')).gift, isNull);
    });
  });

  group('the overview', () {
    test('counts everything, by rarity and by play, rarest first', () {
      final o = WardrobeOverview.of(
        Wardrobe.fromJson(_json(shiny: ['character.linak'])),
      );
      expect((o.all.owned, o.all.total), (2, 5));
      expect(o.all.text, '2 von 5');
      expect(
        [for (final r in o.rarities) r.rarity.id],
        ['gold', 'pink', 'technik', 'hellblau'],
      );
      final hellblau = o.rarities.last.tally;
      expect((hellblau.owned, hellblau.total, hellblau.complete), (2, 2, true));
      // Newest play first, the technicians last.
      expect(
        [for (final p in o.plays) p.title],
        ['Creepshow 2026', 'Anno 1146 2025', 'Technik'],
      );
      final creepshow = o.plays.first;
      expect(creepshow.tally.text, '1 von 3');
      // What is missing by rarity, never by name.
      expect(creepshow.missingText, 'noch offen: 1 × Gold, 1 × Pink');
      expect(creepshow.missingText, isNot(contains('Elena')));
      expect(o.plays[1].tally.complete, isTrue);
      expect(o.plays[1].missingText, isNull);
      expect(o.plays.last.technicians, isTrue);
      expect(o.plays.last.production, isNull);
      expect(o.shiny, 1);
      expect(o.gift?.id, 'character.elena--anno');
      expect((o.uniques!.owned, o.uniques!.total), (0, 1));
    });

    test('the server\'s numbers count, the breakdown by the same rules', () {
      final w = Wardrobe.fromJson(_counted());
      expect((w.collection?.owned, w.collection?.total), (3, 7));
      expect(w.collection?.free, {'bd.free'});
      // The menu's "Dein Stand" shows the same as the Sammel-Rangliste.
      expect('${w.collected}/${w.collectible}', '3/7');
      final o = WardrobeOverview.of(w);
      expect(o.all.text, '3 von 7');
      // Neither the free backdrop nor the one without a picture, nor the
      // ensemble reward counts.
      final backdrops = o.kinds[WardrobeKind.backdrop]!;
      expect((backdrops.owned, backdrops.total), (1, 1));
      final figures = o.kinds[WardrobeKind.character]!;
      expect((figures.owned, figures.total), (2, 5));
      // Older servers: the app's own count, as before.
      final older = Wardrobe.fromJson(_counted(collection: false));
      expect(older.collection, isNull);
      expect('${older.collected}/${older.collectible}', '4/8');
      final before = WardrobeOverview.of(older);
      expect(before.all.text, '4 von 8');
      expect(before.kinds[WardrobeKind.backdrop]!.total, 3);
      // Read tolerantly: without numbers no collection.
      expect(
        Wardrobe.fromJson(
          _counted()..['collection'] = {'owned': 'x'},
        ).collection,
        isNull,
      );
    });

    test('the way to a unique figure keeps its secret', () {
      final o = WardrobeOverview.of(Wardrobe.fromJson(_json()));
      final creepshow = o.plays.first;
      expect(creepshow.uniqueText, 'Unique: noch 2 Rollen');
      expect(o.plays[1].uniqueText, isNull);
      const one = PlayTally(
        title: 'X',
        tally: Tally(1, 2),
        unique: UniqueFigureProgress(play: 'X', have: 1, total: 2),
      );
      expect(one.uniqueText, 'Unique: noch 1 Rolle');
      const done = PlayTally(
        title: 'X',
        tally: Tally(2, 2),
        unique: UniqueFigureProgress(
          play: 'X',
          have: 2,
          total: 2,
          unlocked: true,
          itemId: 'u',
          name: 'Captain Kuschel',
        ),
      );
      expect(done.uniqueText, 'Unique freigeschaltet');
      // Without the unique figures (older apps) none at all.
      expect(
        WardrobeOverview.of(
          Wardrobe.fromJson(_json()),
          unique: false,
        ).plays.first.unique,
        isNull,
      );
    });
  });

  test('the showcase loops through run, flight, sinking and cheer', () {
    expect(RunnerSprite.strides, contains(showcasePose(0).sprite));
    expect(showcasePose(0).lift, 0);
    expect(showcasePose(2.9).sprite, RunnerSprite.fly);
    expect(showcasePose(3.39).lift, greaterThan(.9));
    expect(showcasePose(4).sprite, RunnerSprite.dangle);
    expect(showcasePose(5).sprite, RunnerSprite.cheer);
    expect(showcasePose(5).lift, 0);
    // Again from the start.
    expect(showcasePose(showcasePeriod + 2.9).sprite, showcasePose(2.9).sprite);
    // The run changes its stride like the game.
    final strides = {
      for (var t = 0.0; t < 2.4; t += .05) showcasePose(t).sprite,
    };
    expect(strides, RunnerSprite.strides.toSet());
  });

  group('the wardrobe', () {
    Future<List<JsonMap>> open(WidgetTester tester, JsonMap json) async {
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
          return Future.value(jsonResponse(json));
        }
        return null;
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);
      return bodies;
    }

    testWidgets('the summary, the plays, and no Engel Logge with a gift', (
      tester,
    ) async {
      await open(tester, _json());
      expect(find.byKey(const ValueKey('wardrobe-summary')), findsOneWidget);
      expect(find.text('2 von 5'), findsOneWidget);
      expect(find.text('1 Kiste wartet'), findsOneWidget);
      expect(find.text('Unique 0/1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('wardrobe-play-Creepshow 2026')),
        findsOneWidget,
      );
      expect(find.text('Unique: noch 2 Rollen'), findsOneWidget);
      // The present is marked, Engel Logge is not in the collection.
      expect(
        find.byKey(const ValueKey('wardrobe-character.engel-logge')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('card-gift')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Elena als Johanna.*Geschenk')),
        findsOneWidget,
      );
      // A missing card says where it belongs, not who.
      expect(
        find.bySemanticsLabel('Noch nicht gefunden, Gold, Creepshow 2026'),
        findsOneWidget,
      );

      // A tap on a play shows only its figures.
      await tester.tap(find.byKey(const ValueKey('wardrobe-play-Technik')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('wardrobe-character.florian')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.linak')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('wardrobe-play-Technik')));
      await _settle(tester);
      // Only the missing ones.
      await tester.tap(find.byKey(const ValueKey('wardrobe-missing-only')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('wardrobe-character.linak')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena')),
        findsOneWidget,
      );

      // The crates in numbers.
      await tester.tap(find.byKey(const ValueKey('wardrobe-tab-crates')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('crate-balance')), findsOneWidget);
      expect(find.bySemanticsLabel('geöffnet: 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Gage verdient: 120'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tap on the waiting crates opens the crates tab', (
      tester,
    ) async {
      await open(tester, _json());
      expect(find.byKey(const ValueKey('crate-balance')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('wardrobe-summary-crates')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crate-balance')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the kind chip and its section count the same', (tester) async {
      await open(tester, _counted());
      expect(find.text('3 von 7'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('wardrobe-kind-backdrop')));
      await _settle(tester);
      expect(find.text('Bühnenbilder · 1/1'), findsOneWidget);
      // The ensemble reward is shown, but does not count.
      expect(find.byKey(const ValueKey('wardrobe-bd.reward')), findsOneWidget);
      expect(find.text('Bühnenbilder: 1 von 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without a gift Engel Logge is in the collection', (
      tester,
    ) async {
      await open(tester, _json(gift: null, worn: 'character.engel-logge'));
      expect(
        find.byKey(const ValueKey('wardrobe-character.engel-logge')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('card-gift')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an owned figure has a page of its own', (tester) async {
      final bodies = await open(
        tester,
        _json(
          owned: [
            'character.elena--anno',
            'character.elena',
            'character.linak',
          ],
          shiny: ['character.elena'],
          dupeCounts: {'character.elena': 2},
        ),
      );
      await tester.tap(find.byKey(const ValueKey('wardrobe-character.elena')));
      await _settle(tester);
      expect(find.byType(FigureDetailPage), findsOneWidget);
      expect(find.text('als Lucy · Creepshow 2026'), findsOneWidget);
      expect(find.text('Figur · Gold'), findsOneWidget);
      expect(find.text('Die meisten Wörter des Stücks.'), findsOneWidget);
      expect(find.text('Warum Gold?'), findsOneWidget);
      expect(find.byKey(const ValueKey('figure-shiny')), findsOneWidget);
      expect(find.text('2 Duplikate gezogen'), findsOneWidget);
      expect(find.byKey(const ValueKey('figure-gift')), findsNothing);
      expect(find.text('Creepshow'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);
      // Elena's other role, the present.
      expect(find.text('Weitere Rollen von Elena'), findsOneWidget);
      expect(find.text('2 von 2 gefunden'), findsOneWidget);
      final other = find.byKey(
        const ValueKey('figure-role-character.elena--anno'),
      );
      expect(other, findsOneWidget);
      expect(tester.widget<WardrobeCard>(other).small, isTrue);
      await tester.tap(other);
      await _settle(tester);
      expect(find.text('als Johanna · Anno 1146 2025'), findsWidgets);
      expect(find.byKey(const ValueKey('figure-gift')), findsOneWidget);
      // Worn already.
      expect(find.text('Anlegen'), findsNothing);
      expect(find.text('Angelegt'), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('figure-role-character.elena')),
      );
      await _settle(tester);
      await tester.tap(find.text('Anlegen'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(bodies.single['itemId'], 'character.elena');
      expect(find.byType(FigureDetailPage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a missing figure keeps its secret: no page, the details', (
      tester,
    ) async {
      await open(tester, _json());
      await tester.tap(find.byKey(const ValueKey('wardrobe-character.elena')));
      await _settle(tester);
      expect(find.byType(FigureDetailPage), findsNothing);
      expect(find.text('Noch nicht gefunden'), findsOneWidget);
      expect(find.text('Lucy'), findsNothing);
      expect(find.text('Anlegen'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the showcase plays the figure on the wire and can pause', (
    tester,
  ) async {
    final controller = await _signedIn((_) => null);
    final w = Wardrobe.fromJson(_json());
    final art = await tester.runAsync(() async {
      final recorder = PictureRecorderImage();
      return RunnerArt.test(
        await recorder.image(1124, 580),
        await recorder.image(64, 36),
      );
    });
    await _pump(
      tester,
      FigureDetailPage(
        wardrobe: w,
        item: w.catalog.item('character.linak')!,
        controller: controller,
        art: art,
      ),
    );
    await _settle(tester);
    expect(find.byType(FigureShowcase), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Lina K. als Portrait am Flugseil')),
      findsOneWidget,
    );
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('figure-play')));
    await tester.pump();
    expect(find.byTooltip('Animation abspielen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Blank pictures of a size, for art in tests.
class PictureRecorderImage {
  Future<ui.Image> image(int width, int height) {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF888888),
    );
    return recorder.endRecording().toImage(width, height);
  }
}
