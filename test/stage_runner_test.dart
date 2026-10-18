import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/platform/pwa_install.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/changelog/changelog.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/me/me.dart';
import 'package:theater_app/shared/widgets/brand_logo.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

void _size(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  _size(tester);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  await tester.pumpAndSettle();
}

JsonMap _board({List<JsonMap> top = const [], JsonMap? own}) => {
  'players': top.length,
  'top': top,
  'own': own,
};

JsonMap _entry(int rank, int personId, String name, int score) => {
  'rank': rank,
  'personId': personId,
  'name': name,
  'score': score,
  'achievedAt': '2026-09-12T10:00:00.000Z',
};

/// The server's limit (`runnerMaxScore` in server/src/theater.mjs).
int _serverMax(double seconds) =>
    (RunnerRules.maxMeters(seconds + 5) *
                (1 + RunnerRules.pickupPointsPerMeter) *
                1.15 +
            60)
        .ceil();

/// Flies towards the next pickup, ignoring obstacles (the runner is
/// invincible), to collect as much as possible.
void _greedyStep(StageRunner game) {
  final ahead = game.pickups.where((p) => p.x > game.runnerWorldX - .02);
  final target = ahead.isEmpty
      ? null
      : ahead.reduce((a, b) => a.x < b.x ? a : b);
  game.holding = target != null && target.y < game.y;
  game.update(1 / 60);
}

Future<AppController> _demo() async {
  final demo = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
    clock: () => fixedNow,
  );
  addTearDown(demo.dispose);
  await demo.startDemo();
  return demo;
}

