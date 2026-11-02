import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_overview.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// The wardrobe laid out as a full collection has it (seven rarities, four
// plays and the technicians, gage, trades, waiting crates): on a phone, with
// large text, light and dark, and wide. Nothing may overflow.

class LayoutSound implements RunnerSound {
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

const layoutFeatures = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerRoleFigures',
  'runnerUniqueFigures',
  'runnerGiftFigure',
  'runnerCollection',
  'runnerGageCrates',
  'runnerCrateTargets',
  'runnerEventCrates',
  'runnerMonthlyGala',
  'runnerMissions',
  'runnerDailyBonus',
];

// Common to rare, as the catalog lists them; trades cost five of the gage
// of the open rarity below.
const _rarities = [
  ('hellblau', 'Hellblau', '#5E98D9', 45, 10),
  ('legacy', 'Legacy', '#A47A4B', 6, 15),
  ('blau', 'Blau', '#4B69FF', 21, 20),
  ('technik', 'Technik', '#2FBF71', 11, 30),
  ('pink', 'Pink', '#D32CE6', 12, 40),
  ('rot', 'Rot', '#EB4B4B', 4, 80),
  ('gold', 'Gold', '#E4AE39', 1.5, 160),
];

const _names = [
  'Elena', 'Sebastian', 'Lina', 'Florian', 'Marie', 'Jonas', 'Theresa', //
  'Paul', 'Nela', 'Maren', 'Felix', 'Hanna', 'Lukas', 'Sophie', 'Ben',
  'Clara', 'Moritz', 'Ida', 'Emil', 'Greta', 'Anton', 'Frieda', 'Karl',
  'Luise', 'Oskar', 'Mila', 'Jakob', 'Rosa',
];

const _plays = [
  ('Creepshow', 2026, 26),
  ('Nexus', 2025, 22),
  ('Anno 1146', 2024, 20),
  ('Schicksalsfäden', 2023, 20),
];

