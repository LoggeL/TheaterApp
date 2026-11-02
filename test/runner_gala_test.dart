import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/leaderboard_api.dart';
import 'package:theater_app/features/games/data/runner_menu_preferences.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/crate_choice.dart';
import 'package:theater_app/features/games/ui/gala.dart';
import 'package:theater_app/features/games/ui/runner_menu.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// Monatsgala: prizes from the monthly list, its celebration and crates.

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
  'runnerMonthlyGala',
];

JsonMap _item(String id, String kind, String name, {bool isDefault = false}) =>
    {
      'id': id,
      'kind': kind,
      'name': name,
      'rarity': 'hell',
      'rarities': ['hell'],
      if (isDefault) 'default': true,
    };

const _crate = {
  'id': 'gala',
  'kind': 'gala',
  'name': 'Gala-Kiste',
  'animation': 'burst',
  'shinyChance': 0.15,
};

JsonMap _galaJson({
  int crates = 3,
  String? unseen = '2026-10',
  List<JsonMap> trophies = const [
    {'month': '2026-10', 'trophy': 'gold'},
  ],
}) => {
  'crates': crates,
  'unseen': unseen,
  'trophies': trophies,
  'crate': _crate,
  'masks': const <String, Object?>{},
};

JsonMap _wardrobeJson({JsonMap? gala}) => {
  'progress': {
    'meters': 100,
    'earned': 0,
    'opened': 0,
    'crates': 0,
    'previousAt': 0,
    'nextAt': 2000,
    'poolSize': 2,
    'dupes': true,
    'galaCrates': gala?['crates'] ?? 0,
  },
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hell', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
    ],
    'items': [
      _item('c0', 'character', 'Engel Logge', isDefault: true),
      _item('b0', 'backdrop', 'Bühnenwand', isDefault: true),
      _item('o0', 'obstacles', 'Requisitenlager', isDefault: true),
      _item('f0', 'fx', 'Ohne Effekt', isDefault: true),
      _item('maren', 'character', 'Maren'),
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0'],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'gala': ?gala,
};

