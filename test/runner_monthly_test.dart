import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/leaderboard_api.dart';
import 'package:theater_app/features/games/data/runner_menu_preferences.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/runner_menu.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

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

JsonMap _row(int rank, int person, String name, int score) => {
  'rank': rank,
  'personId': person,
  'name': name,
  'score': score,
};

/// The all-time list: ten others, the own place 12 of 14.
final _allTime = {
  'players': 14,
  'top': [for (var i = 1; i <= 10; i++) _row(i, 100 + i, 'Person $i', 2000)],
  'own': _row(12, 3, 'Testmitglied', 830),
};

/// October's list: ten others, the own place 11 of 11.
final _october = {
  'period': 'month',
  'month': '2026-10',
  'startsAt': '2026-09-30T22:00:00.000Z',
  'endsAt': '2026-10-31T23:00:00.000Z',
  'players': 11,
  'top': [for (var i = 1; i <= 10; i++) _row(i, 200 + i, 'Monat $i', 900)],
  'own': _row(11, 3, 'Testmitglied', 120),
};

final _collection = {
  'total': 6,
  'entries': [
    {
      'personId': 3,
      'name': 'Testmitglied',
      'owned': 2,
      'shiny': 0,
      'percent': 33.3,
      'rank': 1,
      'me': true,
    },
  ],
};

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerCollection',
  'runnerMonthlyLeaderboard',
];

/// A server with the rankings; [monthStatus] answers the month list.
Future<(AppController, List<Uri>)> _server({
  List<String> features = _features,
  int monthStatus = 200,
}) async {
  final calls = <Uri>[];
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (!path.contains('/games/runner/')) return null;
    calls.add(request.url);
    if (path.endsWith('/leaderboard')) {
      if (request.url.queryParameters['period'] == 'month') {
        return Future.value(
          monthStatus == 200
              ? jsonResponse(_october)
              : jsonResponse({'error': 'kaputt'}, monthStatus),
        );
      }
      return Future.value(jsonResponse(_allTime));
    }
    if (path.endsWith('/collection')) {
      return Future.value(jsonResponse(_collection));
    }
    return Future.value(jsonResponse({'error': 'not found'}, 404));
  };
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return (controller, calls);
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _inSwitch(String text) => find.descendant(
  of: find.byKey(const ValueKey('ranking-switch')),
  matching: find.text(text),
);

