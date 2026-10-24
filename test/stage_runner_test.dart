import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
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
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_fx.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart'
    show RunnerGlyphs;
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/me/me.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/shell/app_shell.dart';
import 'package:theater_app/shared/navigation.dart';
import 'package:theater_app/shared/widgets/brand_logo.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;
import 'shell_navigation_test.dart' show finish, pumpDemo, setWidth;

/// Records what the game would play.
class _FakeSound implements RunnerSound {
  final played = <RunnerSfx>[];
  final _enabled = ValueNotifier(true);
  bool music = false, prepared = false;

  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) {
    _enabled.value = on;
    if (!on) music = false;
  }

  @override
  void prepare() => prepared = true;
  @override
  void play(RunnerSfx sfx) {
    if (_enabled.value) played.add(sfx);
  }

  @override
  void startMusic() => music = _enabled.value;
  @override
  void stopMusic() => music = false;
  @override
  void dispose() => _enabled.dispose();
}

/// Logs the calls on a player instead of touching the platform; any other
/// call throws.
class _RecordingPlayer extends Fake implements AudioPlayer {
  _RecordingPlayer(this.log);
  final List<(_RecordingPlayer, String)> log;
  String? asset;
  @override
  PlayerState state = PlayerState.stopped;

  void _log(String call) => log.add((this, call));

  @override
  set positionUpdater(PositionUpdater? updater) =>
      _log('positionUpdater=${updater ?? 'null'}');
  @override
  Future<void> setPlayerMode(PlayerMode mode) async => _log('setPlayerMode');
  @override
  Future<void> setReleaseMode(ReleaseMode mode) async =>
      _log('setReleaseMode ${mode.name}');
  @override
  Future<void> setSource(Source source) async {
    asset = (source as AssetSource).path;
    _log('setSource $asset');
  }

  @override
  Future<void> setVolume(double volume) async => _log('setVolume $volume');

  /// The length the platform reports for the loaded effect.
  Duration length = const Duration(milliseconds: 400);
  @override
  Future<Duration?> getDuration() async {
    _log('getDuration');
    return length;
  }

  @override
  Future<void> resume() async {
    state = PlayerState.playing;
    _log('resume');
  }

  @override
  Future<void> stop() async {
    state = PlayerState.stopped;
    _log('stop');
  }

  @override
  Future<void> pause() async => _log('pause');
  @override
  Future<void> dispose() async => _log('dispose');
}

/// Logs the Web Audio calls; a decoded clip is named after its asset.
class _FakeWebAudio implements WebAudio {
  _FakeWebAudio(this.assets);

  /// The bytes of each asset, to tell the decoded sounds apart.
  final Map<String, Uint8List> assets;
  final log = <String>[];
  final clips = <String, double>{};
  var plays = 0;

  /// Assets that fail to decode.
  final broken = <String>{};

  @override
  void resume() => log.add('resume');
  @override
  void suspend() => log.add('suspend');
  @override
  Future<WebAudioClip> decode(Uint8List bytes, double volume) async {
    final name = assets.entries
        .singleWhere((e) => listEquals(e.value, bytes))
        .key
        .split('/')
        .last;
    if (broken.contains(name)) throw StateError('cannot decode $name');
    clips[name] = volume;
    return _FakeClip(this, name);
  }

  @override
  void close() => log.add('close');
}

class _FakeClip implements WebAudioClip {
  _FakeClip(this.audio, this.name);
  final _FakeWebAudio audio;
  final String name;
  @override
  WebAudioVoice play({bool loop = false}) {
    final voice = '$name#${++audio.plays}';
    audio.log.add('play $voice${loop ? ' loop' : ''}');
    return _FakeVoice(audio, voice);
  }
}

class _FakeVoice implements WebAudioVoice {
  _FakeVoice(this.audio, this.name);
  final _FakeWebAudio audio;
  final String name;
  @override
  void stop() => audio.log.add('stop $name');
}

/// The game's sounds as the asset bundle has them.
Future<Map<String, Uint8List>> _soundAssets() async => {
  for (final asset in [
    for (final sfx in RunnerSfx.values) sfx.asset,
    'games/stage_runner/music.mp3',
  ])
    asset: Uint8List.sublistView(await rootBundle.load('assets/$asset')),
};