/// A wardrobe of 68 of 110 with [gage]; [crates] of the own runs and one
/// Termin-Kiste waiting unless [waiting] is false.
JsonMap layoutWardrobe({int gage = 60, bool waiting = true}) {
  // Per rarity (figures): how many there are and how many are owned.
  final figures = {
    'gold': (6, 2),
    'rot': (11, 2),
    'pink': (13, 9),
    'blau': (14, 8),
    'legacy': (15, 4),
    'hellblau': (29, 28),
  };
  final pool = [
    for (final MapEntry(key: r, value: (n, _)) in figures.entries)
      for (var i = 0; i < n; i++) r,
  ];
  // Spread the rarities over the plays, deterministically.
  final spread = [for (var i = 0; i < pool.length; i++) pool[(i * 37) % 88]];
  final items = <JsonMap>[];
  final owned = <String>[];
  final have = <String, int>{};
  var next = 0;
  for (final (play, year, n) in _plays) {
    for (var i = 0; i < n; i++, next++) {
      final rarity = spread[next];
      final id = 'character.f$next';
      // The worn figure is a placeholder: no picture to load for the run.
      items.add({
        'id': id,
        'kind': 'character',
        'name': _names[next % _names.length],
        'rarity': rarity,
        'rarities': [rarity],
        'role': 'Rolle ${i + 1}',
        'play': play,
        'year': year,
        'personId': next % _names.length,
        'importance': 100 - i,
        if (next == 0)
          'placeholder': true
        else
          'image': '/games/runner/skins/$id.webp',
      });
      if ((have[rarity] ?? 0) < figures[rarity]!.$2) {
        owned.add(id);
        have[rarity] = (have[rarity] ?? 0) + 1;
      }
    }
  }
  for (var i = 0; i < 9; i++) {
    final id = 'character.t$i';
    items.add({
      'id': id,
      'kind': 'character',
      'name': _names[(i * 3) % _names.length],
      'rarity': 'technik',
      'rarities': ['technik'],
      'role': ['Licht', 'Ton', 'Bühne', 'Maske'][i % 4],
      'personId': (i * 3) % _names.length,
      'image': '/games/runner/skins/$id.webp',
    });
    owned.add(id);
  }
  JsonMap other(String id, String kind, String rarity) => {
    'id': id,
    'kind': kind,
    'name': id,
    'rarity': rarity,
    'rarities': [rarity],
    'image': '/games/runner/skins/$id.webp',
  };
  items.addAll([
    other('bd.wald', 'backdrop', 'hellblau'),
    other('bd.burg', 'backdrop', 'hellblau'),
    other('bd.stadt', 'backdrop', 'blau'),
    other('bd.schloss', 'backdrop', 'pink'),
    other('bd.nebel', 'backdrop', 'rot'),
    {...other('fx.funken', 'fx', 'hellblau'), 'effect': 'sparks'},
    {...other('fx.konfetti', 'fx', 'blau'), 'effect': 'confetti'},
    {...other('fx.nebel', 'fx', 'pink'), 'effect': 'fog'},
    {...other('fx.gold', 'fx', 'gold'), 'effect': 'gold'},
  ]);
  owned.addAll(['bd.wald', 'bd.burg', 'bd.stadt', 'fx.funken', 'fx.konfetti']);
  JsonMap target(String id, String kind, String name) => {
    'id': id,
    'kind': kind,
    'name': name,
    'animation': 'generic',
    'owned': 1,
    'total': 3,
    'shinyChance': 0.05,
  };
  return {
    'progress': {
      'meters': 2900,
      'earned': 14,
      'opened': 15,
      'crates': waiting ? 1 : 0,
      'previousAt': 2000,
      'nextAt': 4100,
      'poolSize': 106,
      'dupes': true,
      'bonusOpen': true,
    },
    'catalog': {
      'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
      'rarities': [
        for (final (id, name, color, weight, gage) in _rarities)
          {
            'id': id,
            'name': name,
            'color': color,
            'weight': weight,
            'gage': gage,
            if (id == 'gold') 'buyable': false,
          },
      ],
      'departments': [],
      'dupes': {
        'shinyChance': {'costume': .05, 'targeted': .03},
        'tradeDupes': 5,
        'buyDupes': 10,
        'crateGage': 50,
      },
      'items': [
        {
          'id': 'character.engel-logge',
          'kind': 'character',
          'name': 'Engel Logge',
          'rarity': 'hellblau',
          'rarities': ['hellblau'],
          'default': true,
        },
        for (final kind in ['backdrop', 'obstacles', 'fx'])
          {
            'id': '$kind.default',
            'kind': kind,
            'name': kind,
            'rarity': 'hellblau',
            'rarities': ['hellblau'],
            'default': true,
          },
        ...items,
      ],
      'rewards': [],
      'uniqueRarity': {'id': 'unique', 'name': 'Unique', 'color': '#B388FF'},
      'uniques': [],
    },
    'lockedRarities': [],
    'owned': ['backdrop.default', 'obstacles.default', 'fx.default', ...owned],
    'gift': 'character.f0',
    'hiddenDefaults': ['character.engel-logge'],
    'selected': {
      'character': 'character.f0',
      'backdrop': 'backdrop.default',
      'obstacles': 'obstacles.default',
      'fx': 'fx.default',
    },
    'collection': {'owned': 68, 'total': 110, 'shiny': 8, 'free': []},
    'stats': {'rounds': 41, 'best': 1840, 'meters': 2900, 'duplicates': 23},
    'shiny': owned.take(8).toList(),
    'variants': [],
    'selectedVariants': {},
    'gage': {'balance': gage, 'earned': 230},
    'trades': [
      {'from': 'hellblau', 'to': 'legacy', 'cost': 50},
      {'from': 'legacy', 'to': 'blau', 'cost': 75},
      {'from': 'technik', 'to': 'pink', 'cost': 150},
      {'from': 'pink', 'to': 'rot', 'cost': 200},
      {'from': 'rot', 'to': 'gold', 'cost': 400},
    ],
    'roleFigures': true,
    'uniqueFigures': {
      'plays': [
        {'play': 'Creepshow', 'year': 2026, 'have': 21, 'total': 28},
        {'play': 'Nexus', 'year': 2025, 'have': 22, 'total': 22},
        {'play': 'Anno 1146', 'year': 2024, 'have': 12, 'total': 20},
        {'play': 'Technik', 'have': 9, 'total': 9, 'allTechnicians': true},
      ],
      'unseen': [],
    },
    'crateTargets': [
      target('random', 'random', 'Zufallskiste'),
      target('tech', 'tech', 'Technik-Kiste'),
      target('play:creepshow', 'play', 'Creepshow-Kiste'),
    ],
    'eventCrates': [
      if (waiting)
        {
          'eventId': 'probe',
          'title': 'Probe Akt 2',
          'startsAt': '2026-10-31T18:00:00Z',
        },
    ],
    'gala': {
      'crates': 0,
      'trophies': [
        {'month': '2026-10', 'trophy': 'gold'},
      ],
    },
  };
}

