import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/data/weekly_api.dart';
import 'package:theater_app/features/games/ui/crate_choice.dart';
import 'package:theater_app/features/games/ui/crate_opening.dart';
import 'package:theater_app/features/games/ui/runner_menu.dart';
import 'package:theater_app/features/games/ui/runner_weekly.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// The rewards of the Wochenprobe (`runnerWeeklyRewards`): the Wochenkiste for
// taking part, Pokal and Gage for the places 1 to 3, and the Pokale counted.

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerWeekly',
  'runnerWeeklyRewards',
];

class _Sound implements RunnerSound {
  final _enabled = ValueNotifier(false);
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

// ---------------------------------------------------------------------------
// The weekly view.

/// The test clock's week (`fixedNow` is Saturday, 12 September 2026).
JsonMap _week({JsonMap? lastWeek, JsonMap? trophies}) => {
  'week': '2026-W37',
  'seed': 31415,
  'startsAt': '2026-09-06T22:00:00.000Z',
  'endsAt': '2026-09-13T22:00:00.000Z',
  'attempts': {'used': 1, 'max': 3},
  'best': {'score': 120, 'meters': 100},
  'leaderboard': [
    {
      'rank': 1,
      'personId': 7,
      'name': 'Lena',
      'score': 900,
      'meters': 880,
      'at': '2026-09-10T18:00:00.000Z',
      'me': false,
      'trophies': {'gold': 3, 'silver': 0, 'bronze': 1},
    },
    {
      'rank': 2,
      'personId': 3,
      'name': 'Testmitglied',
      'score': 120,
      'meters': 100,
      'at': '2026-09-10T19:00:00.000Z',
      'me': true,
      'trophies': ?trophies,
    },
    {
      'rank': 3,
      'personId': 8,
      'name': 'Jonas',
      'score': 80,
      'meters': 60,
      'at': '2026-09-10T20:00:00.000Z',
      'me': false,
      'trophies': {'gold': 0, 'silver': 0, 'bronze': 0},
    },
  ],
  'ghosts': <Object?>[],
  'lastWeek': lastWeek,
  'trophies': ?trophies,
};

/// A week whose first place has a long name and nine Pokale of every kind;
/// [everyone] gives all three places as many.
JsonMap _crowdedWeek({bool everyone = false}) {
  const many = {'gold': 9, 'silver': 9, 'bronze': 9};
  final week = _week(trophies: many);
  return {
    ...week,
    'leaderboard': [
      for (final (i, e) in jsonList(week['leaderboard']).indexed)
        {
          ...jsonMap(e),
          if (i == 0) 'name': 'Maximiliane von Hohenzollern-Sigmaringen',
          if (i == 0 || everyone) 'trophies': many,
        },
    ],
  };
}

const _silver = {
  'week': '2026-W36',
  'rank': 2,
  'score': 640,
  'gage': 50,
  'trophy': 'silver',
  'crates': 1,
};

// ---------------------------------------------------------------------------
// The wardrobe.

JsonMap _item(String id, String kind, {bool isDefault = false}) => {
  'id': id,
  'kind': kind,
  'name': id,
  'rarity': 'hell',
  'rarities': ['hell'],
  if (isDefault) 'default': true,
};

const _crate = {
  'id': 'weekly',
  'kind': 'weekly',
  'name': 'Wochenkiste',
  'animation': 'generic',
  'shinyChance': 0.15,
};

JsonMap _wardrobe({int crates = 0, bool weekly = true, int galaCrates = 0}) => {
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hell', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
    ],
    'items': [
      _item('c0', 'character', isDefault: true),
      _item('b0', 'backdrop', isDefault: true),
      _item('o0', 'obstacles', isDefault: true),
      _item('f0', 'fx', isDefault: true),
      _item('maren', 'character'),
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0'],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'progress': {
    'meters': 100,
    'crates': 0,
    'nextAt': 2000,
    'dupes': true,
    'poolSize': 1,
    'galaCrates': galaCrates,
    if (weekly) 'weeklyCrates': crates,
  },
  if (weekly)
    'weekly': {
      'crates': crates,
      'trophies': {'gold': 2, 'silver': 1, 'bronze': 0},
      'crate': _crate,
    },
};