Finder _own(String text) => find.descendant(
  of: find.byKey(const ValueKey('ranking-own')),
  matching: find.text(text),
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('month headline', () {
    final end = DateTime.parse('2026-10-31T23:00:00Z');
    String? at(String now, [String month = '2026-10', DateTime? endsAt]) =>
        monthHeadline(month, endsAt ?? end, DateTime.parse(now));

    test('counts the days left in German time, today included', () {
      expect(at('2026-10-29T11:00:00Z'), 'Oktober 2026 · noch 3 Tage');
      expect(at('2026-10-30T22:30:00Z'), 'Oktober 2026 · noch 2 Tage');
      // 23:30 UTC on the 30th is already the last day in Berlin.
      expect(at('2026-10-30T23:30:00Z'), 'Oktober 2026 · letzter Tag');
      expect(at('2026-10-31T22:59:00Z'), 'Oktober 2026 · letzter Tag');
      expect(at('2026-10-31T23:00:00Z'), 'Oktober 2026');
    });

    test('summer time at the start of October, umlauts in March', () {
      // 00:30 on 1 October in Berlin is 22:30 UTC the day before.
      expect(at('2026-09-30T22:30:00Z'), 'Oktober 2026 · noch 31 Tage');
      expect(at('2026-10-10T22:30:00Z'), 'Oktober 2026 · noch 21 Tage');
      final march = DateTime.parse('2027-03-31T22:00:00Z');
      expect(
        at('2027-02-28T23:30:00Z', '2027-03', march),
        'März 2027 · noch 31 Tage',
      );
      expect(
        at('2027-03-31T21:30:00Z', '2027-03', march),
        'März 2027 · letzter Tag',
      );
      expect(monthHeadline('kaputt', null, DateTime(2026)), isNull);
      expect(
        monthHeadline('2026-12', null, DateTime.utc(2026, 12, 1, 12)),
        'Dezember 2026 · noch 31 Tage',
      );
    });
  });

  group('remembered ranking', () {
    Future<RunnerBoardView> restored(Map<String, Object> stored) async {
      SharedPreferences.setMockInitialValues(stored);
      final menu = RunnerMenuPreferences();
      addTearDown(menu.dispose);
      await menu.loaded;
      return menu.board;
    }

    test('new members start with the month', () async {
      expect(await restored({}), RunnerBoardView.month);
    });

    test('the old points default moves on to the month', () async {
      expect(
        await restored({RunnerMenuPreferences.legacyBoardKey: 'score'}),
        RunnerBoardView.month,
      );
    });

    test('a chosen collection stays, a new choice wins', () async {
      expect(
        await restored({RunnerMenuPreferences.legacyBoardKey: 'collection'}),
        RunnerBoardView.collection,
      );
      expect(
        await restored({
          RunnerMenuPreferences.legacyBoardKey: 'collection',
          RunnerMenuPreferences.boardKey: 'score',
        }),
        RunnerBoardView.score,
      );
    });
  });

  group('ranking card', () {
    testWidgets('shows the month headline and an empty month', (tester) async {
      await _pump(
        tester,
        Scaffold(
          body: RunnerRankingCard(
            view: RunnerBoardView.month,
            onView: (_) {},
            monthShown: true,
            monthly: Leaderboard.fromJson({
              ..._october,
              'top': [],
              'own': null,
            }),
            board: Leaderboard.fromJson(_allTime),
            now: DateTime.parse('2026-10-29T11:00:00Z'),
          ),
        ),
      );
      expect(find.text('Oktober 2026 · noch 3 Tage'), findsOneWidget);
      expect(
        find.text(
          'Diesen Monat hat noch niemand Punkte. Lauf als Erste oder Erster!',
        ),
        findsOneWidget,
      );
      expect(_inSwitch('Monat'), findsOneWidget);
      expect(_inSwitch('Allzeit'), findsOneWidget);
      expect(_inSwitch('Sammlung'), findsNothing);
    });
  });

  group('menu', () {
    testWidgets('the month comes first, then all time and the collection', (
      tester,
    ) async {
      final (controller, calls) = await _server();
      final menu = RunnerMenuPreferences();
      addTearDown(menu.dispose);
      await _pump(
        tester,
        StageRunnerScreen(
          controller: controller,
          sound: _Sound(),
          menuPreferences: menu,
        ),
      );
      expect(
        calls.where((u) => u.queryParameters['period'] == 'month'),
        hasLength(1),
      );
      // Three parts in this order, the month chosen.
      final x = [
        for (final t in ['Monat', 'Allzeit', 'Sammlung'])
          tester.getCenter(_inSwitch(t)).dx,
      ];
      expect(x[0], lessThan(x[1]));
      expect(x[1], lessThan(x[2]));
      expect(menu.board, RunnerBoardView.month);
      expect(find.textContaining('Oktober 2026'), findsOneWidget);
      expect(find.text('Monat 1'), findsOneWidget);
      expect(find.text('Person 1'), findsNothing);
      // Place 11 is beyond the first ten, yet the own row shows highlighted.
      expect(_own('Testmitglied'), findsOneWidget);
      expect(_own('120'), findsOneWidget);
      // "Dein Stand": the best of all time with this month's place.
      expect(find.text('830'), findsOneWidget);
      expect(find.text('Platz 11 diesen Monat'), findsOneWidget);
      expect(find.text('Platz 12 von 14'), findsNothing);

      await tester.tap(_inSwitch('Allzeit'));
      await tester.pump();
      expect(menu.board, RunnerBoardView.score);
      expect(find.text('Person 1'), findsOneWidget);
      expect(find.textContaining('Oktober 2026'), findsNothing);
      expect(_own('830'), findsOneWidget);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(RunnerMenuPreferences.boardKey), 'score');

      await tester.tap(_inSwitch('Sammlung'));
      await tester.pump();
      expect(menu.board, RunnerBoardView.collection);
      expect(find.text('2/6'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failing month list falls back to all time quietly', (
      tester,
    ) async {
      final (controller, _) = await _server(monthStatus: 500);
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(_inSwitch('Monat'), findsNothing);
      expect(_inSwitch('Punkte'), findsOneWidget);
      expect(_inSwitch('Sammlung'), findsOneWidget);
      expect(find.text('Person 1'), findsOneWidget);
      expect(find.text('Platz 12 von 14'), findsOneWidget);
      expect(find.text('kaputt'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the announcement the month is not asked for', (
      tester,
    ) async {
      final (controller, calls) = await _server(
        features: [..._features]..remove('runnerMonthlyLeaderboard'),
      );
      expect(monthlyBoardAvailable(controller), isFalse);
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _Sound()),
      );
      expect(
        calls.where((u) => u.queryParameters.containsKey('period')),
        isEmpty,
      );
      expect(_inSwitch('Monat'), findsNothing);
      expect(_inSwitch('Punkte'), findsOneWidget);
      expect(find.text('Person 1'), findsOneWidget);
      expect(find.text('Platz 12 von 14'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