/// The wardrobe of [json] on a [size] screen.
Future<void> pumpLayoutWardrobe(
  WidgetTester tester,
  JsonMap json, {
  Size size = const Size(360, 800),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = TestServer();
  server.data['capabilities'] = {'features': layoutFeatures};
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (path.contains('/games/runner/skins/')) {
      return Future.value(http.Response('', 404));
    }
    if (path.endsWith('/games/runner/wardrobe')) {
      return Future.value(jsonResponse(json));
    }
    return path.contains('/games/runner/')
        ? Future.value(jsonResponse({}))
        : null;
  };
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(brightness),
      home: WardrobeScreen(controller: controller, sound: LayoutSound()),
    ),
  );
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The tops of the rarity cells of the summary, row by row.
List<int> rarityRows(WidgetTester tester) {
  final tops = <double, int>{};
  for (final (id, _, _, _, _) in _rarities) {
    final cell = find.byKey(ValueKey('wardrobe-rarity-$id'));
    final top = tester.getTopLeft(cell).dy;
    tops[top] = (tops[top] ?? 0) + 1;
  }
  return (tops.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
      .map((e) => e.value)
      .toList();
}

Future<void> _tab(WidgetTester tester, String key) async {
  // With large text the tabs scroll.
  await tester.ensureVisible(find.byKey(ValueKey(key)));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(ValueKey(key)));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(WardrobePictures.clear);

  test('the rarities share their rows evenly', () {
    expect(balancedRows(7, 912, 64).rows, [7]);
    expect(balancedRows(7, 366, 64).rows, [4, 3]);
    expect(balancedRows(7, 280, 64).rows, [4, 3]);
    expect(balancedRows(7, 280, 64 * 1.3).rows, [3, 2, 2]);
    expect(balancedRows(7, 280, 128).rows, [2, 2, 2, 1]);
    // One cell width for all rows: the last row does not stretch.
    final four = balancedRows(7, 280, 64);
    expect(four.cell, (280 - 3 * 8) / 4);
    expect(balancedRows(5, 280, 88).rows, [3, 2]);
    expect(balancedRows(5, 592, 88).rows, [5]);
    expect(balancedRows(0, 280, 64).rows, isEmpty);
  });

  for (final (name, size, scale, brightness) in [
    ('phone', const Size(360, 800), 1.0, Brightness.light),
    ('phone, dark', const Size(360, 800), 1.0, Brightness.dark),
    ('phone, large text', const Size(360, 800), 2.0, Brightness.light),
    ('phone, large text, dark', const Size(360, 800), 2.0, Brightness.dark),
    ('large phone', const Size(430, 900), 1.0, Brightness.light),
    ('wide', const Size(1180, 900), 1.0, Brightness.light),
  ]) {
    testWidgets('$name: every tab without overflow', (tester) async {
      await pumpLayoutWardrobe(
        tester,
        layoutWardrobe(),
        size: size,
        textScale: scale,
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('wardrobe-summary')), findsOneWidget);
      if (scale == 1) {
        expect(rarityRows(tester), size.width > 1000 ? [7] : [4, 3]);
      }
      await tester.drag(
        find.byKey(const PageStorageKey('wardrobe-costumes')),
        const Offset(0, -600),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await _tab(tester, 'wardrobe-tab-crates');
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('wardrobe-ready-crates')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const PageStorageKey('wardrobe-gala-section')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('wardrobe-rewards')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.takeException(), isNull);
      await _tab(tester, 'wardrobe-tab-stats');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('crate-balance')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('wide, the plays share the width without scrolling', (
    tester,
  ) async {
    await pumpLayoutWardrobe(
      tester,
      layoutWardrobe(),
      size: const Size(1180, 900),
    );
    expect(
      find.byKey(const PageStorageKey('wardrobe-play-strip')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('wardrobe-play-Technik')).hitTestable(),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a phone the plays scroll; a filtered one comes into view', (
    tester,
  ) async {
    await pumpLayoutWardrobe(
      tester,
      layoutWardrobe(),
      size: const Size(360, 1400),
    );
    expect(
      find.byKey(const PageStorageKey('wardrobe-play-strip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('wardrobe-play-Technik')).hitTestable(),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('wardrobe-filter-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technik').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('wardrobe-play-Technik')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"Fehlende zeigen" goes to the missing figures', (tester) async {
    await pumpLayoutWardrobe(
      tester,
      layoutWardrobe(gage: 500),
      size: const Size(430, 1400),
    );
    await _tab(tester, 'wardrobe-tab-crates');
    final show = find.byKey(const ValueKey('wardrobe-show-missing'));
    await tester.ensureVisible(show);
    await tester.pump();
    await tester.tap(show);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final chip = tester.widget<FilterChip>(
      find.byKey(const ValueKey('wardrobe-missing-only')),
    );
    expect(chip.selected, isTrue);
    // Only missing figures in the grid.
    expect(find.byKey(const ValueKey('wardrobe-character.f0')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