JsonMap _opening(JsonMap wardrobe) => {
  'item': _item('maren', 'character'),
  'reel': List.filled(56, 'maren'),
  'winnerIndex': 48,
  'outcome': {'type': 'new', 'crate': 'weekly', 'week': '2026-W36'},
  'wardrobe': wardrobe,
};

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('texts', () {
    test('last week’s banner names everything it brought', () {
      expect(
        weeklyRewardText(2, 50, trophy: WeeklyTrophy.silver, crates: 1),
        'Letzte Woche: Platz 2 · Silber-Pokal · +50 Gage · 1 Wochenkiste',
      );
      expect(
        weeklyRewardText(1, 100, trophy: WeeklyTrophy.gold, crates: 1),
        'Letzte Woche: Platz 1 · Gold-Pokal · +100 Gage · 1 Wochenkiste',
      );
      expect(
        weeklyRewardText(7, 0, crates: 1),
        'Letzte Woche: Platz 7 · 1 Wochenkiste',
      );
      expect(
        weeklyRewardText(3, 25, trophy: WeeklyTrophy.bronze, crates: 2),
        'Letzte Woche: Platz 3 · Bronze-Pokal · +25 Gage · 2 Wochenkisten',
      );
      // As an older server tells it.
      expect(weeklyRewardText(2, 20), 'Letzte Woche: Platz 2 · +20 Gage');
    });

    test('the Pokale count the best first', () {
      expect(
        const WeeklyTrophies(gold: 2, silver: 1).text,
        '2× Wochensieger, 1× Silber',
      );
      expect(
        const WeeklyTrophies(bronze: 4, gold: 1).text,
        '1× Wochensieger, 4× Bronze',
      );
      expect(WeeklyTrophies.none.text, isEmpty);
      expect(WeeklyTrophies.none.isEmpty, isTrue);
    });
  });

  group('data', () {
    test('the week reads the Pokale and last week’s reward', () {
      final week = WeeklyChallenge.fromJson(
        _week(lastWeek: _silver, trophies: {'gold': 2, 'silver': 1}),
        me: 3,
      );
      expect(week.trophies.gold, 2);
      expect(week.trophies.silver, 1);
      expect(week.trophies.bronze, 0);
      final lena = week.leaderboard.first;
      expect((lena.trophies.gold, lena.trophies.bronze), (3, 1));
      expect(week.leaderboard.last.trophies.isEmpty, isTrue);
      final last = week.lastWeek!;
      expect(last.week, '2026-W36');
      expect((last.rank, last.score, last.gage), (2, 640, 50));
      expect(last.trophy, WeeklyTrophy.silver);
      expect(last.crates, 1);
      // Kept once the banner was seen.
      expect(week.withoutLastWeek().trophies.gold, 2);
    });

    test(
      'older servers send no Pokal, no crate and none of an unknown kind',
      () {
        final week = WeeklyChallenge.fromJson({
          ..._week(),
          'lastWeek': {
            'week': '2026-W36',
            'rank': 1,
            'score': 640,
            'gage': 30,
            'trophy': 'platinum',
            'crates': -1,
          },
        });
        expect(week.trophies.isEmpty, isTrue);
        expect(week.lastWeek!.trophy, isNull);
        expect(week.lastWeek!.crates, 0);
        expect(WeeklyTrophies.of({'gold': 'x', 'silver': -2}).isEmpty, isTrue);
      },
    );

    test('the wardrobe counts the Wochenkisten with all waiting crates', () {
      final w = Wardrobe.fromJson(_wardrobe(crates: 2, galaCrates: 1));
      expect(w.weekly.crates, 2);
      expect(w.weekly.trophies.text, '2× Wochensieger, 1× Silber');
      expect(w.weekly.crate?.kind, CrateTargetKind.weekly);
      expect(w.weekly.crate?.shinyChance, 0.15);
      expect(crateTargetSubtitle(w.weekly.crate!), 'Alles aus dem Fundus');
      expect(w.progress.weeklyCrates, 2);
      expect(w.progress.waiting, 3);
      expect(crateWaiting(w), isTrue);
    });

    test('older servers have none', () {
      final w = Wardrobe.fromJson(_wardrobe(weekly: false));
      expect(w.weekly.crates, 0);
      expect(w.weekly.crate, isNull);
      expect(w.weekly.trophies.isEmpty, isTrue);
      expect(w.progress.waiting, 0);
      expect(crateWaiting(w), isFalse);
    });

    test('only the progress tells the count: still counted', () {
      final json = _wardrobe(crates: 1)..remove('weekly');
      final w = Wardrobe.fromJson(json);
      expect(w.weekly.crates, 1);
      expect(w.weekly.crate, isNull);
    });
  });

  group('weekly page', () {
    Future<List<String>> open(
      WidgetTester tester, {
      required JsonMap week,
      List<String> features = _features,
      Size size = const Size(420, 1800),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <String>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (!path.contains('/games/runner/')) return null;
        calls.add('${request.method} ${path.split('/games/runner/').last}');
        if (path.endsWith('/weekly')) return Future.value(jsonResponse(week));
        return Future.value(jsonResponse({'ok': true}));
      }, features: features);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: RunnerWeeklyScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('the banner shows Pokal, Gage and Wochenkiste once', (
      tester,
    ) async {
      final calls = await open(tester, week: _week(lastWeek: _silver));
      expect(
        find.text(
          'Letzte Woche: Platz 2 · Silber-Pokal · +50 Gage · 1 Wochenkiste',
        ),
        findsOneWidget,
      );
      final banner = find.byKey(const ValueKey('weekly-reward'));
      final cup = tester.widget<Icon>(
        find.descendant(of: banner, matching: find.byIcon(Icons.emoji_events)),
      );
      expect(cup.color, WeeklyTrophy.silver.color);
      expect(calls, contains('PUT weekly/seen'));
    });

    testWidgets('the ranking shows everyone’s Pokale, the page the own', (
      tester,
    ) async {
      await open(tester, week: _week(trophies: {'gold': 2, 'silver': 1}));
      expect(
        find.text('Deine Pokale: 2× Wochensieger, 1× Silber'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('weekly-rewards-note')), findsOneWidget);
      final ranking = find.byKey(const ValueKey('weekly-ranking'));
      final badges = find.descendant(
        of: ranking,
        matching: find.byType(WeeklyTrophyBadges),
      );
      // Lena and the own row; Jonas has none.
      expect(badges, findsNWidgets(2));
      expect(
        find.descendant(of: ranking, matching: find.text('3×')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: ranking, matching: find.text('2×')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: ranking, matching: find.text('1×')),
        findsNWidgets(2),
      );
      expect(find.byTooltip('3× Wochensieger, 1× Bronze'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the badges fit beside long names on a small phone', (
      tester,
    ) async {
      await open(tester, week: _crowdedWeek(), size: const Size(320, 1400));
      expect(
        find.text('Maximiliane von Hohenzollern-Sigmaringen'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.3, 1.5, 2.0]) {
      testWidgets('the badges fit on a small phone at a ${scale}x font', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await open(
          tester,
          week: _crowdedWeek(everyone: true),
          size: const Size(320, 800),
        );
        expect(tester.takeException(), isNull);
        // The ranking sits below the fold at a large font.
        final ranking = find.byType(RunnerRankRow);
        await tester.scrollUntilVisible(
          find.text('Jonas'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(ranking, findsNWidgets(3));
        for (var i = 0; i < 3; i++) {
          final row = tester.getRect(ranking.at(i));
          final badges = tester.getRect(
            find.descendant(
              of: ranking.at(i),
              matching: find.byType(WeeklyTrophyBadges),
            ),
          );
          expect(badges.right, lessThanOrEqualTo(row.right + 0.01));
        }
      });
    }

    testWidgets('a screen reader hears the own Pokale only once', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await open(tester, week: _week(trophies: {'gold': 2, 'silver': 1}));
      // Said once, by the text: the cups beside it stay silent.
      expect(
        find.bySemanticsLabel(
          RegExp('Deine Pokale: 2× Wochensieger, 1× Silber'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp('Pokale: 2× Wochensieger, 1× Silber\nDeine Pokale'),
        ),
        findsNothing,
      );
      semantics.dispose();
    });

    testWidgets('a screen reader hears the Pokale', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, week: _week());
      expect(
        find.bySemanticsLabel(
          RegExp('Lena\nPokale: 3× Wochensieger, 1× Bronze\n900'),
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('an older server: no Pokale, no note', (tester) async {
      await open(
        tester,
        week: {
          ..._week(),
          'leaderboard': [
            for (final e in jsonList(_week()['leaderboard']))
              {...jsonMap(e)}..remove('trophies'),
          ],
        },
        features: const ['stageRunner', 'runnerWeekly'],
      );
      expect(find.byType(WeeklyTrophyBadges), findsNothing);
      expect(find.byKey(const ValueKey('weekly-trophies')), findsNothing);
      expect(find.byKey(const ValueKey('weekly-rewards-note')), findsNothing);
    });
  });

  group('Wochenkiste', () {
    Future<List<http.Request>> openWardrobe(
      WidgetTester tester, {
      required JsonMap wardrobe,
      List<String> features = _features,
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final requests = <http.Request>[];
      final controller = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/games/runner/wardrobe')) {
          return Future.value(jsonResponse(wardrobe));
        }
        if (path.endsWith('/games/runner/crates')) {
          requests.add(request);
          return Future.value(jsonResponse(_opening(_wardrobe(crates: 1))));
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
      return requests;
    }

    testWidgets('the wardrobe opens it with the other crates', (tester) async {
      final requests = await openWardrobe(
        tester,
        wardrobe: _wardrobe(crates: 2),
      );
      expect(find.text('Wochenkiste öffnen (2)'), findsOneWidget);
      final ready = find.byKey(const ValueKey('wardrobe-ready-weekly'));
      await tester.ensureVisible(ready);
      await tester.pump();
      await tester.tap(ready);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(jsonDecode(requests.single.body), {
        'dupes': true,
        'crate': 'weekly',
      });
      expect(find.text('Die Wochenkiste geht auf …'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the feature the wardrobe offers none', (tester) async {
      await openWardrobe(
        tester,
        wardrobe: _wardrobe(crates: 2),
        features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes'],
      );
      expect(find.textContaining('Wochenkiste'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a lost reply opens the same crate again; then the next', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final requests = <http.Request>[];
      final controller = await _signedIn((request) {
        if (!_path(request).endsWith('/games/runner/crates')) return null;
        requests.add(request);
        if (requests.length == 1) {
          return Future.error(http.ClientException('lost'));
        }
        return Future.value(
          jsonResponse(
            _opening(_wardrobe(crates: requests.length == 2 ? 1 : 0)),
          ),
        );
      });
      final before = Wardrobe.fromJson(_wardrobe(crates: 2));
      final sound = _Sound();
      addTearDown(sound.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: CrateOpeningPage(
            controller: controller,
            wardrobe: before,
            sound: sound,
            weekly: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Erneut versuchen'), findsOneWidget);
      await tester.tap(find.text('Erneut versuchen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(requests, hasLength(2));
      final firstKey = requests[0].headers['Idempotency-Key'];
      expect(firstKey, isNotEmpty);
      expect(requests[1].headers['Idempotency-Key'], firstKey);
      expect(jsonDecode(requests[1].body), {'dupes': true, 'crate': 'weekly'});

      final next = find.text('Nächste Kiste (1)');
      for (var i = 0; i < 100 && next.evaluate().isEmpty; i++) {
        await tester.tapAt(const Offset(400, 300));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(next, findsOneWidget);
      await tester.tap(next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(requests, hasLength(3));
      expect(requests[2].headers['Idempotency-Key'], isNot(firstKey));
      expect(jsonMap(jsonDecode(requests[2].body))['crate'], 'weekly');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