/// Pumps frames until the run is over and the result shows.
Future<void> _runUntilOver(WidgetTester tester) async {
  for (var i = 0; i < 60 * 20 && find.text('Nochmal').evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('run', () {
    test('the speed grows to a limit, as the server assumes', () {
      expect(RunnerRules.speedAt(0), .55);
      expect(RunnerRules.speedAt(100), closeTo(1.55, 1e-9));
      expect(RunnerRules.speedAt(1000), RunnerRules.maxSpeed);
      expect(RunnerRules.maxMeters(10), closeTo(60, 1e-9));
      final top = (RunnerRules.maxSpeed - RunnerRules.startSpeed) / .01;
      expect(
        RunnerRules.maxMeters(top + 10) - RunnerRules.maxMeters(top),
        closeTo(240, 1e-9),
      );
    });

    test('holding lifts the runner, letting go lets them sink', () {
      final game = StageRunner(random: Random(1));
      final floor = game.y;
      game.holding = true;
      for (var i = 0; i < 20; i++) {
        game.update(.02);
      }
      expect(game.y, lessThan(floor - .1));
      for (var i = 0; i < 200; i++) {
        game.update(.02);
      }
      expect(game.y, StageRunner.ceiling + StageRunner.runnerHeight / 2);
      game.holding = false;
      for (var i = 0; i < 200 && !game.over; i++) {
        game.update(.02);
      }
      expect(game.vy >= 0 || game.over, isTrue);
    });

    test('doing nothing ends the run soon; long frames never skip', () {
      final game = StageRunner(random: Random(2))..update(10);
      expect(game.time, closeTo(.05, 1e-9));
      for (var i = 0; i < 60 * 60 && !game.over; i++) {
        game.update(1 / 60);
      }
      expect(game.over, isTrue);
      final score = game.score;
      game.update(.05);
      expect(game.score, score);
      expect(game.sinceOver, greaterThan(0));
    });

    test('it gets harder until reacting is impossible', () {
      expect(StageRunner.reactionTime(0), 1.2);
      expect(
        StageRunner.reactionTime(1000),
        lessThan(StageRunner.reactionTime(500)),
      );
      expect(StageRunner.reactionTime(3000), .3);
      expect(StageRunner.gapHeight(0), greaterThan(.4));
      expect(StageRunner.gapHeight(5000), .25);
      expect(
        StageRunner.gapHeight(5000),
        greaterThan(StageRunner.runnerHeight * 2),
      );
      expect(StageRunner.reachFactor(1000), lessThan(1));
      expect(StageRunner.reachFactor(2600), greaterThan(1));
    });

    test('scores stay within the server limit and objects are reused', () {
      for (var seed = 0; seed < 6; seed++) {
        final game = StageRunner(random: Random(seed))..invincible = true;
        var most = 0;
        while (game.time < 240) {
          _greedyStep(game);
          most = max(most, game.obstacles.length + game.pickups.length);
        }
        expect(game.collected, greaterThan(10), reason: 'seed $seed');
        expect(
          game.meters,
          lessThanOrEqualTo(RunnerRules.maxMeters(game.time) + 1),
        );
        expect(
          game.placedPickupPoints,
          lessThanOrEqualTo(
            (game.distance + StageRunner.viewWidth + 1.2) *
                RunnerRules.metersPerUnit *
                RunnerRules.pickupPointsPerMeter,
          ),
        );
        expect(game.score, lessThanOrEqualTo(_serverMax(game.time)));
        // Passed objects go back to the pool instead of piling up.
        expect(most, lessThan(40), reason: 'seed $seed');
      }
    });
  });

  group('hidden entry', () {
    Future<void> myArea(WidgetTester tester) async {
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner'],
      };
      server.override = (request) =>
          _path(request).endsWith('/games/runner/leaderboard')
          ? Future.value(jsonResponse(_board()))
          : null;
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      await _pump(
        tester,
        Scaffold(
          body: MyAreaScreen(
            controller: controller,
            devices: DeviceServices(
              controller,
              onTarget: (_) {},
              onForegroundMessage: (_) {},
            ),
            installation: PwaInstallation(),
          ),
        ),
      );
    }

    Finder logo() => find.descendant(
      of: find.byType(AboutDialog),
      matching: find.byType(BrandLogo),
    );

    testWidgets('seven taps on the logo in "Über die App" open the game', (
      tester,
    ) async {
      await myArea(tester);
      expect(find.textContaining('Bühnenlauf'), findsNothing);
      expect(find.textContaining('Bestenliste'), findsNothing);
      await tester.tap(find.text('Über die App'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.tap(logo());
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.byType(StageRunnerScreen), findsNothing);
      expect(find.byType(AboutDialog), findsOneWidget);
      await tester.tap(logo());
      await tester.pumpAndSettle();
      expect(find.byType(AboutDialog), findsNothing);
      expect(find.byType(StageRunnerScreen), findsOneWidget);
      expect(find.text('Vorhang auf'), findsOneWidget);
      expect(
        find.text('Noch keine Punkte. Lauf als Erste oder Erster!'),
        findsOne,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the logo is not announced as a button', (tester) async {
      await myArea(tester);
      await tester.tap(find.text('Über die App'));
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Kolpingtheater Ramsen')),
        isNot(matchesSemantics(isButton: true, hasTapAction: true)),
      );
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    test('"Was ist neu" does not mention the game', () {
      final text = changelog
          .expand((e) => [e.version, ...e.items])
          .join(' ')
          .toLowerCase();
      for (final word in ['minispiel', 'bühnenlauf', 'bestenliste']) {
        expect(text, isNot(contains(word)));
      }
    });
  });

  group('screen', () {
    testWidgets('a run is started and scored on the server', (tester) async {
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner'],
      };
      final calls = <String>[];
      JsonMap? submitted;
      server.override = (request) {
        final path = _path(request);
        if (!path.contains('/games/runner/')) return null;
        calls.add('${request.method} ${path.split('/games/runner/').last}');
        if (path.endsWith('/leaderboard')) {
          return Future.value(
            jsonResponse(_board(top: [_entry(1, 7, 'Kim Beispiel', 800)])),
          );
        }
        if (path.endsWith('/rounds')) {
          return Future.value(jsonResponse({'roundId': 'r-1'}));
        }
        submitted = jsonMap(jsonDecode(request.body));
        final score = intValue(submitted!['score']);
        return Future.value(
          jsonResponse({
            'score': score,
            'improved': true,
            'leaderboard': _board(
              top: [
                _entry(1, 7, 'Kim Beispiel', 800),
                _entry(2, 3, 'Testmitglied', score),
              ],
              own: _entry(2, 3, 'Testmitglied', score),
            ),
          }),
        );
      };
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      late StageRunner game;
      await _pump(
        tester,
        StageRunnerScreen(
          controller: controller,
          random: Random(3),
          onRun: (g) => game = g,
        ),
      );
      expect(find.text('Kim Beispiel'), findsOneWidget);
      expect(find.text('Du stehst noch nicht auf der Liste.'), findsOneWidget);

      await tester.tap(find.text('Vorhang auf'));
      await tester.pump();
      expect(find.byKey(const ValueKey('runner-stage')), findsOneWidget);
      expect(find.text('0 m'), findsOneWidget);
      // Holding anywhere on the screen lifts the runner.
      final floor = game.y;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('runner-stage'))),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(game.y, lessThan(floor - .1));
      await gesture.up();
      await _runUntilOver(tester);

      expect(game.over, isTrue);
      expect(calls, ['GET leaderboard', 'POST rounds', 'POST scores']);
      expect(submitted, {'roundId': 'r-1', 'score': game.score});
      expect(find.text('Der Vorhang fällt!'), findsOneWidget);
      expect(find.text('Neuer persönlicher Bestwert!'), findsOneWidget);
      expect(find.text('Testmitglied'), findsOneWidget);
      expect(find.text('Du stehst noch nicht auf der Liste.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the space bar flies, too', (tester) async {
      late StageRunner game;
      await _pump(
        tester,
        StageRunnerScreen(controller: await _demo(), onRun: (g) => game = g),
      );
      await tester.tap(find.text('Vorhang auf'));
      await tester.pump();
      final floor = game.y;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(game.y, lessThan(floor - .1));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed save keeps the result and explains why', (
      tester,
    ) async {
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner'],
      };
      server.override = (request) {
        final path = _path(request);
        if (path.endsWith('/leaderboard')) {
          return Future.value(jsonResponse(_board()));
        }
        if (path.endsWith('/rounds')) {
          return Future.value(
            jsonResponse({
              'error': 'Gerade wurde sehr oft gespielt.',
              'code': 'rate_limited',
            }, 429),
          );
        }
        if (path.endsWith('/scores')) fail('no run, no score');
        return null;
      };
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, random: Random(3)),
      );
      await tester.tap(find.text('Vorhang auf'));
      await _runUntilOver(tester);
      expect(find.text('Der Vorhang fällt!'), findsOneWidget);
      expect(
        find.textContaining('Nicht in der Bestenliste: Gerade wurde'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the demo plays without a leaderboard, again and again', (
      tester,
    ) async {
      await _pump(tester, StageRunnerScreen(controller: await _demo()));
      expect(find.text('In der Demo gibt es keine Bestenliste.'), findsOne);
      await tester.tap(find.text('Vorhang auf'));
      await _runUntilOver(tester);
      expect(find.text('Der Vorhang fällt!'), findsOneWidget);
      expect(find.textContaining('Bestenliste:'), findsNothing);
      await tester.tap(find.text('Nochmal'));
      await tester.pump();
      expect(find.byKey(const ValueKey('runner-stage')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('older servers show that the list is not available', (
      tester,
    ) async {
      final controller = TestServer().controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      await _pump(tester, StageRunnerScreen(controller: controller));
      expect(
        find.text(
          'Die Bestenliste ist auf diesem Server noch nicht verfügbar.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });
}
