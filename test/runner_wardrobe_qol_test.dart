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
import 'package:theater_app/features/games/ui/admin_skin_viewer.dart';
import 'package:theater_app/features/games/ui/ensemble_card.dart';
import 'package:theater_app/features/games/ui/figure_detail.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/unique_figures.dart';
import 'package:theater_app/features/games/ui/wardrobe_overview.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

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
  'runnerEnsemble',
  'runnerCrateTargets',
  'runnerGageCrates',
  'runnerCollection',
];

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<AppController> _signedIn(
  Future<http.Response>? Function(http.Request) handle, {
  List<String> features = _features,
  bool admin = false,
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  if (admin) {
    final me = jsonMap(server.data['me']);
    server.data['me'] = {...me, 'role': 'admin'};
  }
  server.override = handle;
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(800, 2400),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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

JsonMap _qolWardrobe({
  List<String> owned = const [
    'character.elena--creep',
    'character.seb--nexus',
    'character.tech--licht',
    'fx.funken',
  ],
  List<String> shiny = const ['character.elena--creep'],
  JsonMap selected = const {
    'character': 'character.elena--creep',
    'fx': 'fx.default',
  },
  int gage = 250,
  int crates = 2,
  bool unlockKuschel = false,
  bool includeAdvent = false,
}) => {
  'progress': {
    'meters': 3000,
    'earned': 3,
    'opened': 1,
    'crates': crates,
    'previousAt': 2000,
    'nextAt': 4000,
    'poolSize': 8,
    'complete': false,
    'dupes': true,
  },
  'gage': {'balance': gage, 'earned': 600},
  'shiny': shiny,
  'trades': [
    {'from': 'hellblau', 'to': 'blau', 'cost': 50},
    {'from': 'blau', 'to': 'gold', 'cost': 100},
  ],
  'lockedRarities': ['legacy'],
  'crateTargets': [
    {
      'id': 'random',
      'kind': 'random',
      'name': 'Zufallskiste',
      'owned': 4,
      'total': 8,
      'shinyChance': 0.05,
    },
    {
      'id': 'play:creepshow-2026',
      'kind': 'play',
      'name': 'Creepshow',
      'play': 'Creepshow',
      'year': 2026,
      'owned': 1,
      'total': 3,
      'shinyChance': 0.03,
    },
    {
      'id': 'play:nexus-2024',
      'kind': 'play',
      'name': 'Nexus',
      'play': 'Nexus',
      'year': 2024,
      'owned': 1,
      'total': 2,
      'shinyChance': 0.03,
    },
    {
      'id': 'tech',
      'kind': 'tech',
      'name': 'Technik-Kiste',
      'owned': 1,
      'total': 2,
      'shinyChance': 0.03,
    },
  ],
  'uniqueFigures': {
    'plays': [
      {
        'play': 'Creepshow und Nexus',
        'plays': [
          {'play': 'Creepshow', 'year': 2026, 'have': 1, 'total': 3},
          {'play': 'Nexus', 'year': 2024, 'have': 1, 'total': 2},
        ],
        'have': unlockKuschel ? 5 : 2,
        'total': 5,
        'unlocked': unlockKuschel,
        if (unlockKuschel) ...{
          'itemId': 'character.unique-kuschel',
          'name': 'Captain Kuschel',
        } else ...{
          'hidden': true,
          'name': '???',
        },
      },
      {
        'play': 'Technik',
        'allTechnicians': true,
        'have': 1,
        'total': 2,
        'unlocked': false,
        'hidden': true,
        'name': '???',
      },
      if (includeAdvent)
        {
          'play': 'Adventskalender',
          'year': 2026,
          'allAdventCalendar': true,
          'itemNoun': {
            'one': 'Adventskalender-Skin',
            'many': 'Adventskalender-Skins',
          },
          'have': 10,
          'total': 23,
          'unlocked': false,
          'hidden': true,
          'name': '???',
        },
    ],
    'unseen': <String>[],
  },
  'catalog': {
    'kinds': ['character', 'fx'],
    'dupes': {
      'shinyChance': {
        'costume': 0.05,
        'targeted': 0.03,
        'gala': 0.15,
        'ensemble': 0.03,
      },
      'tradeDupes': 5,
      'buyDupes': 10,
      'crateGage': 50,
    },
    'uniqueRarity': {
      'id': 'unique',
      'name': 'Unique',
      'color': '#B388FF',
      'style': 'holo',
    },
    'rarities': [
      {
        'id': 'hellblau',
        'name': 'Hellblau',
        'color': '#5E98D9',
        'weight': 50,
        'gage': 10,
      },
      {
        'id': 'legacy',
        'name': 'Legacy',
        'color': '#A47A4B',
        'weight': 10,
        'gage': 15,
        'style': 'antique',
        'requires': {'rarity': 'hellblau', 'kind': 'character'},
        'hint': 'Sammle alle hellblauen Figuren',
      },
      {
        'id': 'blau',
        'name': 'Blau',
        'color': '#4B69FF',
        'weight': 30,
        'gage': 20,
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
    'departments': [
      {'id': 'light', 'name': 'Licht', 'icon': 'light'},
    ],
    'items': [
      {
        'id': 'character.default',
        'kind': 'character',
        'name': 'Engel Logge',
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'default': true,
      },
      {
        'id': 'fx.default',
        'kind': 'fx',
        'name': 'Ohne Effekt',
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'default': true,
      },
      {
        'id': 'character.elena--creep',
        'kind': 'character',
        'name': 'Elena',
        'role': 'Lucy',
        'play': 'Creepshow',
        'year': 2026,
        'personId': 1,
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'placeholder': true,
        'importance': 90,
      },
      {
        'id': 'character.elena--creep2',
        'kind': 'character',
        'name': 'Elena',
        'role': 'Geist',
        'play': 'Creepshow',
        'year': 2026,
        'personId': 1,
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'placeholder': true,
        'importance': 50,
      },
      {
        'id': 'character.gold--creep',
        'kind': 'character',
        'name': 'Geheime Goldfigur',
        'role': 'Dämon',
        'play': 'Creepshow',
        'year': 2026,
        'personId': 4,
        'rarity': 'gold',
        'rarities': ['gold'],
        'placeholder': true,
        'importance': 99,
      },
      {
        'id': 'character.seb--nexus',
        'kind': 'character',
        'name': 'Sebastian',
        'role': 'Pilot',
        'play': 'Nexus',
        'year': 2024,
        'personId': 2,
        'rarity': 'blau',
        'rarities': ['blau'],
        'placeholder': true,
        'importance': 80,
      },
      {
        'id': 'character.mara--nexus',
        'kind': 'character',
        'name': 'Mara',
        'role': 'Kapitänin',
        'play': 'Nexus',
        'year': 2024,
        'personId': 5,
        'rarity': 'blau',
        'rarities': ['blau'],
        'placeholder': true,
        'importance': 70,
      },
      {
        'id': 'character.legacy--alt',
        'kind': 'character',
        'name': 'Anton',
        'role': 'Bote',
        'play': 'Creepshow',
        'year': 2026,
        'personId': 6,
        'rarity': 'legacy',
        'rarities': ['legacy'],
        'placeholder': true,
        'importance': 40,
      },
      {
        'id': 'character.tech--licht',
        'kind': 'character',
        'name': 'Florian',
        'role': 'Lichttechnik',
        'personId': 3,
        'rarity': 'blau',
        'rarities': ['blau'],
        'departments': ['light'],
        'placeholder': true,
        'importance': 60,
      },
      {
        'id': 'character.tech--ton',
        'kind': 'character',
        'name': 'Lina',
        'role': 'Tontechnik',
        'personId': 7,
        'rarity': 'blau',
        'rarities': ['blau'],
        'placeholder': true,
        'importance': 55,
      },
      {
        'id': 'fx.funken',
        'kind': 'fx',
        'name': 'Funkenregen',
        'rarity': 'blau',
        'rarities': ['blau'],
        'effect': {
          'trail': 'sparkle',
          'colors': ['#FFD54F'],
        },
      },
      {
        'id': 'fx.nebel',
        'kind': 'fx',
        'name': 'Bühnennebel',
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'effect': {
          'trail': 'sparkle',
          'colors': ['#CFD8DC'],
        },
      },
    ],
    if (unlockKuschel)
      'uniques': [
        {
          'id': 'character.unique-kuschel',
          'kind': 'character',
          'name': 'Captain Kuschel',
          'role': 'Captain Kuschel',
          'play': 'Creepshow',
          'year': 2026,
          'rarity': 'unique',
          'rarities': ['unique'],
          'unique': true,
          'placeholder': true,
        },
      ],
  },
  'owned': [...owned, if (unlockKuschel) 'character.unique-kuschel'],
  'selected': selected,
  'stats': {'rounds': 5, 'best': 1000, 'meters': 3000, 'duplicates': 4},
};

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(WardrobePictures.clear);

  testWidgets(
    'openWardrobe(initialTab: 1) opens directly on Kisten and loads at once',
    (tester) async {
      var fetched = 0;
      final json = _qolWardrobe();
      final initial = Wardrobe.fromJson(json);
      final controller = await _signedIn((request) {
        if (_path(request).endsWith('/games/runner/wardrobe')) {
          fetched++;
          return Future.value(jsonResponse(json));
        }
        return _path(request).contains('/games/runner/')
            ? Future.value(jsonResponse({}))
            : null;
      });
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => openWardrobe(
              context,
              controller,
              wardrobe: initial,
              sound: _Sound(),
              initialTab: 1,
            ),
            child: const Text('Öffnen'),
          ),
        ),
      );
      await tester.tap(find.text('Öffnen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Immediately started loading without waiting for route entrance.
      expect(fetched, 1);
      await _settle(tester);
      // Tab 1 (Kisten) is visible right away.
      expect(
        find.byKey(const ValueKey('wardrobe-ready-crates')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'search, ownership, rarity, shine, cross-filtering, sorting and reset',
    (tester) async {
      final controller = await _signedIn(
        (request) => _path(request).contains('/games/runner/')
            ? Future.value(jsonResponse(_qolWardrobe()))
            : null,
      );
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);

      // Search finds owned Elena without leaking unowned secret name "Geheime Goldfigur".
      await tester.enterText(
        find.byKey(const ValueKey('wardrobe-search')),
        'Geheime',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wardrobe-character.gold--creep')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('wardrobe-search')),
        'elena',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--creep')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.seb--nexus')),
        findsNothing,
      );
      // Clear search via button.
      await tester.tap(find.byKey(const ValueKey('wardrobe-search-clear')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wardrobe-character.seb--nexus')),
        findsOneWidget,
      );

      // Rarity tap in CollectionSummaryCard toggles Gold filter.
      await tester.tap(find.byKey(const ValueKey('wardrobe-rarity-gold')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wardrobe-character.gold--creep')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--creep')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-rarity-active')),
        findsOneWidget,
      );
      // Reset clears rarity filter.
      await tester.tap(find.byKey(const ValueKey('wardrobe-reset-filters')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--creep')),
        findsOneWidget,
      );

      // Ownership: Kaufbar (gage 250 buys Hellblau 100 and Blau 200, not Gold or locked Legacy).
      await tester.tap(find.byKey(const ValueKey('wardrobe-buyable-only')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--creep2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.mara--nexus')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.gold--creep')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.legacy--alt')),
        findsNothing,
      );
      // Price badge shown on missing buyable cards.
      expect(
        find.byKey(const ValueKey('card-price-character.elena--creep2')),
        findsOneWidget,
      );

      // Shine filter: Glanz shows only shiny Elena.
      await tester.tap(find.byKey(const ValueKey('wardrobe-reset-filters')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wardrobe-shiny-only')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--creep')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.seb--nexus')),
        findsNothing,
      );

      // Shine filter: Ohne Glanz shows owned non-shiny figures.
      await tester.tap(find.byKey(const ValueKey('wardrobe-plain-only')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--creep')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.seb--nexus')),
        findsOneWidget,
      );

      // Cross-filtering: pick Creepshow 2026 -> Sebastian (Nexus) is not in person dropdown.
      await tester.tap(find.byKey(const ValueKey('wardrobe-reset-filters')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wardrobe-filter-play')));
      await _settle(tester);
      await tester.tap(find.text('Creepshow 2026').last);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('wardrobe-filter-person')));
      await _settle(tester);
      expect(find.text('Elena'), findsWidgets);
      expect(find.text('Sebastian'), findsNothing);
      await tester.tap(find.text('Alle Personen').last);
      await _settle(tester);

      // Sorting: Besessen zuerst, Stück & Jahr, Name A–Z.
      await tester.tap(find.byKey(const ValueKey('wardrobe-reset-filters')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wardrobe-sort')));
      await _settle(tester);
      await tester.tap(find.text('Besessen zuerst').last);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('wardrobe-group-owned')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-group-missing')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('wardrobe-sort')));
      await _settle(tester);
      await tester.tap(find.text('Stück & Jahr').last);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('wardrobe-group-play-Creepshow 2026')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-group-play-Technik')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('wardrobe-sort')));
      await _settle(tester);
      await tester.tap(find.text('Name A–Z').last);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('wardrobe-group-alpha')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'uniques: Technik filter, multi-play filter (locked & unlocked), shortcut & Advent text',
    (tester) async {
      final controller = await _signedIn(
        (request) => _path(request).contains('/games/runner/')
            ? Future.value(
                jsonResponse(_qolWardrobe(includeAdvent: true)),
              )
            : null,
      );
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);

      // Overview attaches multi-play unique to both Creepshow 2026 and Nexus 2024.
      final overview = WardrobeOverview.of(Wardrobe.fromJson(_qolWardrobe()));
      final creep = overview.plays.firstWhere(
        (p) => p.title == 'Creepshow 2026',
      );
      final nexus = overview.plays.firstWhere((p) => p.title == 'Nexus 2024');
      expect(creep.unique?.play, 'Creepshow und Nexus');
      expect(nexus.unique?.play, 'Creepshow und Nexus');

      // Filtering by Technik shows the Technician Unique!
      await tester.tap(find.byKey(const ValueKey('wardrobe-filter-play')));
      await _settle(tester);
      await tester.tap(find.text('Technik').last);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('wardrobe-unique-hidden:Technik')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('wardrobe-unique-hidden:Creepshow und Nexus'),
        ),
        findsNothing,
      );

      // Filtering by Nexus 2024 shows multi-play Unique Captain Kuschel (hidden)!
      await tester.tap(find.byKey(const ValueKey('wardrobe-filter-play')));
      await _settle(tester);
      await tester.tap(find.text('Nexus 2024').last);
      await _settle(tester);
      final multiCard = find.byKey(
        const ValueKey('wardrobe-unique-hidden:Creepshow und Nexus'),
      );
      expect(multiCard, findsOneWidget);

      // Tapping multi-play Unique opens details with per-play missing buttons.
      await tester.tap(multiCard);
      await _settle(tester);
      final jumpBtn = find.byKey(
        const ValueKey('wardrobe-unique-show-missing'),
      );
      expect(jumpBtn, findsOneWidget);
      await tester.tap(jumpBtn);
      await _settle(tester);
      // Filtered directly to missing figures of Creepshow 2026.
      final missingChip = tester.widget<FilterChip>(
        find.byKey(const ValueKey('wardrobe-missing-only')),
      );
      expect(missingChip.selected, isTrue);
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--creep2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('wardrobe-character.elena--creep')),
        findsNothing,
      );

      // Reset and check Advent calendar unique wording (never "Rollen aus Adventskalender").
      await tester.tap(find.byKey(const ValueKey('wardrobe-reset-filters')));
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey('wardrobe-unique-hidden:Adventskalender 2026'),
        ),
      );
      await _settle(tester);
      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(
          of: sheet,
          matching: find.textContaining('Wer alle Adventskalender-Skins hat'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.textContaining('Rollen')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unlocked multi-play unique appears under both plays, Advent texts in celebration & detail',
    (tester) async {
      final json = _qolWardrobe(unlockKuschel: true);
      final controller = await _signedIn(
        (request) => _path(request).contains('/games/runner/')
            ? Future.value(jsonResponse(json))
            : null,
      );
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);

      for (final play in ['Creepshow 2026', 'Nexus 2024']) {
        await tester.tap(find.byKey(const ValueKey('wardrobe-filter-play')));
        await _settle(tester);
        await tester.tap(find.text(play).last);
        await _settle(tester);
        expect(
          find.byKey(const ValueKey('wardrobe-character.unique-kuschel')),
          findsOneWidget,
          reason: 'unlocked Captain Kuschel should appear under $play',
        );
      }

      // Check Advent calendar celebration and FigureDetailPage texts directly.
      final adventWardrobe = Wardrobe.fromJson({
        ..._qolWardrobe(),
        'owned': ['character.unique-advent'],
        'uniqueFigures': {
          'plays': [
            {
              'play': 'Adventskalender',
              'year': 2026,
              'allAdventCalendar': true,
              'itemNoun': {
                'one': 'Adventskalender-Skin',
                'many': 'Adventskalender-Skins',
              },
              'have': 23,
              'total': 23,
              'unlocked': true,
              'itemId': 'character.unique-advent',
              'name': 'Nikolaus',
            },
          ],
          'unseen': ['character.unique-advent'],
        },
        'catalog': {
          ...jsonMap(_qolWardrobe()['catalog']),
          'uniques': [
            {
              'id': 'character.unique-advent',
              'kind': 'character',
              'name': 'Nikolaus',
              'role': 'Nikolaus',
              'play': 'Adventskalender',
              'year': 2026,
              'rarity': 'unique',
              'rarities': ['unique'],
              'unique': true,
              'placeholder': true,
            },
          ],
        },
      });
      final adventItem = adventWardrobe.catalog.item(
        'character.unique-advent',
      )!;
      await _pump(
        tester,
        UniqueCelebration(
          items: [adventItem],
          wardrobe: adventWardrobe,
          controller: controller,
        ),
      );
      expect(
        find.text('Alle 23 Adventskalender-Skins gesammelt'),
        findsOneWidget,
      );

      await _pump(
        tester,
        FigureDetailPage(
          wardrobe: adventWardrobe,
          item: adventItem,
          controller: controller,
          busy: false,
          dupes: true,
          onWear: (_) async {},
        ),
      );
      expect(
        find.text('Freigeschaltet: alle Adventskalender-Skins gesammelt.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'outfit bar, 1-tap quick-equip, random outfit, SnackBar and session Neu badge',
    (tester) async {
      final worn = <String, String>{
        'character': 'character.elena--creep',
        'fx': 'fx.default',
      };
      final owned = [
        'character.elena--creep',
        'character.seb--nexus',
        'character.tech--licht',
        'fx.funken',
      ];
      final outfitCalls = <String>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/games/runner/outfit')) {
          final body = jsonMap(jsonDecode(request.body));
          worn['${body['kind']}'] = '${body['itemId']}';
          outfitCalls.add('${body['itemId']}');
          return Future.value(
            jsonResponse(_qolWardrobe(owned: owned, selected: {...worn})),
          );
        }
        if (path.endsWith('/games/runner/buy')) {
          final body = jsonMap(jsonDecode(request.body));
          final id = '${body['itemId']}';
          if (!owned.contains(id)) owned.add(id);
          final next = _qolWardrobe(
            owned: owned,
            selected: {...worn},
            gage: 150,
          );
          final item = jsonList(
            jsonMap(next['catalog'])['items'],
          ).firstWhere((e) => jsonMap(e)['id'] == id);
          return Future.value(
            jsonResponse({
              'item': item,
              'outcome': {'type': 'buy', 'rarity': 'hellblau', 'cost': 100},
              'wardrobe': next,
            }),
          );
        }
        return path.contains('/games/runner/')
            ? Future.value(
                jsonResponse(_qolWardrobe(owned: owned, selected: {...worn})),
              )
            : null;
      });
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);

      // Outfit bar shows active slots.
      expect(find.byKey(const ValueKey('wardrobe-outfit-bar')), findsOneWidget);
      expect(find.text('Figur: Elena'), findsOneWidget);
      expect(find.text('Effekt: Ohne Effekt'), findsOneWidget);

      // 1-tap quick-equip icon equips Sebastian without pushing FigureDetailPage.
      await tester.tap(
        find.byKey(const ValueKey('card-equip-character.seb--nexus')),
      );
      await _settle(tester);
      expect(outfitCalls, ['character.seb--nexus']);
      expect(find.byType(FigureDetailPage), findsNothing);
      expect(find.text('Figur: Sebastian'), findsOneWidget);
      expect(find.text('Angelegt: Sebastian als Pilot'), findsOneWidget);

      // Long-pressing an owned card also quick-equips directly.
      await tester.longPress(
        find.byKey(const ValueKey('wardrobe-character.tech--licht')),
      );
      await _settle(tester);
      expect(outfitCalls.last, 'character.tech--licht');
      expect(find.text('Figur: Florian'), findsOneWidget);

      // Random outfit equips different owned items across slots with >=2 owned.
      outfitCalls.clear();
      await tester.tap(find.byKey(const ValueKey('wardrobe-random-outfit')));
      await _settle(tester);
      expect(outfitCalls, contains('fx.funken'));
      expect(outfitCalls.length, 2);
      expect(find.text('Zufalls-Outfit angelegt'), findsOneWidget);

      // Buying a missing item marks it "Neu" until opened.
      await tester.tap(
        find.byKey(const ValueKey('wardrobe-character.elena--creep2')),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('wardrobe-buy')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('deal-confirm')));
      await _settle(tester);
      await tester.tap(find.text('Fertig'));
      await _settle(tester);

      expect(
        find.byKey(const ValueKey('card-new-character.elena--creep2')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('wardrobe-new-only')), findsOneWidget);

      // Opening details clears "Neu".
      await tester.tap(
        find.byKey(const ValueKey('wardrobe-character.elena--creep2')),
      );
      await _settle(tester);
      await tester.pageBack();
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('card-new-character.elena--creep2')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('wardrobe-new-only')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'provenance sources, Gold trade cost, Zu den Kisten jump, odds & FigureDetail missing tap',
    (tester) async {
      final controller = await _signedIn(
        (request) => _path(request).contains('/games/runner/')
            ? Future.value(jsonResponse(_qolWardrobe()))
            : null,
      );
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
      );
      await _settle(tester);

      // Locked rarity hint in CollectionSummaryCard shows 1/2 progress.
      expect(
        find.byKey(const ValueKey('wardrobe-locked-hint-legacy')),
        findsOneWidget,
      );
      expect(find.textContaining('1/2'), findsWidgets);

      // Tapping Elena (owned) -> FigureDetailPage -> tapping missing role opens its detail sheet.
      await tester.tap(
        find.byKey(const ValueKey('wardrobe-character.elena--creep')),
      );
      await _settle(tester);
      expect(find.byType(FigureDetailPage), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('figure-role-character.elena--creep2')),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('wardrobe-source')), findsOneWidget);
      expect(find.textContaining('Kiste „Creepshow 2026“'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);

      // Missing Gold figure shows Creepshow crate + Tauschvertrag price + Zu den Kisten button.
      await tester.tap(
        find.byKey(const ValueKey('wardrobe-character.gold--creep')),
      );
      await _settle(tester);
      expect(
        find.text(
          'Fundorte: Zufallskiste · Kiste „Creepshow 2026“ · Tauschvertrag (100 Gage)',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('wardrobe-to-crates')));
      await _settle(tester);
      // Switched to Tab 1 (Kisten).
      expect(
        find.byKey(const ValueKey('wardrobe-ready-crates')),
        findsOneWidget,
      );
      // Gold trade shows "noch 1 offen (garantiert!)".
      expect(
        find.text('Tauschvertrag · noch 1 offen (garantiert!)'),
        findsOneWidget,
      );

      // Open Chancen & Details -> shows duplicate Gage, locked progress & per-crate shine.
      await tester.tap(
        find.byKey(const PageStorageKey('wardrobe-crate-details')),
      );
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('wardrobe-odds-locked-legacy')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('wardrobe-odds-gage')), findsOneWidget);
      expect(find.textContaining('Gold 200'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('wardrobe-odds-shine')),
        findsOneWidget,
      );
      expect(find.textContaining('Gala 15 %'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'EnsembleCard shows eligibility note, reachedAt date and tappable reached reward',
    (tester) async {
      final controller = await _signedIn(
        (request) => _path(request).contains('/games/runner/')
            ? Future.value(jsonResponse({}))
            : null,
      );
      final w = Wardrobe.fromJson({
        ..._qolWardrobe(),
        'owned': ['bd.anno'],
        'catalog': {
          ...jsonMap(_qolWardrobe()['catalog']),
          'rewards': [
            {
              'id': 'bd.anno',
              'kind': 'backdrop',
              'name': 'Anno 1146',
              'rarity': 'ensemble',
              'rarities': ['ensemble'],
              'reward': true,
              'placeholder': true,
            },
          ],
          'ensembleRarity': {
            'id': 'ensemble',
            'name': 'Ensemble',
            'color': '#E89B3C',
          },
        },
        'ensemble': {
          'meters': 30000,
          'previousKm': 25,
          'crates': 0,
          'unseen': <num>[],
          'section': {'own': 0, 'players': 5},
          'next': {'km': 50, 'name': '???', 'hidden': true},
          'milestones': [
            {
              'km': 25,
              'name': 'Anno 1146',
              'reached': true,
              'reachedAt': '2026-10-15T12:00:00Z',
              'reward': {
                'itemId': 'bd.anno',
                'kind': 'backdrop',
                'ready': true,
              },
            },
            {'km': 50, 'name': '???', 'hidden': true, 'reached': false},
          ],
        },
      });
      WardrobeItem? tapped;
      await _pump(
        tester,
        Scaffold(
          body: EnsembleCard(
            wardrobe: w,
            controller: controller,
            onReward: (item) => tapped = item,
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('ensemble-eligibility-note')),
        findsOneWidget,
      );
      await tester.tap(find.text('Alle Ziele'));
      await _settle(tester);
      expect(find.textContaining('erreicht am 15.10.2026'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ensemble-goal-25')));
      await tester.pump();
      expect(tapped?.id, 'bd.anno');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'AdminSchedulePage shows readiness summary, status badges and ohne Bild without overflow',
    (tester) async {
      final catalog = {
        'rarities': [
          {'id': 'hellblau', 'name': 'Hellblau', 'color': '#5E98D9'},
          {'id': 'gold', 'name': 'Gold', 'color': '#E4AE39'},
        ],
        'departments': <JsonMap>[],
        'releases': <JsonMap>[],
        'items': [
          {
            'id': 'character.a1',
            'kind': 'character',
            'name': 'Elena',
            'role': 'Hauptrolle',
            'rarity': 'gold',
            'rarities': ['gold'],
            'image': '/admin/runner/skins/a1.webp',
            'portrait': '/admin/runner/skins/a1-p.webp',
            'admin': {'live': true},
          },
          {
            'id': 'character.a2',
            'kind': 'character',
            'name': 'Florian',
            'role': 'Nebenrolle',
            'rarity': 'hellblau',
            'rarities': ['hellblau'],
            'admin': {'live': true},
          },
          {
            'id': 'character.a3',
            'kind': 'character',
            'name': 'Lina',
            'role': 'Statistin',
            'rarity': 'hellblau',
            'rarities': ['hellblau'],
            'image': '/admin/runner/skins/a3.webp',
            'portrait': '/admin/runner/skins/a3-p.webp',
            'admin': {'disabled': true, 'live': false},
          },
        ],
        'schedule': {
          'title': 'Sonderplan',
          'heading': 'Monat X',
          'unit': 'Feld',
          'units': 'Felder',
          'entries': [
            {'item': 'character.a1', 'title': 'Eintrag 1'},
            {'item': 'character.a2', 'title': 'Eintrag 2'},
            {'item': 'character.a3', 'title': 'Eintrag 3'},
          ],
        },
      };
      final controller = await _signedIn(
        (request) {
          final path = _path(request);
          if (path.endsWith('/admin/runner/catalog')) {
            return Future.value(jsonResponse(catalog));
          }
          if (path.contains('/admin/runner/skins/')) {
            return Future.value(http.Response('', 404));
          }
          return null;
        },
        features: [..._features, 'runnerAdminCatalog'],
        admin: true,
      );
      await _pump(
        tester,
        AdminSkinViewerScreen(controller: controller),
        size: const Size(360, 800),
        textScale: 2.0,
      );
      await _settle(tester);
      await tester.ensureVisible(find.text('Sonderplan'));
      await tester.tap(find.text('Sonderplan'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('schedule-summary')), findsOneWidget);
      expect(
        find.text('1/3 bereit · 1 ohne Bild · 1 deaktiviert'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('schedule-entry-2')),
        300,
        scrollable: find.byType(Scrollable),
      );
      expect(find.text('ohne Bild'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'phone 360x800 at 2.0x textScale with filters and missing sheet has zero overflow',
    (tester) async {
      final controller = await _signedIn(
        (request) => _path(request).contains('/games/runner/')
            ? Future.value(jsonResponse(_qolWardrobe()))
            : null,
      );
      await _pump(
        tester,
        WardrobeScreen(controller: controller, sound: _Sound()),
        size: const Size(360, 800),
        textScale: 2.0,
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final scrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey('wardrobe-costumes')),
            matching: find.byType(Scrollable),
          )
          .first;
      final goldCard = find.byKey(
        const ValueKey('wardrobe-character.gold--creep'),
      );
      await tester.scrollUntilVisible(goldCard, 200, scrollable: scrollable);
      await tester.ensureVisible(goldCard);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(goldCard);
      await _settle(tester);
      expect(find.byKey(const ValueKey('wardrobe-source')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