const _viewJson = {
  'month': '2026-10',
  'monthName': 'Oktober',
  'opensAt': '2026-11-01T09:00:00.000Z',
  'players': 5,
  'podium': [
    {'rank': 1, 'name': 'Anna', 'score': 1400, 'trophy': 'gold', 'me': true},
    {'rank': 1, 'name': 'Ben', 'score': 1400, 'trophy': 'gold', 'me': false},
    {'rank': 3, 'name': 'Cleo', 'score': 900, 'trophy': 'bronze', 'me': false},
  ],
  'own': {
    'rank': 1,
    'score': 1400,
    'prize': 'gold',
    'crates': 3,
    'gage': 0,
    'trophy': 'gold',
  },
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

/// A page starting the celebration from its button, as the game does on open.
Widget _host(
  AppController controller,
  Wardrobe wardrobe,
  RunnerSound sound,
  ValueChanged<Wardrobe> changed, {
  ValueChanged<Object>? failed,
}) => MaterialApp(
  theme: StageTheme.build(Brightness.light),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => celebrateGala(
          context,
          controller: controller,
          wardrobe: wardrobe,
          sound: sound,
          onChanged: changed,
        ).catchError((Object e) => failed?.call(e)),
        child: const Text('Spiel öffnen'),
      ),
    ),
  ),
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('data', () {
    test('the wardrobe tells of the own gala and counts its crates', () {
      final w = Wardrobe.fromJson(
        _wardrobeJson(
          gala: {
            ..._galaJson(
              trophies: const [
                {'month': '2026-11', 'trophy': 'bronze'},
                {'month': '2026-10', 'trophy': 'gold'},
                {'month': '2026-09', 'trophy': 'platinum'},
              ],
            ),
            'masks': {'gold': '/games/runner/skins/trophy-mask-gold.webp'},
          },
        ),
      );
      expect(w.gala.crates, 3);
      expect(w.gala.unseen, '2026-10');
      expect(w.gala.crate?.kind, CrateTargetKind.gala);
      expect(w.gala.crate?.shinyChance, 0.15);
      expect(w.gala.masks.keys, [GalaTrophy.gold]);
      // A trophy of a later server stays out; the rest keeps its order.
      expect(w.gala.trophies.map((t) => t.trophy), [
        GalaTrophy.bronze,
        GalaTrophy.gold,
      ]);
      expect(w.progress.galaCrates, 3);
      expect(w.progress.waiting, 3);
      expect(crateWaiting(w), isTrue);
      expect(crateTargetSubtitle(w.gala.crate!), 'Alles aus dem Fundus');
    });

    test('older servers send nothing of it', () {
      final w = Wardrobe.fromJson(_wardrobeJson());
      expect(w.gala.crates, 0);
      expect(w.gala.unseen, isNull);
      expect(w.gala.trophies, isEmpty);
      expect(w.gala.crate, isNull);
      expect(w.progress.waiting, 0);
      expect(crateWaiting(w), isFalse);
    });

    test(
      'the gala view has the podium with shared ranks and the own prize',
      () {
        final gala = MonthlyGala.fromJson(jsonMap(_viewJson));
        expect(gala.month, '2026-10');
        expect(gala.monthName, 'Oktober');
        expect(gala.players, 5);
        expect(gala.podium.map((e) => e.name), ['Anna', 'Ben', 'Cleo']);
        expect(gala.podium.map((e) => e.rank), [1, 1, 3]);
        expect(gala.podium.first.me, isTrue);
        expect(gala.podium.last.trophy, GalaTrophy.bronze);
        expect(gala.own?.crates, 3);
        expect(gala.own?.trophy, GalaTrophy.gold);
        expect(gala.own?.previous, isNull);
        expect(
          MonthlyGala.fromJson({...jsonMap(_viewJson), 'own': null}).own,
          isNull,
        );
      },
    );

    test('the ranking reads the mask, none for the others', () {
      final entries = [
        for (final json in [
          {'rank': 1, 'personId': 1, 'name': 'A', 'score': 9, 'trophy': 'gold'},
          {'rank': 2, 'personId': 2, 'name': 'B', 'score': 8},
          {'rank': 3, 'personId': 3, 'name': 'C', 'score': 7, 'trophy': '?'},
        ])
          LeaderboardEntry.fromJson(json),
      ];
      expect(entries.map((e) => e.trophy), [GalaTrophy.gold, null, null]);
    });

    test('the own prize reads as what was won', () {
      expect(
        galaPrizeText(
          const GalaOwnPrize(
            rank: 2,
            score: 1200,
            prize: 'silver',
            crates: 2,
            trophy: GalaTrophy.silver,
          ),
        ),
        'Platz 2 mit 1.200 Punkten: Silberne Maske und 2 Gala-Kisten.',
      );
      expect(
        galaPrizeText(
          const GalaOwnPrize(
            rank: 3,
            score: 900,
            prize: 'bronze',
            crates: 1,
            trophy: GalaTrophy.bronze,
          ),
        ),
        'Platz 3 mit 900 Punkten: Bronzene Maske und 1 Gala-Kiste.',
      );
      expect(
        galaPrizeText(
          const GalaOwnPrize(
            rank: 5,
            score: 1500,
            prize: 'climber',
            crates: 1,
            previous: 300,
          ),
        ),
        'Aufsteiger des Monats! Von 300 auf 1.500 Punkte: 1 Gala-Kiste.',
      );
      expect(
        galaPrizeText(
          const GalaOwnPrize(rank: 6, score: 10, prize: 'applause', gage: 50),
        ),
        'Applaus für Platz 6! 50 Gage sind auf deinem Konto.',
      );
      expect(galaPrizeText(null), contains('nicht auf der Liste'));
      expect(galaMonthText('2026-10'), 'Oktober 2026');
      expect(galaMonthText('kaputt'), 'kaputt');
    });
  });

  group('feature', () {
    testWidgets('it takes both runnerMonthlyGala and the duplicates', (
      tester,
    ) async {
      expect(monthlyGalaAvailable(await _signedIn((_) => null)), isTrue);
      expect(
        monthlyGalaAvailable(
          await _signedIn(
            (_) => null,
            features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes'],
          ),
        ),
        isFalse,
      );
      expect(
        monthlyGalaAvailable(
          await _signedIn(
            (_) => null,
            features: const [
              'stageRunner',
              'runnerUnlocks',
              'runnerMonthlyGala',
            ],
          ),
        ),
        isFalse,
      );
    });
  });

  group('celebration', () {
    testWidgets(
      'shows podium and prize once, marks it seen and offers the crate',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final seen = <JsonMap>[], opened = <JsonMap>[];
        final changed = <Wardrobe>[];
        final after = _wardrobeJson(gala: _galaJson(unseen: null));
        final controller = await _signedIn((request) {
          final path = _path(request);
          if (path.endsWith('/games/runner/gala')) {
            return Future.value(jsonResponse({'gala': _viewJson}));
          }
          if (path.endsWith('/games/runner/gala/seen')) {
            expect(request.method, 'PUT');
            seen.add(jsonMap(jsonDecode(request.body)));
            return Future.value(jsonResponse(after));
          }
          if (path.endsWith('/games/runner/crates')) {
            opened.add(jsonMap(jsonDecode(request.body)));
            return Future.value(
              jsonResponse({
                'item': _item('maren', 'character', 'Maren'),
                'reel': List.filled(56, 'maren'),
                'winnerIndex': 48,
                'outcome': {'type': 'new', 'crate': 'gala', 'month': '2026-10'},
                'wardrobe': _wardrobeJson(
                  gala: _galaJson(crates: 2, unseen: null),
                )..['owned'] = ['c0', 'b0', 'o0', 'f0', 'maren'],
              }),
            );
          }
          return null;
        });
        final sound = _Sound();
        final w = Wardrobe.fromJson(_wardrobeJson(gala: _galaJson()));
        await tester.pumpWidget(_host(controller, w, sound, changed.add));
        await tester.tap(find.text('Spiel öffnen'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const ValueKey('gala-celebration')), findsOneWidget);
        expect(sound.played, [RunnerSfx.jackpot]);
        expect(find.text('Gala des Monats Oktober'), findsOneWidget);
        // Two share gold, nobody stands on silver.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('gala-podium-gold')),
            matching: find.text('Anna'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('gala-podium-gold')),
            matching: find.text('Ben'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('gala-podium-silver')), findsNothing);
        expect(
          find.byKey(const ValueKey('gala-podium-bronze')),
          findsOneWidget,
        );
        expect(
          find.text(
            'Platz 1 mit 1.400 Punkten: Goldene Maske und 3 Gala-Kisten.',
          ),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(seen, isEmpty);
        await tester.tap(find.byKey(const ValueKey('gala-celebration-open')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 400));
        expect(seen.single, {'month': '2026-10'});
        expect(changed.single.gala.unseen, isNull);
        expect(opened.single, {'dupes': true, 'crate': 'gala'});
        expect(find.byKey(const ValueKey('gala-celebration')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('nothing to celebrate asks nothing', (tester) async {
      final asked = <String>[];
      final controller = await _signedIn((request) {
        asked.add(_path(request));
        return null;
      });
      asked.clear();
      final sound = _Sound();
      final w = Wardrobe.fromJson(_wardrobeJson(gala: _galaJson(unseen: null)));
      await tester.pumpWidget(_host(controller, w, sound, (_) {}));
      await tester.tap(find.text('Spiel öffnen'));
      await tester.pumpAndSettle();
      expect(asked.where((p) => p.contains('/gala')), isEmpty);
      expect(find.byKey(const ValueKey('gala-celebration')), findsNothing);
      expect(sound.played, isEmpty);
    });

    testWidgets('an older server or app asks nothing either', (tester) async {
      final asked = <String>[];
      final controller = await _signedIn((request) {
        asked.add(_path(request));
        return null;
      }, features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes']);
      asked.clear();
      final w = Wardrobe.fromJson(_wardrobeJson(gala: _galaJson()));
      await tester.pumpWidget(_host(controller, w, _Sound(), (_) {}));
      await tester.tap(find.text('Spiel öffnen'));
      await tester.pumpAndSettle();
      expect(asked.where((p) => p.contains('/gala')), isEmpty);
      expect(find.byKey(const ValueKey('gala-celebration')), findsNothing);
    });

    testWidgets('a failed request stays unseen for the next time', (
      tester,
    ) async {
      final seen = <JsonMap>[];
      final failed = <Object>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/games/runner/gala')) {
          return Future.value(jsonResponse({'error': 'x'}, 500));
        }
        if (path.endsWith('/gala/seen')) {
          seen.add(jsonMap(jsonDecode(request.body)));
        }
        return null;
      });
      final w = Wardrobe.fromJson(_wardrobeJson(gala: _galaJson()));
      await tester.pumpWidget(
        _host(controller, w, _Sound(), (_) {}, failed: failed.add),
      );
      await tester.tap(find.text('Spiel öffnen'));
      await tester.pumpAndSettle();
      expect(failed, hasLength(1));
      expect(find.byKey(const ValueKey('gala-celebration')), findsNothing);
      expect(seen, isEmpty);
    });

    testWidgets('who was not on the list sees the podium, without a crate', (
      tester,
    ) async {
      final seen = <String>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/games/runner/gala')) {
          return Future.value(
            jsonResponse({
              'gala': {
                ...jsonMap(_viewJson),
                'own': null,
                'podium': [
                  {
                    'rank': 2,
                    'name': 'Ben',
                    'score': 800,
                    'trophy': 'silver',
                    'me': false,
                  },
                ],
              },
            }),
          );
        }
        if (path.endsWith('/gala/seen')) {
          seen.add(path);
          return Future.value(
            jsonResponse(_wardrobeJson(gala: _galaJson(crates: 0))),
          );
        }
        return null;
      });
      final w = Wardrobe.fromJson(_wardrobeJson(gala: _galaJson(crates: 0)));
      await tester.pumpWidget(_host(controller, w, _Sound(), (_) {}));
      await tester.tap(find.text('Spiel öffnen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('gala-podium-silver')), findsOneWidget);
      expect(find.byKey(const ValueKey('gala-celebration-open')), findsNothing);
      expect(find.textContaining('nicht auf der Liste'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byKey(const ValueKey('gala-celebration-close')));
      await tester.pumpAndSettle();
      expect(seen, hasLength(1));
    });
  });

  group('wardrobe', () {
    Future<AppController> open(
      WidgetTester tester, {
      required JsonMap wardrobe,
      List<String> features = _features,
      List<JsonMap>? opened,
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/games/runner/wardrobe')) {
          return Future.value(jsonResponse(wardrobe));
        }
        if (path.endsWith('/games/runner/crates')) {
          opened?.add(jsonMap(jsonDecode(request.body)));
          return Future.value(
            jsonResponse({
              'item': _item('maren', 'character', 'Maren'),
              'reel': List.filled(56, 'maren'),
              'winnerIndex': 48,
              'outcome': {'type': 'new', 'crate': 'gala', 'month': '2026-10'},
              'wardrobe': wardrobe,
            }),
          );
        }
        return path.contains('/games/runner/')
            ? Future.value(jsonResponse({}))
            : null;
      }, features: features);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: WardrobeScreen(controller: controller, sound: _Sound()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('wardrobe-tab-crates')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return controller;
    }

    testWidgets('the Vitrine shows masks and crates, which open as a gala', (
      tester,
    ) async {
      final opened = <JsonMap>[];
      await open(
        tester,
        wardrobe: _wardrobeJson(gala: _galaJson(crates: 2, unseen: null)),
        opened: opened,
      );
      expect(find.byKey(const ValueKey('runner-gala-vitrine')), findsOneWidget);
      expect(find.text('Oktober 2026'), findsOneWidget);
      expect(find.text('2 Gala-Kisten bereit'), findsOneWidget);
      expect(find.byKey(const ValueKey('gala-mask-gold')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('gala-open')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('gala-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(opened.single, {'dupes': true, 'crate': 'gala'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without crates or trophies there is no Vitrine', (
      tester,
    ) async {
      await open(
        tester,
        wardrobe: _wardrobeJson(
          gala: _galaJson(crates: 0, unseen: null, trophies: const []),
        ),
      );
      expect(find.byKey(const ValueKey('runner-gala-vitrine')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the feature the wardrobe shows nothing of it', (
      tester,
    ) async {
      await open(
        tester,
        wardrobe: _wardrobeJson(gala: _galaJson(unseen: null)),
        features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes'],
      );
      expect(find.byKey(const ValueKey('runner-gala-vitrine')), findsNothing);
      expect(find.textContaining('Gala-Kiste'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('ranking', () {
    testWidgets('the winners carry their mask beside the name', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RunnerRankingCard(
                view: RunnerBoardView.score,
                onView: (_) {},
                board: Leaderboard.fromJson({
                  'top': [
                    {
                      'rank': 1,
                      'personId': 1,
                      'name': 'Anna',
                      'score': 900,
                      'trophy': 'silver',
                    },
                    {'rank': 2, 'personId': 2, 'name': 'Ben', 'score': 800},
                  ],
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('gala-mask-silver')), findsOneWidget);
      expect(find.byType(GalaMask), findsOneWidget);
      expect(find.byTooltip('Silberne Maske'), findsOneWidget);
    });
  });
}