Future<void> _decoded(_FakeWebAudio audio, int count) async {
  for (var i = 0; i < 200 && audio.clips.length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

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

/// Steers around the obstacles like a careful player: towards the free
/// height of the next obstacle ahead, counting moving ones where they can
/// be at their worst (a sandbag landed, a drop at its lowest).
void _pilotStep(StageRunner game) {
  const f = StageRunner.floor, c = StageRunner.ceiling;
  const hw = StageRunner.hitHalfWidth + .01;
  const hh = StageRunner.hitHalfHeight + .015;
  const minY = c + StageRunner.runnerHeight / 2;
  const maxY = f - StageRunner.runnerHeight / 2;
  final x = game.runnerWorldX;
  final ahead = game.obstacles.where((o) => o.right > x - hw).toList()
    ..sort((a, b) => a.left.compareTo(b.left));
  var lo = minY, hi = maxY;
  if (ahead.isNotEmpty) {
    final first = ahead.first;
    for (final o in ahead.where((o) => o.left < first.right + hw)) {
      switch (o.kind) {
        case ObstacleKind.sandbag:
          hi = min(hi, f - (o.bottom - o.top) - hh);
        case ObstacleKind.drop:
          lo = max(lo, o.anchor + StageRunner.dropSwing + hh);
        case _ when o.top <= 0:
          lo = max(lo, o.bottom + hh);
        case _:
          hi = min(hi, o.top - hh);
      }
    }
  }
  final y = game.y;
  final target = lo > hi ? (lo + hi) / 2 : y.clamp(lo, hi).toDouble();
  final wanted = ((target - y) * 10)
      .clamp(-StageRunner.maxRise, StageRunner.maxFall)
      .toDouble();
  game.holding = game.vy > wanted;
  game.update(1 / 60);
}

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

    test('the hitbox is a little smaller than the slim body', () {
      // Wings, arms, head and shoes may graze an obstacle.
      expect(StageRunner.hitHalfWidth * 2, lessThan(StageRunner.runnerWidth));
      expect(StageRunner.hitHalfHeight * 2, lessThan(StageRunner.runnerHeight));
      // A crate just ahead of the box, then just inside its front edge.
      for (final (gap, crashes) in [(.002, false), (-.002, true)]) {
        final game = StageRunner(random: Random(1))..update(1e-4);
        game.obstacles.clear();
        final left = game.runnerWorldX + StageRunner.hitHalfWidth + gap;
        game.obstacles.add(
          Obstacle()
            ..kind = ObstacleKind.crate
            ..left = left
            ..width = .09
            ..top = StageRunner.floor - .09
            ..bottom = StageRunner.floor,
        );
        game.update(1e-4);
        expect(game.over, crashes, reason: 'gap $gap');
      }
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

  group('new obstacles', () {
    test('each joins once the score reaches its points, and shows at once', () {
      for (var seed = 0; seed < 4; seed++) {
        final game = StageRunner(random: Random(seed))..invincible = true;
        final firstSeen = <ObstacleKind, int>{};
        final debuts = <ObstacleKind>[];
        while (game.time < 200) {
          _greedyStep(game);
          for (final o in game.obstacles) {
            firstSeen.putIfAbsent(o.kind, () => game.score);
          }
          final debut = game.debut;
          if (debut != null && !debuts.contains(debut.kind)) {
            debuts.add(debut.kind);
            // The first one of its kind is the newest obstacle.
            expect(
              game.obstacles.where((o) => o.kind == debut.kind).length,
              anyOf(1, 2),
            );
          }
        }
        expect(game.score, greaterThan(1000), reason: 'seed $seed');
        expect(debuts, [for (final (_, kind) in StageRunner.debuts) kind]);
        for (final (points, kind) in StageRunner.debuts) {
          expect(
            firstSeen[kind],
            greaterThanOrEqualTo(points),
            reason: '$kind, seed $seed',
          );
        }
      }
    });

    test('the stage announces a new obstacle as it comes into view', () {
      final game = StageRunner(random: Random(4))..invincible = true;
      final fx = RunnerFx(random: Random(1));
      final banners = <String>[];
      while (game.time < 200) {
        _greedyStep(game);
        fx.update(1 / 60, game);
        final banner = fx.banner;
        if (banner != null && banner.startsWith('Neu: ')) {
          if (!banners.contains(banner)) {
            banners.add(banner);
            final debut = game.debut!;
            expect(game.score, greaterThanOrEqualTo(250));
            expect(debut.x - game.distance, lessThan(StageRunner.viewWidth));
          }
        }
      }
      expect(banners, [
        'Neu: Kabeltrommel!',
        'Neu: Kistenstapel!',
        'Neu: Lichttraverse!',
        'Neu: Prospekt!',
      ]);
    });

    test('a careful player gets past all of them', () {
      const hw = StageRunner.runnerWidth * .4;
      for (var seed = 0; seed < 8; seed++) {
        final game = StageRunner(random: Random(seed));
        final passed = <ObstacleKind, int>{};
        while (!game.over && game.time < 300) {
          final before = game.runnerWorldX;
          _pilotStep(game);
          final x = game.runnerWorldX;
          for (final o in game.obstacles) {
            if (o.right < x && o.right >= before) {
              passed.update(o.kind, (n) => n + 1, ifAbsent: () => 1);
            }
            // A drum has come to rest where it was placed before the
            // runner gets to it, so the space before it is as usual.
            if (o.kind == ObstacleKind.drum && o.left < x + hw) {
              expect(o.left, o.anchor, reason: 'seed $seed');
            }
          }
        }
        expect(game.meters, greaterThan(1200), reason: 'seed $seed');
        for (final (_, kind) in StageRunner.debuts) {
          expect(passed[kind], greaterThan(2), reason: '$kind, seed $seed');
        }
      }
    });

    test('a drop never moves faster than the runner and leaves a lane', () {
      const lowest = StageRunner.dropMiddle + StageRunner.dropSwing;
      const highest = StageRunner.dropMiddle - StageRunner.dropSwing;
      expect(
        StageRunner.floor - lowest,
        greaterThan(StageRunner.runnerHeight * 2.5),
      );
      expect(highest, greaterThan(StageRunner.ceiling + .15));
      final edgeSpeed = 2 * pi * StageRunner.dropSwing / StageRunner.dropPeriod;
      expect(edgeSpeed, lessThan(StageRunner.maxRise / 3));
      expect(edgeSpeed, lessThan(StageRunner.maxFall / 3));
      for (var t = 0.0; t < 5; t += .1) {
        final bottom = StageRunner.dropBottom(StageRunner.dropMiddle, 1, t);
        expect(bottom, inInclusiveRange(highest - 1e-9, lowest + 1e-9));
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
      final sound = _FakeSound();
      await _pump(
        tester,
        StageRunnerScreen(
          controller: controller,
          random: Random(3),
          onRun: (g) => game = g,
          sound: sound,
        ),
      );
      expect(find.text('Kim Beispiel'), findsOneWidget);
      expect(find.text('Du stehst noch nicht auf der Liste.'), findsOneWidget);

      expect(sound.prepared, isFalse);
      await tester.tap(find.text('Vorhang auf'));
      await tester.pump();
      expect(find.byKey(const ValueKey('runner-stage')), findsOneWidget);
      expect(find.text('0 m'), findsOneWidget);
      // Sound starts with the tap on "Vorhang auf", as browsers require.
      expect(sound.prepared, isTrue);
      expect(sound.music, isTrue);
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
      expect(submitted, {
        'roundId': 'r-1',
        'score': game.score,
        'meters': game.meters,
        'hitBy': game.hitBy!.name,
      });
      expect(find.text('Der Vorhang fällt!'), findsOneWidget);
      expect(find.text('Neuer persönlicher Bestwert!'), findsOneWidget);
      expect(find.text('Testmitglied'), findsOneWidget);
      expect(sound.played, containsAllInOrder([RunnerSfx.whoosh]));
      expect(
        sound.played.where(
          (s) => s == RunnerSfx.crash || s == RunnerSfx.curtain,
        ),
        [RunnerSfx.crash, RunnerSfx.curtain],
      );
      expect(sound.played.last, RunnerSfx.record);
      expect(sound.music, isFalse);
      expect(find.text('Du stehst noch nicht auf der Liste.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the space bar flies, too', (tester) async {
      late StageRunner game;
      await _pump(
        tester,
        StageRunnerScreen(
          controller: await _demo(),
          onRun: (g) => game = g,
          sound: _FakeSound(),
        ),
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
        StageRunnerScreen(
          controller: controller,
          random: Random(3),
          sound: _FakeSound(),
        ),
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
      await _pump(
        tester,
        StageRunnerScreen(controller: await _demo(), sound: _FakeSound()),
      );
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
      await _pump(
        tester,
        StageRunnerScreen(controller: controller, sound: _FakeSound()),
      );
      expect(
        find.text(
          'Die Bestenliste ist auf diesem Server noch nicht verfügbar.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('header logo', () {
    Finder logo() => find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(BrandLogo),
    );
    Matrix4 hop(WidgetTester tester) => tester
        .widget<Transform>(
          find
              .descendant(
                of: find.byType(SecretTap),
                matching: find.byType(Transform),
              )
              .first,
        )
        .transform;

    Future<void> taps(WidgetTester tester, int count, Duration pause) async {
      for (var i = 0; i < count; i++) {
        await tester.tap(logo());
        await tester.pump();
        await tester.pump(pause);
      }
    }

    // A pushed route is offstage in its first frame.
    final game = find.byType(StageRunnerScreen, skipOffstage: false);

    testWidgets('five quick taps open the game after a short sparkle', (
      tester,
    ) async {
      setWidth(tester, 400);
      final c = await pumpDemo(tester);
      await taps(tester, 4, const Duration(milliseconds: 120));
      expect(find.byType(StageRunnerScreen), findsNothing);
      await tester.tap(logo());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      // The closing effect plays first, but not for long.
      expect(game, findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(game, findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Vorhang auf'), findsOneWidget);
      await finish(tester, c);
    });

    testWidgets('single and slow taps keep the logo as it was', (tester) async {
      setWidth(tester, 400);
      final c = await pumpDemo(tester);
      await tester.tap(logo());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // Each tap hops ...
      expect(hop(tester), isNot(Matrix4.identity()));
      await tester.pumpAndSettle();
      // ... and the logo comes back to rest.
      expect(hop(tester), Matrix4.identity());
      expect(find.byType(StageRunnerScreen), findsNothing);
      // A pause longer than the window starts the count again.
      await taps(tester, 5, const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(StageRunnerScreen), findsNothing);
      expect(hop(tester), Matrix4.identity());
      await finish(tester, c);
    });

    testWidgets('the animation does not hold up the navigation', (
      tester,
    ) async {
      setWidth(tester, 400);
      final c = await pumpDemo(tester);
      await tester.tap(logo());
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(find.text('Termine').last);
      await tester.pumpAndSettle();
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1);
      expect(find.byType(StageRunnerScreen), findsNothing);
      await finish(tester, c);
    });

    testWidgets('with reduced motion the logo stays still and still opens', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      setWidth(tester, 400);
      final c = await pumpDemo(tester);
      await tester.tap(logo());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(hop(tester), Matrix4.identity());
      await taps(tester, 3, const Duration(milliseconds: 60));
      await tester.tap(logo());
      await tester.pump();
      // No closing effect: the game opens at once.
      expect(game, findsOneWidget);
      await tester.pumpAndSettle();
      await finish(tester, c);
    });

    testWidgets('the header logo is not announced as a button', (tester) async {
      setWidth(tester, 400);
      final c = await pumpDemo(tester);
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.bySemanticsLabel('Kolpingtheater Ramsen'),
          ),
        ),
        isNot(matchesSemantics(isButton: true, hasTapAction: true)),
      );
      semantics.dispose();
      await finish(tester, c);
    });

    testWidgets('on wide screens the rail logo of a page opens it, too', (
      tester,
    ) async {
      setWidth(tester, 1200);
      final c = await pumpDemo(tester);
      openPage<void>(
        tester.element(find.byType(AppShell)),
        const Scaffold(body: Text('Eine Seite')),
      );
      await tester.pumpAndSettle();
      final rail = find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byType(BrandLogo),
      );
      expect(rail, findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await tester.tap(rail);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpAndSettle();
      expect(find.byType(StageRunnerScreen), findsOneWidget);
      await finish(tester, c);
    });
  });

  group('sound', () {
    testWidgets('the switch mutes the run and is remembered', (tester) async {
      final sound = _FakeSound();
      await _pump(
        tester,
        StageRunnerScreen(controller: await _demo(), sound: sound),
      );
      await tester.tap(find.text('Vorhang auf'));
      await tester.pump();
      expect(sound.music, isTrue);
      expect(find.byTooltip('Ton aus'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('runner-sound')));
      await tester.pump();
      expect(sound.enabled.value, isFalse);
      expect(sound.music, isFalse);
      expect(find.byTooltip('Ton an'), findsOneWidget);
      await _runUntilOver(tester);
      expect(sound.played, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    test('the device remembers a muted game', () async {
      SharedPreferences.setMockInitialValues({});
      final first = PluginRunnerSound();
      await pumpEventQueue();
      expect(first.enabled.value, isTrue);
      first.setEnabled(false);
      await pumpEventQueue();
      first.dispose();
      final next = PluginRunnerSound();
      await pumpEventQueue();
      expect(next.enabled.value, isFalse);
      next.dispose();
    });

    test(
      'every effect has its own loaded player; a pickup only plays',
      () async {
        SharedPreferences.setMockInitialValues({});
        final log = <(_RecordingPlayer, String)>[];
        final players = <_RecordingPlayer>[];
        final sound = PluginRunnerSound(
          newPlayer: () {
            final player = _RecordingPlayer(log);
            players.add(player);
            return player;
          },
        );
        await pumpEventQueue();
        sound.prepare();
        sound.startMusic();
        await pumpEventQueue();
        expect(players, hasLength(RunnerSfx.values.length + 1));
        // No player polls its position once per frame.
        for (final p in players) {
          expect(
            log.where((e) => e.$1 == p && e.$2.startsWith('positionUpdater')),
            [(p, 'positionUpdater=null')],
          );
        }
        final bySfx = {
          for (final sfx in RunnerSfx.values)
            sfx: players.singleWhere((p) => p.asset == sfx.asset),
        };
        for (final sfx in RunnerSfx.values) {
          expect(
            log.where(
              (e) => e.$1 == bySfx[sfx] && e.$2.startsWith('setSource'),
            ),
            [(bySfx[sfx], 'setSource ${sfx.asset}')],
          );
          expect(log, contains((bySfx[sfx], 'setVolume ${sfx.volume}')));
        }

        for (final p in players) {
          p.state = PlayerState.completed;
        }
        log.clear();
        const series = [
          RunnerSfx.rose,
          RunnerSfx.mask,
          RunnerSfx.star,
          RunnerSfx.rose,
          RunnerSfx.bravo,
          RunnerSfx.record,
        ];
        for (final sfx in series) {
          sound.play(sfx);
          await pumpEventQueue();
          // The effect has sounded out before the next pickup.
          bySfx[sfx]!.state = PlayerState.completed;
        }
        expect(log, [for (final sfx in series) (bySfx[sfx], 'resume')]);

        // An effect that still sounds starts over.
        log.clear();
        bySfx[RunnerSfx.rose]!.state = PlayerState.playing;
        sound.play(RunnerSfx.rose);
        await pumpEventQueue();
        expect(log, [
          (bySfx[RunnerSfx.rose], 'stop'),
          (bySfx[RunnerSfx.rose], 'resume'),
        ]);
        sound.dispose();
      },
    );

    test('on iOS an effect is stopped before it ends by itself', () async {
      // audioplayers_darwin runs a synchronous AVAudioSession.setActive on
      // the main (= UI) thread whenever an effect plays to its end.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final log = <(_RecordingPlayer, String)>[];
      final players = <_RecordingPlayer>[];
      final sound = PluginRunnerSound(
        newPlayer: () {
          final player = _RecordingPlayer(log)
            ..length =
                PluginRunnerSound.earlyEnd + const Duration(milliseconds: 40);
          players.add(player);
          return player;
        },
      );
      await pumpEventQueue();
      sound.prepare();
      await pumpEventQueue();
      final rose = players.singleWhere((p) => p.asset == RunnerSfx.rose.asset);
      expect(log, contains((rose, 'getDuration')));

      log.clear();
      sound.play(RunnerSfx.rose);
      await pumpEventQueue();
      expect(log, [(rose, 'resume')]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(log, [(rose, 'resume'), (rose, 'stop')]);
      expect(rose.state, PlayerState.stopped);

      // A new play before the end restarts the effect and moves its end; the
      // end of the first play does not cut the second.
      log.clear();
      sound.play(RunnerSfx.rose);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      sound.play(RunnerSfx.rose);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(log, [(rose, 'resume'), (rose, 'stop'), (rose, 'resume')]);
      expect(rose.state, PlayerState.playing);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(log, [
        (rose, 'resume'),
        (rose, 'stop'),
        (rose, 'resume'),
        (rose, 'stop'),
      ]);

      // An effect that has already ended is not stopped again.
      log.clear();
      sound.play(RunnerSfx.star);
      await pumpEventQueue();
      final star = players.singleWhere((p) => p.asset == RunnerSfx.star.asset);
      star.state = PlayerState.completed;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(log, [(star, 'resume')]);
      sound.dispose();
    });

    test('outside browsers the plugin plays', () {
      SharedPreferences.setMockInitialValues({});
      final sound = RunnerSound();
      expect(sound, isA<PluginRunnerSound>());
      sound.dispose();
    });

    test('in browsers one audio context decodes every sound once; a pickup '
        'only starts it', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final audio = _FakeWebAudio(await _soundAssets());
      var opened = 0;
      final sound = WebRunnerSound(
        open: () {
          opened++;
          return audio;
        },
      );
      await pumpEventQueue();
      expect(opened, 0);

      // Within the tap: Safari only starts audio in a user gesture.
      sound
        ..prepare()
        ..startMusic();
      expect(audio.log, ['resume']);
      await _decoded(audio, RunnerSfx.values.length + 1);
      expect(audio.clips, {
        for (final sfx in RunnerSfx.values) '${sfx.name}.mp3': sfx.volume,
        'music.mp3': .32,
      });
      // The tune starts once it is decoded.
      expect(audio.log, ['resume', 'play music.mp3#1 loop']);

      audio.log.clear();
      sound
        ..prepare()
        ..play(RunnerSfx.rose)
        ..play(RunnerSfx.mask)
        ..play(RunnerSfx.rose);
      expect(opened, 1);
      expect(audio.log, [
        'resume',
        'play rose.mp3#2',
        'play mask.mp3#3',
        // Still sounding or not, a new play starts the effect over.
        'stop rose.mp3#2',
        'play rose.mp3#4',
      ]);

      // Muted, the music waits where it is and effects are cut.
      audio.log.clear();
      sound.setEnabled(false);
      sound.play(RunnerSfx.star);
      expect(audio.log, ['stop mask.mp3#3', 'stop rose.mp3#4', 'suspend']);
      audio.log.clear();
      sound.setEnabled(true);
      expect(audio.log, ['resume']);

      audio.log.clear();
      sound
        ..stopMusic()
        ..dispose();
      expect(audio.log, ['stop music.mp3#1', 'close']);
      expect(opened, 1);
    });

    test('in browsers every failure only means silence', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final missing = WebRunnerSound(
        open: () => throw UnsupportedError('no Web Audio'),
      );
      missing
        ..prepare()
        ..startMusic()
        ..play(RunnerSfx.rose)
        ..setEnabled(false)
        ..setEnabled(true)
        ..stopMusic()
        ..dispose();

      final audio = _FakeWebAudio(await _soundAssets())
        ..broken.add('rose.mp3');
      final sound = WebRunnerSound(open: () => audio)..prepare();
      await _decoded(audio, RunnerSfx.values.length);
      audio.log.clear();
      sound
        ..play(RunnerSfx.rose)
        ..play(RunnerSfx.star);
      expect(audio.log, [startsWith('play star.mp3')]);
      sound.dispose();
    });
  });

  group('art', () {
    test('the poses of the run follow each other in a cycle', () {
      final poses = [
        for (var i = 0; i < 8; i++) RunnerSprite.stride((i + .5) / 18),
      ];
      expect(poses, [...RunnerSprite.strides, ...RunnerSprite.strides]);
      expect(RunnerSprite.strides, [
        RunnerSprite.runA,
        RunnerSprite.passA,
        RunnerSprite.runB,
        RunnerSprite.passB,
      ]);
    });

    testWidgets('the poses share the body and swap the legs', (tester) async {
      final atlas = await tester.runAsync(() async {
        final data = await rootBundle.load(
          'assets/games/stage_runner/atlas.webp',
        );
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final image = (await codec.getNextFrame()).image;
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        return (image.width, image.height, bytes!);
      });
      final (width, height, bytes) = atlas!;

      // Every picture lies inside the atlas and none overlaps another.
      for (final sprite in RunnerSprite.values) {
        expect(
          Rect.fromLTWH(
            0,
            0,
            width.toDouble(),
            height.toDouble(),
          ).intersect(sprite.rect),
          sprite.rect,
          reason: '$sprite',
        );
        for (final other in RunnerSprite.values) {
          if (other.index <= sprite.index) continue;
          final overlap = sprite.rect.intersect(other.rect);
          expect(
            overlap.width <= 0 || overlap.height <= 0,
            isTrue,
            reason: '$sprite and $other overlap',
          );
        }
      }

      final a = RunnerSprite.runA;
      int at(RunnerSprite s, int x, int y) =>
          ((s.y.toInt() + y) * width + s.x.toInt() + x) * 4;
      // Mean difference per channel from [a] in the rows from [from] to [to].
      double difference(RunnerSprite b, double from, double to) {
        var sum = 0, count = 0;
        for (var y = (a.height * from).floor(); y < a.height * to; y++) {
          for (var x = 0; x < a.width; x++) {
            final i = at(a, x, y), j = at(b, x, y);
            for (var c = 0; c < 4; c++) {
              sum += (bytes.getUint8(i + c) - bytes.getUint8(j + c)).abs();
            }
            count += 4;
          }
        }
        return sum / count;
      }

      // Mean x of the shoe pixels in the lower half: the near shoe is bright
      // red, the far one in the shade.
      (double, double) shoes(RunnerSprite s) {
        var brightX = 0, bright = 0, darkX = 0, dark = 0;
        for (var y = s.height ~/ 2 + 16; y < s.height; y++) {
          for (var x = 0; x < s.width; x++) {
            final i = at(s, x, y);
            final r = bytes.getUint8(i), g = bytes.getUint8(i + 1);
            final b = bytes.getUint8(i + 2), alpha = bytes.getUint8(i + 3);
            if (alpha < 200 || g > 90 || b > 90) continue;
            if (r > 150) {
              brightX += x;
              bright++;
            } else if (r > 60 && r < 135 && g < 45 && b < 60 && r - g > 45) {
              darkX += x;
              dark++;
            }
          }
        }
        return (brightX / bright, darkX / dark);
      }

      // Mean position of the golden halo at the top of a pose.
      (double, double) halo(RunnerSprite s) {
        var sumX = 0, sumY = 0, count = 0;
        for (var y = 0; y < 30; y++) {
          for (var x = 0; x < s.width; x++) {
            final i = at(s, x, y);
            final r = bytes.getUint8(i), g = bytes.getUint8(i + 1);
            final b = bytes.getUint8(i + 2), alpha = bytes.getUint8(i + 3);
            if (alpha > 200 && r > 180 && g > 130 && b < 90) {
              sumX += x;
              sumY += y;
              count++;
            }
          }
        }
        expect(count, greaterThan(50), reason: '$s has a halo');
        return (sumX / count, sumY / count);
      }

      final (haloX, haloY) = halo(a);
      for (final pose in RunnerSprite.strides) {
        // Same size and the head in the same place, so the runner does not
        // jump.
        expect((pose.width, pose.height), (a.width, a.height));
        final (x, y) = halo(pose);
        expect((x - haloX).abs(), lessThan(3), reason: '$pose');
        expect((y - haloY).abs(), lessThan(4), reason: '$pose');
      }
      expect(difference(RunnerSprite.runB, 2 / 3, 1), greaterThan(8));
      // The near shoe is in front in runA and behind in runB, the far shoe
      // the other way round.
      final (nearA, farA) = shoes(RunnerSprite.runA);
      final (nearB, farB) = shoes(RunnerSprite.runB);
      expect(nearA, greaterThan(farA + 30));
      expect(farB, greaterThan(nearB + 30));
      expect(nearA, greaterThan(nearB + 50));
      expect(farB, greaterThan(farA + 15));

      // The wire meets the harness at the top of its ring, on the body.
      for (final pose in [
        ...RunnerSprite.strides,
        RunnerSprite.fly,
        RunnerSprite.dangle,
        RunnerSprite.cheer,
      ]) {
        final h = pose.harness;
        var opaque = 0;
        for (var y = h.dy.round() - 3; y <= h.dy.round() + 3; y++) {
          for (var x = h.dx.round() - 3; x <= h.dx.round() + 3; x++) {
            if (bytes.getUint8(at(pose, x, y) + 3) > 128) opaque++;
          }
        }
        expect(opaque, greaterThan(15), reason: '$pose');
      }

      // The hitbox, where the stage draws it on each pose: it lies on the
      // body, and wings, arms, head and shoes stick out of it, so grazing
      // them is no crash.
      const px = RunnerSprite.stagePerPixel;
      const hw = StageRunner.hitHalfWidth / px;
      const hh = StageRunner.hitHalfHeight / px;
      for (final pose in RunnerSprite.strides) {
        // The stage puts the soles .006 below the bottom of the runner.
        final cy = pose.height - (StageRunner.runnerHeight / 2 + .006) / px;
        final cx = pose.width / 2;
        var opaque = 0, count = 0;
        for (var y = (cy - hh).round(); y < cy + hh; y++) {
          for (var x = (cx - hw).round(); x < cx + hw; x++) {
            if (bytes.getUint8(at(pose, x, y) + 3) > 128) opaque++;
            count++;
          }
        }
        expect(opaque / count, greaterThan(.65), reason: '$pose');
        expect(2 * hw, lessThan(pose.width * .4), reason: '$pose');
        expect(cy - hh, greaterThan(haloY + 30), reason: '$pose');
        expect(cy + hh, lessThan(pose.height - 15), reason: '$pose');
      }
    });
  });

  group('effects', () {
    test('texts of different sizes share a frame without new layouts', () {
      final g = RunnerGlyphs()..stage(400);
      final popup = g.label('+5', 18, shadow: true);
      final banner = g.label('Kombo ×5 – Bravo!', 22);
      final kg = g.kg(36);
      final icon = g.icon(PickupKind.rose, 30);
      expect(identical(g.label('+5', 18, shadow: true), popup), isTrue);
      expect(identical(g.label('Kombo ×5 – Bravo!', 22), banner), isTrue);
      expect(identical(g.kg(36), kg), isTrue);
      expect(identical(g.icon(PickupKind.rose, 30), icon), isTrue);
      expect(identical(g.label('+5', 18), popup), isFalse);
      expect(g.label('+5', 24).height, greaterThan(popup.height));
      g.stage(400);
      expect(identical(g.label('+5', 18, shadow: true), popup), isTrue);
      // A new stage size (rotation) lays everything out again.
      g.stage(500);
      expect(identical(g.label('+5', 18, shadow: true), popup), isFalse);
    });

    test('pickups sparkle and sound by kind; the score stays the same', () {
      final played = <RunnerSfx>[];
      final game = StageRunner(random: Random(5))..invincible = true;
      final fx = RunnerFx(random: Random(1), onSound: played.add);
      var taken = 0;
      game.onPickup = (kind, x, y) {
        taken += kind.points;
        fx.pickup(kind, x - game.distance, y);
      };
      for (var i = 0; i < 60 * 30; i++) {
        _greedyStep(game);
        fx.update(1 / 60, game);
      }
      expect(taken, game.pickupPoints);
      expect(game.score, game.meters + game.pickupPoints);
      expect(played, contains(RunnerSfx.rose));
      expect(played, contains(RunnerSfx.bravo));
      expect(fx.popups.any((p) => p.text.startsWith('+')), isTrue);
    });

    test('milestones at 100, 500 and 1000 m, then every thousand', () {
      expect(
        [for (var i = 0; i < 5; i++) RunnerFx.milestoneAt(i)],
        [100, 500, 1000, 2000, 3000],
      );
      expect(RunnerFx.milestoneText(1000), '1000 m – Zugabe!');
      final game = StageRunner(random: Random(2))..invincible = true;
      final fx = RunnerFx();
      while (game.meters < 100) {
        game.update(1 / 60);
        fx.update(1 / 60, game);
      }
      expect(fx.banner, '100 m – Applaus!');
      expect(fx.showsBanner, isTrue);
    });

    test('a broken record gets a fanfare once', () {
      final played = <RunnerSfx>[];
      final game = StageRunner(random: Random(2))..invincible = true;
      final fx = RunnerFx(best: 20, onSound: played.add);
      for (var i = 0; i < 60 * 10; i++) {
        game.update(1 / 60);
        fx.update(1 / 60, game);
      }
      expect(fx.recordBroken, isTrue);
      expect(played.where((s) => s == RunnerSfx.record), hasLength(1));
    });

    test('the crash shakes briefly, then the curtain sounds', () {
      final played = <RunnerSfx>[];
      final game = StageRunner(random: Random(4));
      final fx = RunnerFx(onSound: played.add);
      while (!game.over) {
        game.update(1 / 60);
        fx.update(1 / 60, game);
      }
      expect(game.hitBy, isNotNull);
      game.update(1 / 60);
      fx.update(1 / 60, game);
      expect(fx.shake(game), isNot((0.0, 0.0)));
      for (var i = 0; i < 60; i++) {
        game.update(1 / 60);
        fx.update(1 / 60, game);
      }
      expect(fx.shake(game), (0.0, 0.0));
      expect(played.where((s) => s == RunnerSfx.crash), hasLength(1));
      expect(played.where((s) => s == RunnerSfx.curtain), hasLength(1));
    });

    test('the curtain line changes and sometimes names the obstacle', () {
      final random = Random(9);
      final lines = {
        for (var i = 0; i < 80; i++) curtainLine(ObstacleKind.sandbag, random),
      };
      expect(lines.length, greaterThan(5));
      expect(lines, contains('Der Sandsack hatte Vorfahrt.'));
      expect(lines, contains('Text vergessen!'));
      for (final kind in ObstacleKind.values) {
        expect(obstacleName(kind), isNotEmpty);
        expect(
          {for (var i = 0; i < 60; i++) curtainLine(kind, random)}.length,
          greaterThan(3),
        );
      }
    });
  });

  // Layers that drift at their own pace made players feel sick: the whole
  // stage moves as one, exactly at the running pace.
  group('motion', () {
    testWidgets('the whole stage keeps the running pace', (tester) async {
      late StageRunner game;
      await _pump(
        tester,
        StageRunnerScreen(
          controller: await _demo(),
          onRun: (g) => game = g,
          sound: _FakeSound(),
        ),
      );
      // The screen decodes the pictures in real time.
      for (var i = 0; i < 100 && RunnerArt.loaded == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(Durations.short1));
        await tester.pump();
      }
      expect(RunnerArt.loaded, isNotNull);
      await tester.tap(find.text('Vorhang auf'));
      await tester.pump();
      final painter = tester
          .widget<CustomPaint>(find.byKey(const ValueKey('runner-stage')))
          .painter!;

      const s = 400, w = 640;
      Future<Uint8List> shot(double distance, double time) async {
        game
          ..distance = distance
          ..time = time;
        final bytes = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          painter.paint(Canvas(recorder), const Size(640, 400));
          final image = await recorder.endRecording().toImage(w, s);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!.buffer.asUint8List();
        });
        return bytes!;
      }

      // Mean difference per channel between [b] and [a] moved left by
      // [shift] pixels, in the rows from [top] to [bottom] (stage heights),
      // left and right of the runner and its rope in both (no course is in
      // view).
      double difference(
        Uint8List a,
        Uint8List b,
        int shift,
        double top,
        double bottom,
      ) {
        var sum = 0, count = 0;
        for (var y = (top * s).ceil(); y < bottom * s; y++) {
          for (var x = 60; x < 560; x++) {
            if (x + shift > .3 * s && x < .6 * s) continue;
            for (var c = 0; c < 3; c++) {
              sum += (b[(y * w + x) * 4 + c] - a[(y * w + x + shift) * 4 + c])
                  .abs();
              count++;
            }
          }
        }
        return sum / count;
      }

      // The shift in pixels that best lines up [b] with [a].
      int shift(Uint8List a, Uint8List b, double top, double bottom) {
        var best = 0;
        var least = double.infinity;
        for (var i = 0; i <= 60; i++) {
          final d = difference(a, b, i, top, bottom);
          if (d < least) (best, least) = (i, d);
        }
        return best;
      }

      // Backdrop, wings and lights between the valance and the floor; the
      // floor with the front row below it.
      const set = (.08, StageRunner.floor - .01);
      const floor = (StageRunner.floor + .01, 1.0);

      // 0.1 stage heights of running are exactly 40 pixels, at the start and
      // far into a run (the backdrop is tiled without end).
      for (final start in [.02, 1000.02]) {
        final a = await shot(start, .5), b = await shot(start + .1, .5);
        expect(shift(a, b, set.$1, set.$2), 40, reason: 'set at $start');
        expect(shift(a, b, floor.$1, floor.$2), 40, reason: 'floor at $start');
        expect(difference(a, b, 40, set.$1, set.$2), lessThan(.5));
        expect(difference(a, b, 40, floor.$1, floor.$2), lessThan(1));
        expect(difference(a, b, 0, set.$1, set.$2), greaterThan(5));
      }

      // Lights don't sway: at the same place the stage looks the same later.
      final now = await shot(.12, .5), later = await shot(.12, 1.7);
      expect(difference(now, later, 0, set.$1, set.$2), 0);
      // The stage moves in whole pixels: less than half a pixel of running
      // leaves it where it is, so the pictures don't shimmer.
      final nudged = await shot(.12 + .4 / s, 1.7);
      expect(difference(later, nudged, 0, set.$1, set.$2), 0);
      expect(difference(later, nudged, 0, floor.$1, floor.$2), 0);
    });

    test('the crash only nudges the stage, briefly', () {
      final game = StageRunner(random: Random(4));
      final fx = RunnerFx();
      while (!game.over) {
        game.update(1 / 60);
      }
      var largest = 0.0;
      for (var i = 0; i < 60; i++) {
        game.update(1 / 60);
        final (dx, dy) = fx.shake(game);
        largest = max(largest, max(dx.abs(), dy.abs()));
        if (game.sinceOver > RunnerFx.shakeTime) expect((dx, dy), (0.0, 0.0));
      }
      expect(largest, greaterThan(0));
      expect(largest, lessThanOrEqualTo(.01));
    });
  });
}
