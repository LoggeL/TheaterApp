import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/platform/pwa_install.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/core/telemetry/perf_telemetry.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/changelog/changelog.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_fx.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart'
    show RunnerTrail;
import 'package:theater_app/features/games/ui/stage_runner_screen.dart'
    show RunnerGlyphs, stageLayout, stagePainterFor;
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

/// A [_FakeSound] that also plays the backdrop's music and counts warm-ups.
class _WarmSound extends _FakeSound implements RunnerMusic {
  int warmed = 0;
  @override
  void warmUp() => warmed++;
  @override
  void useTune(Uint8List? tune) {}
  @override
  void pauseMusic() {}
  @override
  void resumeMusic() {}
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
  @override
  Future<void> setAudioContext(AudioContext ctx) async =>
      _log('setAudioContext');

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
  WebAudioVoice play({bool loop = false, Duration fadeIn = Duration.zero}) {
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
  void stop({Duration fadeOut = Duration.zero}) => audio.log.add('stop $name');
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

/// Receives the performance telemetry's reports.
class _PerfUplink implements PerfUplink {
  final sent = <Map<String, Object?>>[];
  @override
  bool get isDemo => false;
  @override
  bool get hasAccess => true;
  @override
  bool get featuresKnown => true;
  @override
  bool supports(String feature) => true;
  @override
  Future<void> send(Map<String, Object?> report) async => sent.add(report);
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

    test('the quickest crash leaves the spam guard out of reach', () {
      // The server takes 20 starts in 10 s (`stageRunner.startBurst` in
      // server/src/theater.mjs). The first obstacle stands far enough
      // ahead that no run, held or not, ends before 2.5 s; with the 1 s
      // curtain and the tap on "Nochmal" that is at most 3 starts in 10 s.
      var quickest = double.infinity;
      for (var seed = 0; seed < 40; seed++) {
        for (final holding in [false, true]) {
          final game = StageRunner(random: Random(seed))..holding = holding;
          while (!game.over && game.time < 30) {
            game.update(1 / 120);
          }
          quickest = min(quickest, game.time);
        }
      }
      expect(quickest, greaterThan(2.5));
      expect(10 / (quickest + 1), lessThan(20));
    });

    test('it gets harder until reacting is impossible', () {
      expect(StageRunner.reactionTime(0), 1.2);
      expect(
        StageRunner.reactionTime(1000),
        lessThan(StageRunner.reactionTime(500)),
      );
      expect(StageRunner.reactionTime(3000), .3);
      expect(StageRunner.gapHeight(0), greaterThan(.4));
      expect(StageRunner.gapHeight(5000), .32);
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

    test('the stage shows no banner for a new obstacle', () {
      final game = StageRunner(random: Random(4))..invincible = true;
      final fx = RunnerFx(random: Random(1));
      final debuts = <ObstacleKind>{};
      while (game.time < 200) {
        _greedyStep(game);
        fx.update(1 / 60, game);
        if (game.debut case final debut?) debuts.add(debut.kind);
        expect(fx.banner ?? '', isNot(startsWith('Neu: ')));
      }
      expect(debuts, hasLength(StageRunner.debuts.length));
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
        // For the Tagesmissionen; servers without them ignore it.
        'missionStats': game.missionStats,
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
              'error': 'Das waren gerade sehr viele Starts auf einmal.',
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
        find.textContaining('Nicht in der Bestenliste: Das waren gerade'),
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

    testWidgets('a run reports its frame times to the telemetry', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final uplink = _PerfUplink();
      PerfTelemetry.instance.startForTest(uplink: uplink);
      addTearDown(PerfTelemetry.instance.stopForTest);
      StageRunner? game;
      await _pump(
        tester,
        StageRunnerScreen(
          controller: await _demo(),
          sound: _FakeSound(),
          onRun: (g) => game = g,
        ),
      );
      await tester.tap(find.text('Vorhang auf'));
      await _runUntilOver(tester);
      await PerfTelemetry.instance.flush();
      final report = uplink.sent.singleWhere((r) => r['kind'] == 'stageRunner');
      final run = report['run']! as Map;
      expect(run['m'], game!.meters);
      expect(run['score'], game!.score);
      expect(run['end'], 'crash');
      expect(run['ms'], closeTo(game!.time * 1000, 1));
      expect(run.containsKey('character'), isFalse, reason: 'default costume');
      final frames = report['frames']! as Map;
      // The test pumps every 50 ms: each step is a (small) jank.
      expect(frames['n'], greaterThan(10));
      expect(frames['p50'], closeTo(50, 1));
      expect(frames['j25'], frames['n']);
      final worst = (report['worst']! as List).cast<Map>();
      expect(worst, hasLength(5));
      expect(worst.first['m'], isA<int>());
      final events = worst.expand((w) => '${w['ev'] ?? ''}'.split(',')).toSet();
      expect(events, contains('sound'), reason: 'the music starts the run');
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

    testWidgets('on wide screens a run paints nothing over the rail', (
      tester,
    ) async {
      // The stage fills its page to the edges, and its set is drawn beyond
      // them; the rail of the desktop layout lies right next to it.
      setWidth(tester, 1200);
      final c = await pumpDemo(tester);
      openPage<void>(
        tester.element(find.byType(AppShell)),
        StageRunnerScreen(
          controller: c,
          random: Random(3),
          onRun: (g) => g.invincible = true,
          sound: _FakeSound(),
        ),
      );
      await tester.pumpAndSettle();
      final rail = tester.getRect(find.byType(NavigationRail));
      final page = tester.getRect(find.byType(StageRunnerScreen));
      expect(rail.right, lessThanOrEqualTo(page.left));
      // The rail and the divider beside it, as the screen shows them.
      Future<List<int>> left() async => (await tester.runAsync(() async {
        final layer = tester.binding.renderViews.first.debugLayer!;
        final image = await (layer as OffsetLayer).toImage(
          Rect.fromLTRB(0, 0, page.left, page.bottom),
        );
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List().toList();
      }))!;
      final before = await left();
      await tester.scrollUntilVisible(find.text('Vorhang auf'), 200);
      await tester.tap(find.text('Vorhang auf'));
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byKey(const ValueKey('runner-stage')), findsOneWidget);
      final during = await left();
      expect(during.length, before.length);
      var changed = 0;
      for (var i = 0; i < before.length; i++) {
        if (before[i] != during[i]) changed++;
      }
      expect(changed, 0, reason: 'pixels of the rail changed by the stage');
      await finish(tester, c);
    });

    testWidgets('new numbers repaint the numbers, not the page', (
      tester,
    ) async {
      await _pump(
        tester,
        StageRunnerScreen(
          controller: await _demo(),
          random: Random(3),
          onRun: (g) => g.invincible = true,
          sound: _FakeSound(),
        ),
      );
      await tester.tap(find.text('Vorhang auf'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final painted = <RenderObject>[];
      debugProfilePaintsEnabled = true;
      debugOnProfilePaint = painted.add;
      try {
        final metres = find.textContaining(' m').evaluate().single;
        final before = (metres.widget as Text).data;
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          (find.textContaining(' m').evaluate().single.widget as Text).data,
          isNot(before),
        );
      } finally {
        debugProfilePaintsEnabled = false;
        debugOnProfilePaint = null;
      }
      bool paints(Finder finder) =>
          painted.contains(tester.renderObject(finder));

      // The picture of the stage every frame, the numbers when they change;
      // the app bar's title and the hint keep their pictures.
      expect(paints(find.byKey(const ValueKey('runner-stage'))), isTrue);
      expect(paints(find.textContaining(' m')), isTrue);
      expect(paints(find.text('Halten zum Steigen')), isFalse);
      expect(
        paints(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Bühnenlauf'),
          ),
        ),
        isFalse,
      );
      // No blurred shadows over the stage: Impeller would blur them anew
      // whenever their picture is redrawn.
      for (final text in tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('runner-hud')),
          matching: find.byType(Text),
        ),
      )) {
        for (final s in text.style?.shadows ?? const <Shadow>[]) {
          expect(s.blurRadius, 0);
        }
      }
      await tester.pumpWidget(const SizedBox());
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
        // The music fades in meanwhile, on a timer of its own.
        final music = players.singleWhere((p) => !bySfx.containsValue(p));
        Iterable<(_RecordingPlayer, String)> effects() =>
            log.where((e) => e.$1 != music);
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
        expect(effects(), [for (final sfx in series) (bySfx[sfx], 'resume')]);

        // An effect that still sounds starts over.
        log.clear();
        bySfx[RunnerSfx.rose]!.state = PlayerState.playing;
        sound.play(RunnerSfx.rose);
        await pumpEventQueue();
        expect(effects(), [
          (bySfx[RunnerSfx.rose], 'stop'),
          (bySfx[RunnerSfx.rose], 'resume'),
        ]);
        sound.dispose();
      },
    );

    test('outside browsers effects and music are loaded before the run, '
        'so its start only plays', () async {
      SharedPreferences.setMockInitialValues({});
      final log = <(_RecordingPlayer, String)>[];
      final players = <_RecordingPlayer>[];
      final sound = PluginRunnerSound(
        newPlayer: () {
          final player = _RecordingPlayer(log);
          players.add(player);
          return player;
        },
        othersPlaying: () async => false,
      );
      await pumpEventQueue();
      sound.warmUp();
      await pumpEventQueue();
      // Every effect and the music are loaded, nothing sounds yet.
      expect(players, hasLength(RunnerSfx.values.length + 1));
      final loaded = {for (final p in players) p.asset};
      expect(loaded, {
        for (final sfx in RunnerSfx.values) sfx.asset,
        'games/stage_runner/music.mp3',
      });
      expect(log.where((e) => e.$2 == 'resume'), isEmpty);

      // "Vorhang auf": no player is made or loaded any more.
      log.clear();
      sound
        ..prepare()
        ..startMusic();
      await pumpEventQueue();
      expect(players, hasLength(RunnerSfx.values.length + 1));
      expect(
        log.where((e) => e.$2.startsWith('setSource') || e.$2 == 'create'),
        isEmpty,
      );
      expect(log.map((e) => e.$2), contains('resume'));

      // Muted, nothing is warmed up at all.
      final muted = PluginRunnerSound(
        newPlayer: () => fail('no player while muted'),
      );
      await pumpEventQueue();
      muted
        ..setEnabled(false)
        ..warmUp();
      await pumpEventQueue();
      sound.dispose();
      muted.dispose();
    });

    testWidgets('outside browsers the game warms its sound up on opening', (
      tester,
    ) async {
      final sound = _WarmSound();
      await _pump(
        tester,
        StageRunnerScreen(controller: await _demo(), sound: sound),
      );
      expect(sound.warmed, 1);
      // The tap still prepares, as browsers need it.
      expect(sound.prepared, isFalse);
      await tester.tap(find.text('Vorhang auf'));
      await tester.pump();
      expect(sound.prepared, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    // In fake time: the early ends are timers of 40 ms, and on the real
    // clock a busy test machine let the second end fire before the check.
    testWidgets(
      'on iOS an effect is stopped before it ends by itself',
      (tester) async {
        // audioplayers_darwin runs a synchronous AVAudioSession.setActive on
        // the main (= UI) thread whenever an effect plays to its end.
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
        await tester.pump();
        sound.prepare();
        await tester.pump();
        final rose = players.singleWhere(
          (p) => p.asset == RunnerSfx.rose.asset,
        );
        expect(log, contains((rose, 'getDuration')));

        log.clear();
        sound.play(RunnerSfx.rose);
        await tester.pump();
        expect(log, [(rose, 'resume')]);
        await tester.pump(const Duration(milliseconds: 80));
        expect(log, [(rose, 'resume'), (rose, 'stop')]);
        expect(rose.state, PlayerState.stopped);

        // A new play before the end restarts the effect and moves its end; the
        // end of the first play does not cut the second.
        log.clear();
        sound.play(RunnerSfx.rose);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 25));
        sound.play(RunnerSfx.rose);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 25));
        expect(log, [(rose, 'resume'), (rose, 'stop'), (rose, 'resume')]);
        expect(rose.state, PlayerState.playing);
        await tester.pump(const Duration(milliseconds: 60));
        expect(log, [
          (rose, 'resume'),
          (rose, 'stop'),
          (rose, 'resume'),
          (rose, 'stop'),
        ]);

        // An effect that has already ended is not stopped again.
        log.clear();
        sound.play(RunnerSfx.star);
        await tester.pump();
        final star = players.singleWhere(
          (p) => p.asset == RunnerSfx.star.asset,
        );
        star.state = PlayerState.completed;
        await tester.pump(const Duration(milliseconds: 80));
        expect(log, [(star, 'resume')]);
        sound.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

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

      final audio = _FakeWebAudio(await _soundAssets())..broken.add('rose.mp3');
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
      final themed = {
        for (var i = 0; i < 80; i++)
          curtainLine(
            ObstacleKind.sandbag,
            random,
            obstacleCrashLines: {
              ObstacleKind.sandbag: 'Der Kronleuchter hatte Vorfahrt.',
            },
          ),
      };
      expect(themed, contains('Der Kronleuchter hatte Vorfahrt.'));
      expect(themed, isNot(contains('Der Sandsack hatte Vorfahrt.')));
      expect(themed, contains('Text vergessen!'));
      for (final kind in ObstacleKind.values) {
        expect(obstacleName(kind), isNotEmpty);
        expect(
          {for (var i = 0; i < 60; i++) curtainLine(kind, random)}.length,
          greaterThan(3),
        );
      }
    });
  });

