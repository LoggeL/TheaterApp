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
import 'package:theater_app/features/games/ui/crate_opening.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// Role figures (`runnerRoleFigures`): one card per stage role, grouped by
// rarity and filterable by play and person; the app asks for them with
// `roles` and has no role choice any more.

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
];

JsonMap _figure(
  String id,
  String name,
  String rarity, {
  String? role,
  String? play,
  int? year,
  int? personId,
  int? importance,
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
  'importance': ?importance,
};

JsonMap _default(String id, String kind) => {
  'id': id,
  'kind': kind,
  'name': id,
  'rarity': 'hellblau',
  'rarities': ['hellblau'],
  'default': true,
};

final _rarities = [
  for (final (id, name, color, weight) in [
    ('hellblau', 'Hellblau', '#5E98D9', 45),
    ('blau', 'Blau', '#4B69FF', 21),
    ('technik', 'Technik', '#2FBF71', 11),
    ('pink', 'Pink', '#D32CE6', 12),
    ('legacy', 'Legacy', '#A47A4B', 6),
    ('rot', 'Rot', '#EB4B4B', 3.5),
    ('gold', 'Gold', '#E4AE39', 1.5),
  ])
    {'id': id, 'name': name, 'color': color, 'weight': weight, 'gage': 10},
];

/// The figures of a small wardrobe: Elena in three plays, Sebastian in two,
/// Lina K. and a technician.
final _figures = [
  _figure(
    'character.elena',
    'Elena',
    'gold',
    role: 'Lucy',
    play: 'Creepshow',
    year: 2026,
    personId: 6,
    importance: 93,
  ),
  _figure(
    'character.elena--anno',
    'Elena',
    'gold',
    role: 'Johanna',
    play: 'Anno 1146',
    year: 2025,
    personId: 6,
    importance: 92,
  ),
  _figure(
    'character.elena--schicksal',
    'Elena',
    'rot',
    role: 'Eurydike',
    play: 'Schicksalsfäden',
    year: 2025,
    personId: 6,
    importance: 78,
  ),
  _figure(
    'character.sebastian',
    'Sebastian',
    'rot',
    role: 'Butler Wilson',
    play: 'Creepshow',
    year: 2026,
    personId: 4,
    importance: 80,
  ),
  _figure(
    'character.sebastian--anno',
    'Sebastian',
    'rot',
    role: 'Konrad',
    play: 'Anno 1146',
    year: 2025,
    personId: 4,
    importance: 74,
  ),
  _figure(
    'character.linak',
    'Lina K.',
    'hellblau',
    role: 'Portrait',
    play: 'Creepshow',
    year: 2026,
    personId: 15,
    importance: 18,
  ),
  _figure(
    'character.florian',
    'Florian',
    'technik',
    role: 'Lichttechnik',
    personId: 35,
  ),
];

/// A wardrobe as a server with role figures sends it.
JsonMap _json({
  List<String> owned = const ['character.elena--anno', 'character.linak'],
  List<JsonMap>? figures,
  String worn = 'c0',
}) => {
  'progress': {
    'meters': 2900,
    'earned': 1,
    'opened': 0,
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
      _default('c0', 'character'),
      _default('b0', 'backdrop'),
      _default('o0', 'obstacles'),
      _default('f0', 'fx'),
      ...figures ?? _figures,
    ],
    'rewards': [],
  },
  'lockedRarities': ['legacy'],
  'owned': ['c0', 'b0', 'o0', 'f0', ...owned],
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
};

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

  test('every role is a figure of its own: its role, its rarity', () {
    final w = Wardrobe.fromJson(_json(worn: 'character.elena--anno'));
    final johanna = w.catalog.item('character.elena--anno')!;
    expect(w.catalog.rarityOf(johanna).name, 'Gold');
    expect(johanna.importance, 92);
    expect(johanna.variants, isEmpty);
    expect(w.roleOf(johanna)?.line, 'als Johanna · Anno 1146 2025');
    expect(w.wornCharacterName(), 'Elena als Johanna');
    final florian = w.catalog.item('character.florian')!;
    expect(w.roleOf(florian)?.isFunction, isTrue);
    expect(nameInRole(florian.name, florian.role), 'Florian (Lichttechnik)');
    // Collected: the owned figures among all collectible items.
    expect('${w.collected}/${w.collectible}', '2/7');
  });

  test('owned or worn ids missing from the catalog are ignored', () {
    // Figures that left the catalog (e.g. new members without a picture
    // yet) count for nothing and are never worn.
    final w = Wardrobe.fromJson(
      _json(
        owned: const [
          'character.elena--anno',
          'character.linak',
          'character.lucia',
          'character.daniel',
        ],
        worn: 'character.lucia',
      ),
    );
    expect(w.catalog.item('character.lucia'), isNull);
    expect(w.worn(WardrobeKind.character)?.id, 'c0');
    expect(w.wornCharacterName(), 'c0');
    expect('${w.collected}/${w.collectible}', '2/7');
  });

  group('the app asks for role figures only when the server has them', () {
    for (final roles in [true, false]) {
      test('runnerRoleFigures ${roles ? 'on' : 'off'}', () async {
        final requests = <(String, JsonMap)>[];
        final controller = await _signedIn((request) {
          final path = _path(request);
          if (!path.contains('/games/runner/')) return null;
          requests.add((
            '$path ${request.url.queryParameters}',
            request.body.isEmpty ? {} : jsonMap(jsonDecode(request.body)),
          ));
          final w = _json();
          final item = _figures[1];
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
        }, features: roles ? _features : _features.take(3).toList());
        expect(roleFiguresAvailable(controller), roles);
        final w = await loadWardrobe(controller);
        await openCrate(controller, dupes: true);
        await wearItem(controller, w.catalog.item('character.elena--anno')!);
        await buyItem(controller, w.catalog.item('character.linak')!);
        expect(
          requests[0].$1.endsWith(
            '/games/runner/wardrobe ${roles ? '{roles: 1}' : '{}'}',
          ),
          isTrue,
          reason: requests[0].$1,
        );
        expect(requests[1].$2, {'dupes': true, if (roles) 'roles': true});
        expect(requests[2].$2, {
          'kind': 'character',
          'itemId': 'character.elena--anno',
          if (roles) 'roles': true,
        });
        expect(requests[3].$2['roles'], roles ? true : isNull);
      });
    }
  });

  group('the wardrobe', () {
    Future<List<JsonMap>> open(WidgetTester tester) async {
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
          return Future.value(jsonResponse(_json()));
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

    double top(WidgetTester tester, String key) =>
        tester.getTopLeft(find.byKey(ValueKey(key))).dy;

    testWidgets('one card per role, grouped by rarity from rare to common', (
      tester,
    ) async {
      await open(tester);
      for (final f in _figures) {
        expect(find.byKey(ValueKey('wardrobe-${f['id']}')), findsOneWidget);
      }
      final groups = [
        for (final id in ['gold', 'rot', 'technik', 'hellblau'])
          top(tester, 'wardrobe-group-$id'),
      ];
      expect(groups, orderedEquals([...groups]..sort()));
      // No group for rarities without figures.
      expect(find.byKey(const ValueKey('wardrobe-group-pink')), findsNothing);
      // In a rarity the owned figures come first: Johanna before Lucy.
      final johanna = tester.getTopLeft(
        find.byKey(const ValueKey('wardrobe-character.elena--anno')),
      );
      final lucy = tester.getTopLeft(
        find.byKey(const ValueKey('wardrobe-character.elena')),
      );
      expect(johanna.dx < lucy.dx || johanna.dy < lucy.dy, isTrue);
      // The role under the name of an owned card, "?" for the others.
      expect(find.text('als Johanna · Anno 1146 2025'), findsOneWidget);
      expect(find.text('Lina K.'), findsOneWidget);
      expect(find.text('Elena'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('filters by play and by person', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('wardrobe-filter-play')));
      await _settle(tester);
      await tester.tap(find.text('Anno 1146 2025').last);
      await _settle(tester);
      final shown = [
        for (final f in _figures)
          if (find.byKey(ValueKey('wardrobe-${f['id']}')).evaluate().isNotEmpty)
            f['id'],
      ];
      expect(shown, ['character.elena--anno', 'character.sebastian--anno']);
      // Together with a person: Elena in Anno 1146 only.
      await tester.tap(find.byKey(const ValueKey('wardrobe-filter-person')));
      await _settle(tester);
      await tester.tap(find.text('Elena').last);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('wardrobe-character.sebastian--anno')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--anno')),
        findsOneWidget,
      );
      // All plays again: all of Elena's roles.
      await tester.tap(find.byKey(const ValueKey('wardrobe-filter-play')));
      await _settle(tester);
      await tester.tap(find.text('Alle Stücke').last);
      await _settle(tester);
      for (final id in ['elena', 'elena--anno', 'elena--schicksal']) {
        expect(
          find.byKey(ValueKey('wardrobe-character.$id')),
          findsOneWidget,
          reason: id,
        );
      }
      expect(find.byKey(const ValueKey('wardrobe-c0')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a figure is worn as it is, without a role to choose', (
      tester,
    ) async {
      final bodies = await open(tester);
      await tester.tap(
        find.byKey(const ValueKey('wardrobe-character.elena--anno')),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('wardrobe-role')), findsOneWidget);
      expect(find.text('Rolle'), findsNothing);
      expect(find.byKey(const ValueKey('variant-plain')), findsNothing);
      await tester.tap(find.text('Anlegen'));
      await _settle(tester);
      expect(bodies, [
        {'kind': 'character', 'itemId': 'character.elena--anno', 'roles': true},
      ]);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a crate rolls through many figures and reveals the role won', (
    tester,
  ) async {
    // 84 figures, 12 per rarity: as large as the catalog with role figures.
    final many = [
      for (final r in _rarities)
        for (var i = 0; i < 12; i++)
          _figure(
            'character.p${r['id']}$i',
            'Person $i',
            '${r['id']}',
            role: 'Rolle $i',
            play: 'Stück',
            year: 2020 + i % 7,
            personId: 100 + i,
            importance: i * 8,
          ),
    ];
    final controller = await _signedIn(
      (request) => request.url.path.contains('/games/runner/skins/')
          ? Future.value(http.Response('', 404))
          : null,
    );
    final w = Wardrobe.fromJson(_json(figures: many, owned: const []));
    final won = w.catalog.item('character.pgold3')!;
    final reel = [
      for (var i = 0; i < 56; i++)
        w.catalog.item('${many[(i * 7) % many.length]['id']}')!,
    ]..[48] = won;
    await _pump(
      tester,
      CrateOpeningPage(
        controller: controller,
        wardrobe: w,
        sound: _Sound(),
        open: () async => CrateOpening(
          item: won,
          reel: reel,
          winnerIndex: 48,
          wardrobe: Wardrobe.fromJson(
            _json(figures: many, owned: const ['character.pgold3']),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(const Offset(400, 200));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('Person 3'), findsWidgets);
    expect(find.textContaining('als Rolle 3 · Stück 2023'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