  // The whole stage passes as one, exactly at the running pace, like the
  // world in a side-scroller; nothing moves at its own pace (parallax made
  // players feel sick). It fills pictures of any shape.
  group('motion', () {
    // Decoded here, not with RunnerArt.load: an earlier test may have left
    // that waiting in its fake time.
    Future<RunnerArt> decodeArt(
      WidgetTester tester,
    ) async => (await tester.runAsync(() async {
      Future<ui.Image> decode(String name) async {
        final data = await rootBundle.load('assets/games/stage_runner/$name');
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        return (await codec.getNextFrame()).image;
      }

      return RunnerArt.test(
        await decode('atlas.webp'),
        await decode('backdrop.webp'),
      );
    }))!;

    Future<Uint8List> render(
      WidgetTester tester,
      StageRunner game,
      RunnerArt? art,
      int w,
      int h, {
      RunnerFx? fx,
      bool sceneryMotion = true,
    }) async => (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      stagePainterFor(
        game,
        art,
        fx: fx,
        sceneryMotion: sceneryMotion,
      ).paint(Canvas(recorder), Size(w.toDouble(), h.toDouble()));
      final image = await recorder.endRecording().toImage(w, h);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;

    testWidgets('the whole stage passes at running speed', (tester) async {
      final art = await decodeArt(tester);
      // A landscape picture and a tall one with drapes and stalls; the
      // stage height of the tall one is no whole number of pixels.
      for (final (w, h) in [(640, 400), (390, 844)]) {
        final (:s, :top, view: _) = stageLayout(
          Size(w.toDouble(), h.toDouble()),
        );
        final game = StageRunner(random: Random(1));
        Future<Uint8List> shot(double px, {double? crateAt}) {
          game
            ..distance = px / s
            ..time = .5
            ..obstacles.clear()
            ..pickups.clear();
          if (crateAt != null) {
            game.obstacles.add(
              Obstacle()
                ..left = crateAt
                ..width = .1
                ..top = StageRunner.floor - .1
                ..bottom = StageRunner.floor,
            );
          }
          return render(tester, game, art, w, h);
        }

        // Rows from [from] to [to] (stage heights, may lie outside the
        // playing field): the pixels of [b] that differ from those of [a]
        // [shift] pixels to their right. The runner and its rope are left
        // out, in both places, and so are the outermost pixels, where round
        // shapes cut by the picture's edge are smoothed a little
        // differently. Elsewhere, smoothed edges may differ by a few shades.
        int moved(Uint8List a, Uint8List b, int shift, double from, double to) {
          var n = 0;
          final runner = (.3 * s, .6 * s);
          bool near(int x) => x > runner.$1 && x < runner.$2;
          final y0 = max(0, (top + from * s).ceil());
          final y1 = min(h, top + to * s);
          for (var y = y0; y < y1; y++) {
            for (var x = 3; x + shift < w - 3; x++) {
              if (near(x) || near(x + shift)) continue;
              final i = (y * w + x) * 4, j = (y * w + x + shift) * 4;
              if ((b[i] - a[j]).abs() > 6 ||
                  (b[i + 1] - a[j + 1]).abs() > 6 ||
                  (b[i + 2] - a[j + 2]).abs() > 6) {
                n++;
              }
            }
          }
          return n;
        }

        final bands = {
          // The gold hem and the scalloped edge.
          'valance': (.03, .079),
          'backdrop': (.08, StageRunner.floor - .01),
          'floor': (StageRunner.floor + .01, .95),
          'front row': (.95, 1.0),
          if (top > 0) 'drapes': (-top / s, -.02),
          if (top > 0) 'stalls': (1.0, (h - top) / s),
        };
        // At the start and far into a run: 40 pixels of running move every
        // layer by exactly 40 pixels, the crate on the floor as well.
        for (final start in [8, 400008]) {
          final crate = (start + 160) / s;
          final a = await shot(start.toDouble(), crateAt: crate);
          final b = await shot(start + 40.0, crateAt: crate);
          for (final MapEntry(key: name, value: (from, to)) in bands.entries) {
            final at = '$name of ${w}x$h at $start';
            expect(moved(a, b, 0, from, to), greaterThan(0), reason: at);
            expect(moved(a, b, 40, from, to), 0, reason: at);
          }
          // Less than half a pixel of running leaves the stage where it is.
          final c = await shot(start + .4, crateAt: crate);
          expect(moved(a, c, 0, -top / s, (h - top) / s), 0);
        }
      }
    });

    testWidgets('calm scenery stays fixed as the run advances', (tester) async {
      final loaded = await decodeArt(tester);
      for (final art in [loaded, null]) {
        for (final (w, h) in [(640, 400), (390, 844)]) {
          final s = stageLayout(Size(w.toDouble(), h.toDouble())).s;
          bool sameScenery(Uint8List a, Uint8List b) {
            for (var y = 0; y < h; y++) {
              for (var x = 0; x < w; x++) {
                // The runner's stride deliberately follows distance in
                // both renderers; leave the figure and its wire out.
                if (x > s * .2 && x < s * .7) continue;
                final i = (y * w + x) * 4;
                if (a[i] != b[i] ||
                    a[i + 1] != b[i + 1] ||
                    a[i + 2] != b[i + 2] ||
                    a[i + 3] != b[i + 3]) {
                  return false;
                }
              }
            }
            return true;
          }

          final game = StageRunner(random: Random(1))
            ..time = .5
            ..obstacles.clear()
            ..pickups.clear();
          final start = await render(
            tester,
            game,
            art,
            w,
            h,
            sceneryMotion: false,
          );
          for (final distance in [.13, 1.7, 1000.02]) {
            game.distance = distance;
            final later = await render(
              tester,
              game,
              art,
              w,
              h,
              sceneryMotion: false,
            );
            expect(
              sameScenery(start, later),
              isTrue,
              reason: '${w}x$h, distance $distance, art ${art != null}',
            );
          }
          final moving = await render(tester, game, art, w, h);
          expect(sameScenery(start, moving), isFalse);
        }
      }
    });

    testWidgets('calm scenery still lets obstacles and pickups approach', (
      tester,
    ) async {
      final loaded = await decodeArt(tester);
      const w = 640, h = 400;
      final s = stageLayout(const Size(640, 400)).s;
      (int, int) changedBounds(
        Uint8List background,
        Uint8List scene,
        double from,
        double to,
      ) {
        var left = w, right = -1;
        for (var y = (from * s).floor(); y < (to * s).ceil(); y++) {
          for (var x = (s * .7).ceil(); x < w; x++) {
            final i = (y * w + x) * 4;
            if ((background[i] - scene[i]).abs() > 6 ||
                (background[i + 1] - scene[i + 1]).abs() > 6 ||
                (background[i + 2] - scene[i + 2]).abs() > 6) {
              left = min(left, x);
              right = max(right, x);
            }
          }
        }
        expect(right, greaterThan(left), reason: 'a visible course item');
        return (left, right);
      }

      for (final art in [loaded, null]) {
        final game = StageRunner(random: Random(1))
          ..distance = .5
          ..time = .5
          ..obstacles.clear()
          ..pickups.clear();
        final background = await render(
          tester,
          game,
          art,
          w,
          h,
          sceneryMotion: false,
        );
        final crate = Obstacle()
          ..left = 1.75
          ..width = .1
          ..top = StageRunner.floor - .1
          ..bottom = StageRunner.floor;
        final pickup = Pickup()
          ..x = 1.55
          ..y = .35;
        game.obstacles.add(crate);
        game.pickups.add(pickup);
        Future<Uint8List> shot() async {
          final state = (
            game.distance,
            game.time,
            game.score,
            crate.left,
            crate.right,
            pickup.x,
            pickup.y,
            pickup.taken,
          );
          final pixels = await render(
            tester,
            game,
            art,
            w,
            h,
            sceneryMotion: false,
          );
          expect((
            game.distance,
            game.time,
            game.score,
            crate.left,
            crate.right,
            pickup.x,
            pickup.y,
            pickup.taken,
          ), state);
          return pixels;
        }

        final before = await shot();
        game.distance += 40 / s;
        final after = await shot();
        for (final (from, to) in [
          (.25, .45),
          (StageRunner.floor - .12, StageRunner.floor),
        ]) {
          final first = changedBounds(background, before, from, to);
          final later = changedBounds(background, after, from, to);
          // Blended sprite edges may merge with a background pixel; their
          // visible bounds still travel exactly with the course.
          expect(later.$1, closeTo(first.$1 - 40, 1));
          expect(later.$2, closeTo(first.$2 - 40, 1));
        }
      }
    });

    testWidgets('calm scenery suppresses shaking and sliding decorations', (
      tester,
    ) async {
      final art = await decodeArt(tester);
      const w = 390, h = 844;
      final s = stageLayout(const Size(390, 844)).s;
      final game = StageRunner(random: Random(1))
        ..distance = .5
        ..time = .5
        ..obstacles.clear()
        ..pickups.clear()
        ..over = true
        ..sinceOver = .05;
      final before = await render(
        tester,
        game,
        art,
        w,
        h,
        sceneryMotion: false,
      );
      game.sinceOver = .15;
      final after = await render(tester, game, art, w, h, sceneryMotion: false);
      // The character can fall after a crash; the surrounding scene cannot
      // shake. Both snapshots precede the closing curtain.
      var changed = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (x > s * .2 && x < s * .7) continue;
          final i = (y * w + x) * 4;
          if (after[i] != before[i] ||
              after[i + 1] != before[i + 1] ||
              after[i + 2] != before[i + 2]) {
            changed++;
          }
        }
      }
      expect(changed, 0);
      // The end transition still happens, but its curtain is fully closed
      // from the start rather than sweeping across the picture.
      game.sinceOver = .21;
      final curtainStart = await render(
        tester,
        game,
        art,
        w,
        h,
        sceneryMotion: false,
      );
      game.sinceOver = .8;
      final curtainEnd = await render(
        tester,
        game,
        art,
        w,
        h,
        sceneryMotion: false,
      );
      expect(listEquals(curtainStart, curtainEnd), isTrue);
      expect(listEquals(after, curtainStart), isFalse);

      game.over = false;
      final fx = RunnerFx()
        ..banner = '100 m – Applaus!'
        ..bannerAge = .05;
      final bannerStart = await render(
        tester,
        game,
        art,
        w,
        h,
        fx: fx,
        sceneryMotion: false,
      );
      for (final age in [.5, 1.5]) {
        fx.bannerAge = age;
        final bannerLater = await render(
          tester,
          game,
          art,
          w,
          h,
          fx: fx,
          sceneryMotion: false,
        );
        expect(listEquals(bannerStart, bannerLater), isTrue);
      }
    });

    // Phones upright and turned, a laptop, a tablet and a cinema-wide
    // window.
    const shapes = {
      '9:19.5': (390, 845),
      '19.5:9': (845, 390),
      '16:9': (800, 450),
      '4:3': (800, 600),
      '21:9': (1050, 450),
    };

    testWidgets('pictures of any shape are filled to the edges', (
      tester,
    ) async {
      final art = await decodeArt(tester);
      for (final MapEntry(key: shape, value: (w, h)) in shapes.entries) {
        final game = StageRunner(random: Random(2))
          ..invincible = true
          ..view = stageLayout(Size(w.toDouble(), h.toDouble())).view;
        for (var i = 0; i < 60 * 6; i++) {
          game.update(1 / 60);
        }
        final rgba = await render(tester, game, art, w, h);
        // Every pixel is painted, and none shows the bare dark behind the
        // stage: no bars, no gaps between the layers.
        var bare = 0, clear = 0;
        for (var i = 0; i < rgba.length; i += 4) {
          if (rgba[i + 3] != 255) clear++;
          if (rgba[i] == 0x15 && rgba[i + 1] == 0x1A && rgba[i + 2] == 0x17) {
            bare++;
          }
        }
        expect(clear, 0, reason: shape);
        expect(bare, lessThan(w * h * .001), reason: shape);
      }
    });

    test('obstacles come in from outside the picture, however wide', () {
      for (final MapEntry(key: shape, value: (w, h)) in shapes.entries) {
        final view = stageLayout(Size(w.toDouble(), h.toDouble())).view;
        final game = StageRunner(random: Random(5))
          ..invincible = true
          ..view = view;
        expect(game.view, max(StageRunner.viewWidth, view));
        // The first obstacles stand ready when the curtain opens; every
        // later one (and every pickup) is laid out beyond the right edge.
        var seen = Set<Obstacle>.identity()..addAll(game.obstacles);
        final seenPickups = Set<Pickup>.identity()..addAll(game.pickups);
        var count = 0;
        for (var i = 0; i < 60 * 90; i++) {
          game.update(1 / 60);
          for (final o in game.obstacles) {
            if (seen.contains(o)) continue;
            count++;
            expect(
              o.left - game.distance,
              greaterThan(game.view + .05),
              reason: '$shape at ${game.meters} m',
            );
          }
          for (final p in game.pickups) {
            if (!seenPickups.add(p)) continue;
            expect(p.x - game.distance, greaterThan(game.view + .05));
          }
          seen = Set<Obstacle>.identity()..addAll(game.obstacles);
          seenPickups.retainAll(game.pickups);
        }
        expect(count, greaterThan(50), reason: shape);
      }
    });

    test('a wider picture changes only how early the course is laid out', () {
      // Without new obstacles (they join by score, when they are laid out),
      // the same dice give the same course in every picture: the kinds in
      // the same order, at the same places and heights. The speed at
      // arrival is estimated as on the narrowest picture; only the frames
      // fall a little differently.
      List<(ObstacleKind, double, double, double)> course(double view) {
        final game = StageRunner(random: Random(7))
          ..invincible = true
          ..view = view;
        final out = <(ObstacleKind, double, double, double)>[];
        final seen = Set<Obstacle>.identity();
        while (game.score < 200) {
          game.update(1 / 60);
          for (final o in game.obstacles) {
            if (seen.add(o)) out.add((o.kind, o.left, o.top, o.bottom));
          }
          seen.retainAll(game.obstacles);
        }
        return out.where((o) => o.$2 < 15).toList();
      }

      final narrow = course(StageRunner.viewWidth);
      expect(narrow.length, greaterThan(10));
      for (final view in [2.2, 2.6, 3.5]) {
        final wide = course(view);
        expect(wide.length, narrow.length);
        for (final (i, o) in narrow.indexed) {
          expect(wide[i].$1, o.$1);
          expect(wide[i].$2, closeTo(o.$2, .001));
          expect(wide[i].$3, closeTo(o.$3, .001));
          expect(wide[i].$4, closeTo(o.$4, .001));
        }
      }
    });

    testWidgets('a turned phone pauses the run; nothing jumps', (tester) async {
      tester.view.physicalSize = const Size(390, 845);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TestServer().controller();
      addTearDown(controller.dispose);
      late StageRunner game;
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: StageRunnerScreen(
            controller: controller,
            random: Random(3),
            onRun: (g) => game = g..invincible = true,
            sound: _FakeSound(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Vorhang auf'), 200);
      await tester.tap(find.text('Vorhang auf'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      Size stage() =>
          tester.getSize(find.byKey(const ValueKey('runner-stage')));
      // Upright, the stage keeps its width of 1.6 stage heights and fills
      // the screen below the app bar.
      expect(stage(), Size(390, 845 - kToolbarHeight));
      expect(game.view, closeTo(StageRunner.viewWidth, 1e-9));
      final (distance, y, time) = (game.distance, game.y, game.time);
      expect(distance, greaterThan(.2));

      // Turned: the run waits, the picture is filled, the course reaches
      // its new right edge at once.
      tester.view.physicalSize = const Size(845, 390);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);
      expect(stage(), Size(845, 390 - kToolbarHeight));
      final view = 845 / (390 - kToolbarHeight);
      expect(game.view, closeTo(view, 1e-9));
      final ready = Set<Obstacle>.identity()..addAll(game.obstacles);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Paused, nothing moved: state in stage heights only gets scaled.
      expect(game.time - time, lessThan(.02));
      expect((game.distance - distance).abs(), lessThan(.02));
      expect((game.y - y).abs(), lessThan(.02));

      // A tap runs on from where it stood, at the usual pace.
      await tester.tapAt(const Offset(400, 200));
      await tester.pump();
      expect(find.byKey(const ValueKey('runner-paused')), findsNothing);
      final before = game.distance;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(game.distance - before, closeTo(game.speed * 30 * .016, .02));
      // Whatever was not laid out yet comes in from beyond the new edge.
      for (var i = 0; i < 120; i++) {
        final known = Set<Obstacle>.identity()..addAll(game.obstacles);
        await tester.pump(const Duration(milliseconds: 16));
        for (final o in game.obstacles) {
          if (known.contains(o) || ready.contains(o)) continue;
          expect(o.left - game.distance, greaterThan(view));
        }
      }

      // And back upright, again with a pause.
      tester.view.physicalSize = const Size(390, 845);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);
      expect(game.view, closeTo(StageRunner.viewWidth, 1e-9));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    test('things leave the course only once they are out of the picture', () {
      for (final MapEntry(key: shape, value: (w, h)) in shapes.entries) {
        final game = StageRunner(random: Random(9))
          ..invincible = true
          ..view = stageLayout(Size(w.toDouble(), h.toDouble())).view;
        var gone = 0;
        var last = <Obstacle, double>{};
        var lastPickups = <Pickup, double>{};
        for (var i = 0; i < 60 * 90; i++) {
          game.holding = sin(i / 40) > .2;
          final before = game.distance;
          game.update(1 / 60);
          final now = Map<Obstacle, double>.identity()
            ..addEntries(game.obstacles.map((o) => MapEntry(o, o.right)));
          // An obstacle (with the beam or frame its picture may add) is
          // dropped only once its right edge has passed the picture's left
          // edge, the course at [distance], with room to spare.
          // Objects are reused: one that turns up far ahead is a new one.
          for (final MapEntry(key: o, value: right) in last.entries) {
            final still = now[o];
            if (still != null && (still - right).abs() < .5) continue;
            gone++;
            expect(right, lessThan(before - .1), reason: shape);
          }
          for (final MapEntry(key: p, value: x) in lastPickups.entries) {
            if (p.taken) continue;
            if (game.pickups.any((q) => identical(q, p)) && p.x == x) continue;
            expect(x, lessThan(before - .1), reason: shape);
          }
          last = now;
          lastPickups = Map<Pickup, double>.identity()
            ..addEntries(
              game.pickups.where((p) => !p.taken).map((p) => MapEntry(p, p.x)),
            );
        }
        expect(gone, greaterThan(50), reason: shape);
      }
    });

    testWidgets('the left edge cuts the picture, nothing else', (tester) async {
      final art = await decodeArt(tester);
      // Every kind of obstacle and a rose straddle the left edge. The same
      // stage 100 pixels further on shows them whole; the left edge must be
      // a plain cut through it: no thing missing, faded or half drawn.
      for (final MapEntry(key: shape, value: (w, h)) in shapes.entries) {
        final (:s, :top, :view) = stageLayout(Size(w.toDouble(), h.toDouble()));
        const shift = 100;
        // Where the picture cut by the left edge starts on the course.
        final edge = (8 + shift) / s;
        Future<Uint8List> shot(double px) {
          final d = px / s;
          final game = StageRunner(random: Random(1))
            ..distance = d
            ..time = 1
            ..view = view;
          game
            ..obstacles.clear()
            ..pickups.clear();
          for (final (kind, width, top, bottom) in [
            (
              ObstacleKind.crate,
              .12,
              StageRunner.floor - .15,
              StageRunner.floor,
            ),
            (ObstacleKind.truss, .3, 0.0, .3),
            (ObstacleKind.flat, .07, .5, StageRunner.floor),
            (ObstacleKind.lamp, .1, 0.0, .35),
            (ObstacleKind.border, .09, 0.0, .2),
            (ObstacleKind.sandbag, .09, .4, .5),
            (
              ObstacleKind.drum,
              .12,
              StageRunner.floor - .12,
              StageRunner.floor,
            ),
          ]) {
            // Each one half out of the picture.
            final x = edge - width / 2;
            game.obstacles.add(
              Obstacle()
                ..kind = kind
                ..left = x
                ..width = width
                ..top = top
                ..bottom = bottom
                ..anchor = x,
            );
          }
          game.pickups.add(
            Pickup()
              ..kind = PickupKind.rose
              ..x = edge + .01
              ..y = .6,
          );
          return render(tester, game, art, w, h);
        }

        final cut = await shot(8.0 + shift), whole = await shot(8);
        final runner = (.3 * s, .6 * s);
        bool near(int x) => x > runner.$1 && x < runner.$2;
        // Round shapes cut by an edge are smoothed a little differently in
        // its outermost pixels, by up to a tenth of the colour range; a
        // missing, faded or half drawn thing differs by far more.
        var differ = 0, covered = 0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x + shift < w - 8; x++) {
            if (near(x) || near(x + shift)) continue;
            final i = (y * w + x) * 4, j = (y * w + x + shift) * 4;
            final shades = x < 8 ? 40 : 6;
            covered++;
            if ((cut[i] - whole[j]).abs() > shades ||
                (cut[i + 1] - whole[j + 1]).abs() > shades ||
                (cut[i + 2] - whole[j + 2]).abs() > shades) {
              differ++;
            }
          }
        }
        expect(covered, greaterThan(w * h / 3), reason: shape);
        expect(differ, 0, reason: '$shape (stage top at $top)');
      }
    });

    testWidgets('the stage paints nothing outside its picture', (tester) async {
      final art = await decodeArt(tester);
      const margin = 120;
      for (final MapEntry(key: shape, value: (w, h)) in shapes.entries) {
        for (final withArt in [true, false]) {
          final game = StageRunner(random: Random(4))
            ..invincible = true
            ..view = stageLayout(Size(w.toDouble(), h.toDouble())).view;
          for (var i = 0; i < 60 * 3; i++) {
            game.update(1 / 60);
          }
          // The set is laid out beyond both edges; a picture with room
          // around it shows whether any of it lands there.
          final rgba = (await tester.runAsync(() async {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder)
              ..translate(margin.toDouble(), margin.toDouble());
            stagePainterFor(
              game,
              withArt ? art : null,
            ).paint(canvas, Size(w.toDouble(), h.toDouble()));
            final image = await recorder.endRecording().toImage(
              w + 2 * margin,
              h + 2 * margin,
            );
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            image.dispose();
            return data!.buffer.asUint8List();
          }))!;
          final width = w + 2 * margin;
          var outside = 0, inside = 0;
          for (var y = 0; y < h + 2 * margin; y++) {
            for (var x = 0; x < width; x++) {
              final within =
                  x >= margin &&
                  x < margin + w &&
                  y >= margin &&
                  y < margin + h;
              final alpha = rgba[(y * width + x) * 4 + 3];
              if (within && alpha == 255) inside++;
              if (!within && alpha != 0) outside++;
            }
          }
          final at = '$shape${withArt ? '' : ' without art'}';
          expect(outside, 0, reason: at);
          expect(inside, w * h, reason: at);
        }
      }
    });

    testWidgets('on Android the navigation bar lays no veil over a run', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(845, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TestServer().controller();
      addTearDown(controller.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: StageTheme.build(Brightness.light),
          home: const Scaffold(body: Text('Start')),
        ),
      );
      navigator.currentState!
          .push(
            MaterialPageRoute<void>(
              builder: (_) => StageRunnerScreen(
                controller: controller,
                random: Random(3),
                onRun: (g) => g.invincible = true,
                sound: _FakeSound(),
              ),
            ),
          )
          .ignore();
      await tester.pumpAndSettle();
      bool? veil() =>
          SystemChrome.latestStyle?.systemNavigationBarContrastEnforced;
      expect(veil(), isTrue);
      await tester.scrollUntilVisible(find.text('Vorhang auf'), 200);
      await tester.tap(find.text('Vorhang auf'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Clear while running, to the screen's edge ...
      expect(veil(), isFalse);
      // ... and back as usual for the rest of the app, also when the run
      // is left halfway.
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Start'), findsOneWidget);
      expect(veil(), isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the shine stays on the figure, no light on the stage', (
      tester,
    ) async {
      const s = 400, w = 640;
      // Decoded here: an earlier test may have left RunnerArt.load waiting
      // in its fake time.
      final base = (await tester.runAsync(() async {
        Future<ui.Image> decode(String name) async {
          final data = await rootBundle.load('assets/games/stage_runner/$name');
          final codec = await ui.instantiateImageCodec(
            data.buffer.asUint8List(),
          );
          return (await codec.getNextFrame()).image;
        }

        return RunnerArt.test(
          await decode('atlas.webp'),
          await decode('backdrop.webp'),
        );
      }))!;
      final shiny = base.dressed(
        effect: const RunnerEffectStyle('', [], shine: true),
      );
      Future<Uint8List> shot(RunnerArt art, double y, double vy) async {
        final game = StageRunner(random: Random(1))
          ..distance = .02
          ..time = 1
          ..y = y
          ..vy = vy;
        // The glints gather as in a run, and the sheen is midway.
        final trail = RunnerTrail(random: Random(3));
        for (var i = 0; i < 40; i++) {
          trail.update(1 / 60, game, art.effect);
        }
        final bytes = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          stagePainterFor(
            game,
            art,
            trail: trail,
          ).paint(Canvas(recorder), Size(w.toDouble(), s.toDouble()));
          final image = await recorder.endRecording().toImage(w, s);
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!.buffer.asUint8List();
        });
        return bytes!;
      }

      // Pixels that differ in the rows from [top] to [bottom] (stage
      // heights).
      int changed(Uint8List a, Uint8List b, double top, double bottom) {
        var n = 0;
        for (var y = max(0, (top * s).floor()); y < min(s, bottom * s); y++) {
          for (var i = y * w * 4; i < (y + 1) * w * 4; i += 4) {
            if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) {
              n++;
            }
          }
        }
        return n;
      }

      const ground = StageRunner.floor - StageRunner.runnerHeight / 2;
      for (final (pose, y, vy) in [
        ('fly', .42, -.6),
        ('dangle', .42, .3),
        ('run', ground, 0.0),
      ]) {
        final plain = await shot(base, y, vy), shine = await shot(shiny, y, vy);
        // Around the figure it shines (rim, sheen, glints) ...
        expect(changed(plain, shine, y - .1, y + .1), greaterThan(200));
        // ... and nowhere else: no cone above it, no light below it, no
        // circle of light on the floor.
        expect(changed(plain, shine, 0, y - .1), 0, reason: '$pose above');
        expect(
          changed(plain, shine, max(y + .1, StageRunner.floor + .03), 1),
          0,
          reason: '$pose below',
        );
      }
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
