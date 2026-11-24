import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/games/data/runner_menu_preferences.dart';
import 'package:theater_app/features/games/data/score_outbox.dart';
import 'package:theater_app/features/games/domain/runner_ghost.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/runner_menu.dart';
import 'package:theater_app/features/games/ui/runner_news.dart';
import 'package:theater_app/features/games/ui/runner_volume_settings.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_fx.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/shared/feedback.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;

class _SpySound
    implements RunnerSound, RunnerMusic, RunnerVolumes, RunnerMusicPreview {
  final _enabled = ValueNotifier(true);
  final _music = ValueNotifier(1.0);
  final _effects = ValueNotifier(1.0);
  final _other = ValueNotifier(false);
  final events = <String>[];
  bool playing = false;
  bool previewing = false;

  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) {
    events.add('enabled:$on');
    _enabled.value = on;
  }

  @override
  ValueListenable<double> get musicVolume => _music;
  @override
  ValueListenable<double> get effectsVolume => _effects;
  @override
  void setMusicVolume(double share) {
    events.add('musicVol:${share.toStringAsFixed(2)}');
    _music.value = share;
  }

  @override
  void setEffectsVolume(double share) {
    events.add('effectsVol:${share.toStringAsFixed(2)}');
    _effects.value = share;
  }

  @override
  void previewEffect(RunnerSfx sfx) => events.add('previewSfx:${sfx.name}');

  @override
  ValueListenable<bool> get otherMusicActive => _other;
  void setOtherMusic(bool active) => _other.value = active;

  @override
  void refreshOtherMusic() => events.add('refreshOther');

  @override
  void startMusicPreview() {
    previewing = true;
    events.add('startPreview');
  }

  @override
  void stopMusicPreview() {
    if (!previewing) return;
    previewing = false;
    events.add('stopPreview');
  }

  @override
  void prepare() {}
  @override
  void play(RunnerSfx sfx) => events.add('sfx:${sfx.name}');
  @override
  void warmUp() {}
  @override
  void useTune(Uint8List? tune) {}
  @override
  void startMusic() {
    playing = true;
    events.add('startMusic');
  }

  @override
  void stopMusic() {
    playing = false;
    events.add('stopMusic');
  }

  @override
  void pauseMusic() {
    playing = false;
    events.add('pauseMusic');
  }

  @override
  void resumeMusic() {
    playing = true;
    events.add('resumeMusic');
  }

  @override
  void dispose() {
    _enabled.dispose();
    _music.dispose();
    _effects.dispose();
    _other.dispose();
  }
}

class _SpyCanvas implements Canvas {
  final lines = <(Offset, Offset, Paint)>[];
  final ovals = <(Rect, Paint)>[];
  final circles = <(Offset, double, Paint)>[];
  final paths = <(Path, Paint)>[];
  final rects = <(Rect, Paint)>[];
  final images = <(Rect, Paint)>[];
  final paragraphs = <(Offset, double)>[];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines.add((p1, p2, paint));

  @override
  void drawOval(Rect rect, Paint paint) => ovals.add((rect, paint));

  @override
  void drawCircle(Offset c, double radius, Paint paint) =>
      circles.add((c, radius, paint));

  @override
  void drawPath(Path path, Paint paint) => paths.add((path, paint));

  @override
  void drawRect(Rect rect, Paint paint) => rects.add((rect, paint));

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) =>
      images.add((dst, paint));

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) =>
      paragraphs.add((offset, paragraph.longestLine));

  @override
  int getSaveCount() => 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeWebVoice implements WebAudioVoice {
  _FakeWebVoice(this.log);
  final List<String> log;
  @override
  void stop({Duration fadeOut = Duration.zero}) => log.add('voiceStop');
}

class _FakeWebClip implements WebAudioClip {
  _FakeWebClip(this.log, this.channel);
  final List<String> log;
  final WebAudioChannel channel;
  @override
  WebAudioVoice play({bool loop = false, Duration fadeIn = Duration.zero}) {
    log.add(loop ? 'playLoop:${channel.name}' : 'play:${channel.name}');
    return _FakeWebVoice(log);
  }
}

class _FakeWebAudio implements WebAudio {
  final log = <String>[];
  @override
  void resume() => log.add('resume');
  @override
  void suspend() => log.add('suspend');
  @override
  Future<WebAudioClip> decode(
    Uint8List bytes,
    double volume,
    WebAudioChannel channel,
  ) async {
    log.add('decode:${channel.name}');
    return _FakeWebClip(log, channel);
  }

  @override
  void setVolume(WebAudioChannel channel, double gain) =>
      log.add('vol:${channel.name}:${gain.toStringAsFixed(2)}');

  @override
  void close() => log.add('close');
}

class _FakeBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList([1, 2, 3, 4]));
}

ui.Image _solidImage(int w, int h) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFFCCCCCC),
  );
  return recorder.endRecording().toImageSync(w, h);
}

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Obstacle _obstacle({
  required ObstacleKind kind,
  required double left,
  required double width,
  required double bottom,
  required double height,
  bool falling = false,
}) => Obstacle()
  ..kind = kind
  ..left = left
  ..width = width
  ..top = bottom - height
  ..bottom = bottom
  ..falling = falling;

Pickup _pickup(PickupKind kind, double x, double y) => Pickup()
  ..kind = kind
  ..x = x
  ..y = y;

JsonMap _wardrobeJson({
  int crates = 1,
  int missionCrates = 0,
  JsonMap? nextDrop,
}) => {
  'progress': {
    'meters': 1200,
    'earned': 2,
    'opened': 1,
    'crates': crates,
    'missionCrates': missionCrates,
    'previousAt': 1000,
    'nextAt': 2500,
    'poolSize': 4,
    'complete': false,
    'dupes': true,
  },
  'gage': {'balance': 500, 'earned': 1000},
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hellblau', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
    ],
    'departments': [],
    'items': [
      {
        'id': 'c0',
        'kind': 'character',
        'name': 'Engel Logge',
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'default': true,
      },
      {
        'id': 'b0',
        'kind': 'backdrop',
        'name': 'Bühnenwand',
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'default': true,
      },
      {
        'id': 'o0',
        'kind': 'obstacles',
        'name': 'Requisitenlager',
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'default': true,
      },
      {
        'id': 'f0',
        'kind': 'fx',
        'name': 'Ohne Effekt',
        'rarity': 'hellblau',
        'rarities': ['hellblau'],
        'default': true,
      },
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0'],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'stats': {'rounds': 4, 'best': 420, 'meters': 1200},
  'nextDrop': ?nextDrop,
};

JsonMap _missionsJson({List<JsonMap>? missions, bool allDone = false}) => {
  'day': '2026-10-29',
  'missions':
      missions ??
      [
        {
          'slot': 'easy',
          'type': 'ground',
          'target': 80,
          'progress': 0,
          'done': false,
          'reward': 200,
          'text': 'Bleib 80 m am Boden',
          'unit': 'm',
          'scope': 'run',
        },
        {
          'slot': 'medium',
          'type': 'noPickup',
          'target': 120,
          'progress': 0,
          'done': false,
          'reward': 300,
          'text': '120 m ohne Requisite',
          'unit': 'm',
          'scope': 'run',
        },
      ],
  'rerollAvailable': true,
  'allDone': allDone,
  'crate': {'earned': allDone, 'shinyChance': 0.05},
};

JsonMap _weeklyJson({int used = 1}) => {
  'week': '2026-W37',
  'seed': 3141592653,
  'startsAt': '2026-09-06T22:00:00.000Z',
  'endsAt': '2026-09-13T22:00:00.000Z',
  'attempts': {'used': used, 'max': 3},
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
    },
    {
      'rank': 2,
      'personId': 3,
      'name': 'Ich',
      'score': 120,
      'meters': 100,
      'at': '2026-09-10T18:00:00.000Z',
      'me': true,
    },
  ],
  'ghosts': [],
  'lastWeek': null,
};

JsonMap _boardJson({int score = 420, int rank = 5}) => {
  'players': 12,
  'top': [
    {
      'rank': 1,
      'personId': 7,
      'name': 'Lena',
      'score': 900,
      'meters': 800,
      'at': '2026-09-10T18:00:00.000Z',
      'me': false,
    },
  ],
  'own': {
    'rank': rank,
    'personId': 3,
    'name': 'Ich',
    'score': score,
    'meters': score - 20,
    'at': '2026-09-10T18:00:00.000Z',
    'me': true,
  },
};

Future<AppController> _demoController() async {
  final controller = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
    clock: () => fixedNow,
  );
  addTearDown(controller.dispose);
  await controller.startDemo();
  return controller;
}

Future<void> _pumpApp(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(960, 720),
  bool disableAnimations = false,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  if (disableAnimations) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: child),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _finishCountdown(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(StageRunnerScreen.resumeCountdownStep);
  }
}

Future<void> _runUntilFinished(WidgetTester tester) async {
  for (
    var i = 0;
    i < 400 && find.text('Der Vorhang fällt!').evaluate().isEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
  expect(find.text('Der Vorhang fällt!'), findsOneWidget);
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  setUp(() {
    SharedPreferences.setMockInitialValues({
      RunnerMenuPreferences.newsSeenKey: [for (final n in runnerNews) n.id],
    });
  });

  group('Pause, 3-2-1 Countdown und neutrales Fortsetzen', () {
    testWidgets(
      'AppBar-Pause, Esc/P, 3-2-1 Countdown, neutrales Fortsetzen und Neu starten',
      (tester) async {
        final controller = await _demoController();
        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          StageRunnerScreen(
            controller: controller,
            random: Random(7),
            sound: sound,
            onRun: games.add,
          ),
        );

        await tester.tap(find.byKey(const ValueKey('runner-start')));
        await tester.pump();
        final game = games.single;
        game.invincible = true;
        await tester.pump(const Duration(milliseconds: 60));
        expect(find.byKey(const ValueKey('runner-pause-button')), findsOneWidget);

        // AppBar pause button pauses run and shows card with Weiter + Neu starten.
        await tester.tap(find.byKey(const ValueKey('runner-pause-button')));
        await tester.pump();
        expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);
        expect(find.byKey(const ValueKey('runner-resume')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('runner-pause-restart')),
          findsOneWidget,
        );
        expect(sound.playing, isFalse);

        final resumeSemantics = tester.getSemantics(
          find.byKey(const ValueKey('runner-resume')),
        );
        expect(resumeSemantics.label, contains('Lauf fortsetzen'));

        final pausedDist = game.distance;
        // Space resumes via 3-2-1 countdown and stays neutral even if held.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(find.byKey(const ValueKey('runner-paused')), findsNothing);
        expect(find.byKey(const ValueKey('runner-countdown')), findsOneWidget);
        expect(find.text('3'), findsOneWidget);

        await tester.pump(StageRunnerScreen.resumeCountdownStep);
        expect(find.text('2'), findsOneWidget);
        expect(game.distance, pausedDist);

        await tester.pump(StageRunnerScreen.resumeCountdownStep);
        expect(find.text('1'), findsOneWidget);
        expect(game.distance, pausedDist);

        await tester.pump(StageRunnerScreen.resumeCountdownStep);
        expect(find.byKey(const ValueKey('runner-countdown')), findsNothing);
        await tester.pump(const Duration(milliseconds: 32));
        expect(game.distance, greaterThan(pausedDist));
        expect(
          game.holding,
          isFalse,
          reason: 'resume key must not trigger lift',
        );

        // Releasing and pressing Space again climbs normally.
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 32));
        expect(game.holding, isTrue);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);

        // KeyP pauses, Neu starten launches a fresh run immediately.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
        await tester.pump();
        expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('runner-pause-restart')));
        await tester.pump();
        expect(games, hasLength(2));
        expect(find.byKey(const ValueKey('runner-paused')), findsNothing);

        // Escape pauses and resumes via countdown.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byKey(const ValueKey('runner-countdown')), findsOneWidget);
        await _finishCountdown(tester);
        expect(find.byKey(const ValueKey('runner-countdown')), findsNothing);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'Pause-Overlay zeigt offene Missionen & 1-Tap-Geister und versteckt Neu starten im Wertungslauf',
      (tester) async {
        final server = TestServer();
        server.data['capabilities'] = {
          'features': [
            'stageRunner',
            'runnerMissions',
            'runnerWeekly',
            'runnerUnlocks',
          ],
        };
        server.override = (req) {
          final p = _path(req);
          if (p.endsWith('/leaderboard')) {
            return Future.value(jsonResponse(_boardJson()));
          }
          if (p.endsWith('/wardrobe')) {
            return Future.value(jsonResponse(_wardrobeJson()));
          }
          if (p.endsWith('/missions')) {
            return Future.value(jsonResponse(_missionsJson()));
          }
          if (p.endsWith('/weekly')) {
            return Future.value(jsonResponse(_weeklyJson(used: 1)));
          }
          if (p.endsWith('/rounds')) {
            return Future.value(jsonResponse({'roundId': 'w-2', 'attempt': 2}));
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          StageRunnerScreen(
            controller: controller,
            sound: sound,
            onRun: games.add,
          ),
        );
        await tester.pumpAndSettle();

        // Enter weekly -> ranked run.
        await tester.tap(find.byKey(const ValueKey('runner-weekly')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('weekly-ranked')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        games.single.invincible = true;
        await tester.tap(find.byKey(const ValueKey('runner-pause-button')));
        await tester.pump();

        expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('runner-pause-restart')),
          findsNothing,
          reason: 'ranked weekly run must not offer instant restart',
        );
        expect(find.byKey(const ValueKey('runner-pause-ghosts')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('runner-pause-missions')),
          findsOneWidget,
        );
        expect(find.text('120 m ohne Requisite'), findsOneWidget);

        // 1-tap ghost toggle inside pause persists preference directly.
        await tester.tap(find.byKey(const ValueKey('pause-ghosts-off')));
        await tester.pump();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(RunnerMenuPreferences.ghostModeKey), 'off');

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('DiscardGuard und Fokus-Entkopplung', () {
    testWidgets(
      'DiscardGuard(confirm:) schützt PopScope und popToFirst mit custom Confirm',
      (tester) async {
        var calls = 0;
        var allow = false;
        final navKey = GlobalKey<NavigatorState>();

        await _pumpApp(
          tester,
          Navigator(
            key: navKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DiscardGuard(
                        dirty: true,
                        confirm: (ctx) async {
                          calls++;
                          return allow;
                        },
                        child: const Scaffold(body: Text('Run')),
                      ),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Run'), findsOneWidget);

        // Back pop blocked when confirm returns false.
        await navKey.currentState!.maybePop();
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.text('Run'), findsOneWidget);

        // Desktop rail popToFirst calls the same custom confirm.
        final blocked = await popToFirst(
          tester.element(find.text('Run')),
          navKey.currentState!,
        );
        await tester.pumpAndSettle();
        expect(blocked, isFalse);
        expect(calls, 2);
        expect(find.text('Run'), findsOneWidget);

        // Confirm returns true -> pops cleanly.
        allow = true;
        final popped = await popToFirst(
          tester.element(find.text('Run')),
          navKey.currentState!,
        );
        await tester.pumpAndSettle();
        expect(popped, isTrue);
        expect(calls, 3);
        expect(find.text('Run'), findsNothing);
      },
    );

    testWidgets(
      'Verlassen im Lauf pausiert + fragt nach; AppBar-Mute entkoppelt Space-Fokus',
      (tester) async {
        final controller = await _demoController();
        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => StageRunnerScreen(
                      controller: controller,
                      random: Random(4),
                      sound: sound,
                      onRun: games.add,
                    ),
                  ),
                ),
                child: const Text('Launch'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Launch'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('runner-start')));
        await tester.pump();
        final game = games.single;
        game.invincible = true;

        // Tapping Mute in AppBar during play toggles sound once, then Space
        // controls flight instead of re-toggling Mute.
        expect(sound.enabled.value, isTrue);
        await tester.tap(find.byKey(const ValueKey('runner-sound')));
        await tester.pump();
        expect(sound.enabled.value, isFalse);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump(const Duration(milliseconds: 32));
        expect(
          sound.enabled.value,
          isFalse,
          reason: 'Space must not re-toggle Mute',
        );
        expect(game.holding, isTrue);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);

        // Navigating back during active run pauses and asks confirmation.
        unawaited(
          Navigator.maybePop(
            tester.element(find.byKey(const ValueKey('runner-stage'))),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Lauf abbrechen?'), findsOneWidget);
        expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);

        // Canceling keeps the run paused.
        await tester.tap(find.text('Weiterspielen'));
        await tester.pumpAndSettle();
        expect(find.text('Lauf abbrechen?'), findsNothing);
        expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);

        // Confirming pops back to launcher.
        unawaited(
          Navigator.maybePop(
            tester.element(find.byKey(const ValueKey('runner-stage'))),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        expect(find.text('Launch'), findsOneWidget);
      },
    );

    testWidgets(
      'Verlassen eines Wertungslaufs warnt vor verlorenem Wochenprobe-Versuch',
      (tester) async {
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['stageRunner', 'runnerWeekly'],
        };
        server.override = (req) {
          final p = _path(req);
          if (p.endsWith('/leaderboard')) {
            return Future.value(jsonResponse(_boardJson()));
          }
          if (p.endsWith('/weekly')) {
            return Future.value(jsonResponse(_weeklyJson(used: 1)));
          }
          if (p.endsWith('/rounds')) {
            return Future.value(jsonResponse({'roundId': 'w-2', 'attempt': 2}));
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => StageRunnerScreen(
                      controller: controller,
                      sound: sound,
                      onRun: games.add,
                    ),
                  ),
                ),
                child: const Text('Launch'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Launch'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('runner-weekly')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('weekly-ranked')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
        await tester.pump();
        games.single.invincible = true;

        unawaited(
          Navigator.maybePop(
            tester.element(find.byKey(const ValueKey('runner-stage'))),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Wertungslauf abbrechen?'), findsOneWidget);
        expect(
          find.textContaining('beim Start gezählt und geht beim Abbruch verloren'),
          findsOneWidget,
        );
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        expect(find.text('Launch'), findsOneWidget);
      },
    );
  });

  group('Hindernis-Telegraphing', () {
    test('Drop-Flylines im Art-Modus, Sandbag-Warnung/Schatten und Drum-Trail', () {
      final img = _solidImage(32, 32);
      addTearDown(img.dispose);
      final art = RunnerArt.test(img, img);

      // 1. Drop obstacle in art mode draws heavy fly-lines up to y = 0.
      final dropGame = StageRunner(random: Random(1));
      dropGame.obstacles
        ..clear()
        ..add(
          _obstacle(
            kind: ObstacleKind.drop,
            left: StageRunner.runnerX + 0.5,
            width: 0.18,
            bottom: 0.55,
            height: 0.16,
          ),
        );
      final dropCanvas = _SpyCanvas();
      final dropPainter = stagePainterFor(dropGame, art);
      addTearDown(dropPainter.dispose);
      dropPainter.paint(dropCanvas, const Size(800, 500));
      expect(
        dropCanvas.lines.any((l) => l.$1.dy == 0 && l.$3.strokeWidth >= 2.2),
        isTrue,
        reason: 'Drop should draw heavy vertical fly-lines in art mode',
      );

      // 2. Approaching sandbag above ceiling draws floor target oval + warning marker.
      final bagGame = StageRunner(random: Random(2));
      bagGame.obstacles
        ..clear()
        ..add(
          _obstacle(
            kind: ObstacleKind.sandbag,
            left: StageRunner.runnerX + 0.6,
            width: 0.12,
            bottom: StageRunner.ceiling - 0.02,
            height: 0.14,
            falling: false,
          ),
        );
      final bagCanvas = _SpyCanvas();
      final bagPainter = stagePainterFor(bagGame, null);
      addTearDown(bagPainter.dispose);
      bagPainter.paint(bagCanvas, const Size(800, 500));
      expect(
        bagCanvas.ovals.any((o) => o.$2.color.toARGB32() == 0x66E96131),
        isTrue,
        reason: 'Sandbag telegraphing should draw orange floor target oval',
      );
      expect(
        bagCanvas.paths.any((p) => p.$2.color.toARGB32() == 0xFFE96131),
        isTrue,
        reason: 'Sandbag warning pointer should be drawn below the valance',
      );

      // 3. Rolling drum draws dust puffs without speed lines when falling == true.
      final stillDrum = StageRunner(random: Random(3));
      stillDrum.obstacles
        ..clear()
        ..add(
          _obstacle(
            kind: ObstacleKind.drum,
            left: StageRunner.runnerX + 0.5,
            width: 0.14,
            bottom: StageRunner.floor,
            height: 0.14,
            falling: false,
          ),
        );
      final stillCanvas = _SpyCanvas();
      final stillPainter = stagePainterFor(stillDrum, null);
      addTearDown(stillPainter.dispose);
      stillPainter.paint(stillCanvas, const Size(800, 500));

      final rollingDrum = StageRunner(random: Random(3));
      rollingDrum.obstacles
        ..clear()
        ..add(
          _obstacle(
            kind: ObstacleKind.drum,
            left: StageRunner.runnerX + 0.5,
            width: 0.14,
            bottom: StageRunner.floor,
            height: 0.14,
            falling: true,
          ),
        );
      final rollingCanvas = _SpyCanvas();
      final rollingPainter = stagePainterFor(rollingDrum, null);
      addTearDown(rollingPainter.dispose);
      rollingPainter.paint(rollingCanvas, const Size(800, 500));

      expect(
        rollingCanvas.circles.length,
        greaterThan(stillCanvas.circles.length),
        reason: 'Rolling drum should draw trailing dust puffs',
      );
      expect(
        rollingCanvas.lines.length,
        stillCanvas.lines.length,
        reason: 'Rolling drum should not draw trailing speed lines',
      );
    });
  });

  group('Post-Run-Flow, Garderoben-Tab, Mobile-CTA, Shortcuts und Stand', () {
    testWidgets(
      'RunnerStandCard zeigt Monats- und Allzeit-Rang und routet Kisten/Gage auf onCrates',
      (tester) async {
        var wardrobeTapped = 0;
        var cratesTapped = 0;
        await _pumpApp(
          tester,
          Scaffold(
            body: RunnerStandCard(
              best: 920,
              rank: 8,
              monthRank: 3,
              monthShown: true,
              gage: 640,
              crates: 2,
              onWardrobe: () => wardrobeTapped++,
              onCrates: () => cratesTapped++,
            ),
          ),
        );
        expect(find.text('Platz 3 diesen Monat'), findsOneWidget);
        expect(find.text('Allzeit #8'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('stand-crates')));
        await tester.tap(find.byKey(const ValueKey('stand-gage')));
        expect(cratesTapped, 2);
        expect(wardrobeTapped, 0);
      },
    );

    testWidgets(
      'Mobile-CTA über Fortschritt, Kiste öffnen -> Tab 1, Garderoben-Refresh und R/Enter Shortcuts',
      (tester) async {
        var wardrobeLoads = 0;
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['stageRunner', 'runnerUnlocks', 'runnerMissions'],
        };
        server.override = (req) {
          final p = _path(req);
          if (p.endsWith('/leaderboard')) {
            return Future.value(jsonResponse(_boardJson()));
          }
          if (p.endsWith('/wardrobe')) {
            wardrobeLoads++;
            return Future.value(
              jsonResponse(_wardrobeJson(crates: wardrobeLoads > 1 ? 2 : 0)),
            );
          }
          if (p.endsWith('/missions')) {
            return Future.value(jsonResponse(_missionsJson()));
          }
          if (p.endsWith('/rounds')) {
            return Future.value(jsonResponse({'roundId': 'r-1'}));
          }
          if (p.endsWith('/scores')) {
            return Future.value(
              jsonResponse({
                'improved': true,
                'leaderboard': _boardJson(score: 500, rank: 2),
                'progress': {
                  'meters': 2600,
                  'earned': 3,
                  'opened': 1,
                  'crates': 2,
                  'missionCrates': 0,
                  'newCrates': 1,
                  'previousAt': 2500,
                  'nextAt': 4000,
                  'poolSize': 4,
                  'complete': false,
                  'dupes': true,
                },
              }),
            );
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          StageRunnerScreen(
            controller: controller,
            random: Random(3),
            sound: sound,
            onRun: games.add,
          ),
          size: const Size(400, 820),
        );
        await tester.pumpAndSettle();
        expect(wardrobeLoads, 1);

        // KeyW / ArrowUp must NOT start a run in menu.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(games, isEmpty);

        // KeyR starts a run from the menu.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
        await tester.pump();
        expect(games, hasLength(1));

        await _runUntilFinished(tester);
        await tester.pumpAndSettle();

        // _finish refreshed the wardrobe.
        expect(wardrobeLoads, greaterThanOrEqualTo(2));

        // On narrow screen (< 720), CTA wrap sits ABOVE crate progress.
        final actionsRect = tester.getRect(
          find.byKey(const ValueKey('runner-result-actions')),
        );
        final progressRect = tester.getRect(
          find.byKey(const ValueKey('runner-progress')),
        );
        expect(actionsRect.bottom, lessThanOrEqualTo(progressRect.top));

        // 'Kiste öffnen' CTA opens WardrobeScreen directly on Kisten-Tab (1).
        final openCrate = find.byKey(const ValueKey('runner-result-open-crate'));
        expect(openCrate, findsOneWidget);
        await tester.tap(openCrate);
        await tester.pumpAndSettle();
        final tabs = tester.widget<TabBar>(find.byType(TabBar));
        final tabController =
            tabs.controller ??
            DefaultTabController.of(tester.element(find.byType(TabBar)));
        expect(tabController.index, 1);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'Nach Wertungslauf-Ende bietet _result direkt Training auf derselben Woche',
      (tester) async {
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['stageRunner', 'runnerWeekly'],
        };
        server.override = (req) {
          final p = _path(req);
          if (p.endsWith('/leaderboard')) {
            return Future.value(jsonResponse(_boardJson()));
          }
          if (p.endsWith('/weekly')) {
            return Future.value(jsonResponse(_weeklyJson(used: 1)));
          }
          if (p.endsWith('/rounds')) {
            return Future.value(
              jsonResponse({'roundId': 'w-run', 'attempt': 2}),
            );
          }
          if (p.endsWith('/scores')) {
            return Future.value(
              jsonResponse({
                'improved': false,
                'leaderboard': _boardJson(),
                'weekly': {
                  'ranked': true,
                  'improved': false,
                  'rank': 2,
                  'best': 120,
                  'used': 2,
                  'max': 3,
                },
              }),
            );
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          StageRunnerScreen(
            controller: controller,
            sound: sound,
            onRun: games.add,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('runner-weekly')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('weekly-ranked')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
        await tester.pump();

        await _runUntilFinished(tester);
        await tester.pumpAndSettle();

        final trainBtn = find.byKey(const ValueKey('runner-weekly-train'));
        expect(trainBtn, findsOneWidget);
        await tester.ensureVisible(trainBtn);
        await tester.tap(trainBtn);
        await tester.pump();
        expect(games, hasLength(2));
        expect(find.byKey(const ValueKey('runner-weekly-hud')), findsOneWidget);
        expect(find.textContaining('Training'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'Enter startet fokussierten Vorhang-auf-Button; Garderoben-Button springt bei Kisten auf Tab 1',
      (tester) async {
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['stageRunner', 'runnerUnlocks'],
        };
        server.override = (req) {
          final p = _path(req);
          if (p.endsWith('/leaderboard')) {
            return Future.value(jsonResponse(_boardJson()));
          }
          if (p.endsWith('/wardrobe')) {
            return Future.value(jsonResponse(_wardrobeJson(crates: 2)));
          }
          if (p.endsWith('/rounds')) {
            return Future.value(jsonResponse({'roundId': 'r-enter'}));
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          StageRunnerScreen(
            controller: controller,
            random: Random(5),
            sound: sound,
            onRun: games.add,
          ),
        );
        await tester.pumpAndSettle();

        // WardrobeButton with crates > 0 opens Kisten-Tab (index 1).
        await tester.tap(find.byKey(const ValueKey('runner-wardrobe')));
        await tester.pumpAndSettle();
        final tabs = tester.widget<TabBar>(find.byType(TabBar));
        final tabController =
            tabs.controller ??
            DefaultTabController.of(tester.element(find.byType(TabBar)));
        expect(tabController.index, 1);

        // Return to menu and start via Enter on focused runner-start.
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(games, hasLength(1));

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('In-Run Live-Mission-HUD', () {
    testWidgets(
      'Live-Missions-Pill liegt kollisionsfrei unter dem HUD und priorisiert noPickup',
      (tester) async {
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['stageRunner', 'runnerUnlocks', 'runnerMissions'],
        };
        server.override = (req) {
          final p = _path(req);
          if (p.endsWith('/leaderboard')) {
            return Future.value(jsonResponse(_boardJson()));
          }
          if (p.endsWith('/wardrobe')) {
            return Future.value(jsonResponse(_wardrobeJson()));
          }
          if (p.endsWith('/missions')) {
            return Future.value(jsonResponse(_missionsJson()));
          }
          if (p.endsWith('/rounds')) {
            return Future.value(jsonResponse({'roundId': 'r-m'}));
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          StageRunnerScreen(
            controller: controller,
            sound: sound,
            onRun: games.add,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('runner-start')));
        await tester.pump();
        final game = games.single;
        game.invincible = true;
        await tester.pump(const Duration(milliseconds: 50));

        final liveFinder = find.byKey(const ValueKey('runner-mission-live'));
        expect(liveFinder, findsOneWidget);
        expect(find.textContaining('Ohne Requisite:'), findsOneWidget);

        final hudRect = tester.getRect(find.byKey(const ValueKey('runner-hud')));
        final liveRect = tester.getRect(liveFinder);
        expect(
          liveRect.top,
          greaterThanOrEqualTo(hudRect.bottom - 1),
          reason: 'live mission pill must not overlap score/meters HUD',
        );

        // Collecting a pickup invalidates noPickup and switches to ground mission.
        game.pickups.add(
          _pickup(PickupKind.rose, game.distance + StageRunner.runnerX, game.y),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(game.collected, greaterThan(0));
        expect(find.textContaining('Boden:'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('Offline-Outbox UX und Auto-Sync', () {
    testWidgets(
      'Warteschlangen-Banner, Jetzt senden, Auto-Sync vor Leaderboard und Offline-Hinweis',
      (tester) async {
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['stageRunner'],
        };
        var failScores = true;
        var failRounds = false;
        final callOrder = <String>[];
        server.override = (req) {
          final p = _path(req);
          if (p.endsWith('/leaderboard')) {
            callOrder.add('leaderboard');
            return Future.value(jsonResponse(_boardJson(score: 555, rank: 1)));
          }
          if (p.endsWith('/rounds')) {
            callOrder.add('rounds');
            if (failRounds) {
              return Future.error(http.ClientException('offline'));
            }
            return Future.value(jsonResponse({'roundId': 'r-sync'}));
          }
          if (p.endsWith('/scores')) {
            callOrder.add('scores');
            if (failScores) {
              return Future.error(http.ClientException('offline'));
            }
            return Future.value(
              jsonResponse({
                'improved': true,
                'leaderboard': _boardJson(score: 555, rank: 1),
              }),
            );
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final outbox = runnerScoreOutbox(controller);
        var notified = 0;
        outbox.addListener(() => notified++);

        final sound = _SpySound();
        addTearDown(sound.dispose);
        final games = <StageRunner>[];

        await _pumpApp(
          tester,
          StageRunnerScreen(
            controller: controller,
            random: Random(3),
            sound: sound,
            onRun: games.add,
          ),
        );
        await tester.pumpAndSettle();

        // 1. Run crashes while /scores is offline -> queued + 'Jetzt senden' button.
        await tester.tap(find.byKey(const ValueKey('runner-start')));
        await tester.pump();
        await _runUntilFinished(tester);
        await tester.pumpAndSettle();

        expect(outbox.waiting, 1);
        expect(notified, greaterThan(0));
        expect(
          find.byKey(const ValueKey('runner-outbox-retry')),
          findsOneWidget,
        );

        // Go online and tap 'Jetzt senden' -> delivers and clears retry button.
        failScores = false;
        await tester.tap(find.byKey(const ValueKey('runner-outbox-retry')));
        await tester.pumpAndSettle();
        expect(outbox.waiting, 0);
        expect(outbox.lastResult, isNotNull);
        expect(find.byKey(const ValueKey('runner-outbox-retry')), findsNothing);

        // 2. Queue another score offline, reopen screen -> initState retries BEFORE leaderboard.
        failScores = true;
        final queuedScore = RunScore(
          round: Future.value('r-queued'),
          score: 300,
          meters: 250,
        );
        await expectLater(outbox.send(queuedScore), throwsA(anything));
        expect(outbox.waiting, 1);

        // Keep offline first so intro shows banner.
        await tester.pumpWidget(const SizedBox());
        callOrder.clear();
        await _pumpApp(
          tester,
          StageRunnerScreen(
            controller: controller,
            random: Random(3),
            sound: sound,
            onRun: games.add,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          callOrder.indexOf('scores'),
          lessThan(callOrder.indexOf('leaderboard')),
          reason: 'initState should flush outbox before loading leaderboard',
        );
        expect(
          find.byKey(const ValueKey('runner-outbox-banner')),
          findsOneWidget,
        );

        // Go online and tap banner's 'Jetzt senden'.
        failScores = false;
        await tester.tap(find.byKey(const ValueKey('runner-outbox-retry')));
        await tester.pumpAndSettle();
        expect(outbox.waiting, 0);
        expect(
          find.byKey(const ValueKey('runner-outbox-banner')),
          findsNothing,
        );

        // 3. App returning to foreground (onShow) automatically flushes outbox.
        failScores = true;
        await expectLater(
          outbox.send(
            RunScore(round: Future.value('r-fg'), score: 220, meters: 190),
          ),
          throwsA(anything),
        );
        expect(outbox.waiting, 1);
        failScores = false;
        tester.binding
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
          ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
          ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(outbox.waiting, 0);

        // 4. Offline startRound shows subtle runner-offline-warning during run.
        failRounds = true;
        await tester.tap(find.byKey(const ValueKey('runner-start')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(const ValueKey('runner-offline-warning')),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('Audio-Bedienung, Ghost-Crash-Marker und System-Reduced-Motion', () {
    testWidgets(
      'RunnerVolumeSettings: Direkt-Mute, Fremdmusik-Hinweis und Menü-Musik-Vorschau ohne Effekt-Musik-Resume',
      (tester) async {
        final controller = await _demoController();
        final sound = _SpySound();
        addTearDown(sound.dispose);
        sound.setOtherMusic(true);

        await _pumpApp(
          tester,
          StageRunnerScreen(controller: controller, sound: sound),
        );
        await tester.tap(find.byKey(const ValueKey('runner-settings')));
        await tester.pumpAndSettle();

        expect(sound.events, contains('refreshOther'));
        expect(
          find.byKey(const ValueKey('runner-volume-enabled')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('runner-volume-other-music')),
          findsOneWidget,
        );

        // Dragging Effects slider must NOT start menu music preview.
        sound.events.clear();
        await tester.drag(
          find.byKey(const ValueKey('runner-volume-effects')),
          const Offset(-120, 0),
        );
        await tester.pump();
        expect(sound.events, isNot(contains('startPreview')));
        expect(sound.events, isNot(contains('resumeMusic')));

        // Dragging Music slider starts menu preview; closing dialog stops it.
        await tester.drag(
          find.byKey(const ValueKey('runner-volume-music')),
          const Offset(-120, 0),
        );
        await tester.pump();
        expect(sound.events, contains('startPreview'));

        // Direct mute switch toggles sound.enabled and hides Fremdmusik-Hinweis.
        await tester.tap(find.byKey(const ValueKey('runner-volume-enabled')));
        await tester.pump();
        expect(sound.enabled.value, isFalse);
        expect(
          find.byKey(const ValueKey('runner-volume-other-music')),
          findsNothing,
        );

        await tester.tap(find.text('Fertig'));
        await tester.pumpAndSettle();
        expect(sound.events, contains('stopPreview'));
        expect(sound.previewing, isFalse);

        // Clear any pending effect preview cooldown timer.
        await tester.pump(RunnerVolumeSettings.previewGap);
        await tester.pumpWidget(const SizedBox());
      },
    );

    test(
      'WebRunnerSound respektiert _hidden bei startMusic und weckt AudioContext in resumeMusic',
      () async {
        SharedPreferences.setMockInitialValues({});
        final audio = _FakeWebAudio();
        final sound = WebRunnerSound(
          open: () => audio,
          bundle: _FakeBundle(),
        );
        addTearDown(sound.dispose);
        await runnerSoundSettingsReady(sound);

        // Prepare within user gesture so AudioContext opens and music decodes.
        sound.prepare();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Hidden tab: startMusic must not start a loop.
        sound.pauseMusic();
        audio.log.clear();
        sound.startMusic();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(audio.log, isNot(contains('playLoop:music')));

        // Returning visible starts the wanted loop; subsequent resumeMusic
        // still calls audio.resume() (Safari interruption recovery).
        sound.resumeMusic();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(audio.log, contains('playLoop:music'));

        audio.log.clear();
        sound.resumeMusic();
        expect(audio.log, contains('resume'));
      },
    );

    test('Ghost-Crash-Marker heben Top-3 & eigenen Geist mit Label hervor', () {
      final top = RunnerGhost(
        personId: 7,
        name: 'Lena',
        rank: 1,
        score: 900,
        meters: 800,
        hz: ghostHz,
        samples: Uint8List.fromList([120, 120]),
        crashed: true,
      );
      final own = RunnerGhost(
        personId: 3,
        name: 'Ich',
        rank: 5,
        score: 300,
        meters: 250,
        hz: ghostHz,
        samples: Uint8List.fromList([120, 120]),
        crashed: true,
        me: true,
      );
      expect(top.highlightCrash, isTrue);
      expect(top.crashTag, '1. Lena');
      expect(own.highlightCrash, isTrue);
      expect(own.crashTag, 'Du');

      final game = StageRunner(random: Random(1))..invincible = true;
      for (var i = 0; i < 6; i++) {
        game.update(0.05);
      }
      final ghosts = RunnerGhosts([top, own], mode: GhostMode.all, ownRank: 5);
      final canvas = _SpyCanvas();
      final painter = stagePainterFor(game, null, ghosts: ghosts);
      addTearDown(painter.dispose);
      painter.paint(canvas, const Size(800, 500));

      // Gold (0xCCF2C45A) for rank 1 and orange (0xDDE96131) for own crash mark.
      expect(
        canvas.lines.any((l) => l.$3.color.toARGB32() == 0xCCF2C45A),
        isTrue,
      );
      expect(
        canvas.lines.any((l) => l.$3.color.toARGB32() == 0xDDE96131),
        isTrue,
      );
      expect(canvas.paragraphs, isNotEmpty);
    });

    testWidgets(
      'System Reduced Motion beruhigt Pickup-Bobbing, Partikel und MissionBanner-Animation',
      (tester) async {
        // 1. Pickup bobbing stopped when reducedMotion == true.
        final game = StageRunner(random: Random(1));
        game.obstacles.clear();
        game.pickups
          ..clear()
          ..add(_pickup(PickupKind.rose, StageRunner.runnerX + 0.5, 0.5));
        final c1 = _SpyCanvas(), c2 = _SpyCanvas();
        final p1 = stagePainterFor(game, null, reducedMotion: true);
        addTearDown(p1.dispose);
        p1.paint(c1, const Size(800, 500));
        game.time = 1.25;
        p1.paint(c2, const Size(800, 500));
        expect(c1.circles.first.$1.dy, closeTo(c2.circles.first.$1.dy, 1e-6));

        // 2. Burst particles skipped when reducedMotion == true.
        final fx = RunnerFx();
        fx.pickup(PickupKind.rose, 0.5, 0.5);
        final cFull = _SpyCanvas(), cReduced = _SpyCanvas();
        final pFull = stagePainterFor(game, null, fx: fx, reducedMotion: false);
        final pRed = stagePainterFor(game, null, fx: fx, reducedMotion: true);
        addTearDown(pFull.dispose);
        addTearDown(pRed.dispose);
        pFull.paint(cFull, const Size(800, 500));
        pRed.paint(cReduced, const Size(800, 500));
        expect(cReduced.circles.length, lessThan(cFull.circles.length));

        // 3. Mission HUD AnimatedSwitcher uses Duration.zero under disableAnimations.
        final server = TestServer();
        server.data['capabilities'] = {
          'features': ['stageRunner', 'runnerUnlocks', 'runnerMissions'],
        };
        server.override = (req) {
          final p = _path(req);
          if (p.endsWith('/leaderboard')) {
            return Future.value(jsonResponse(_boardJson()));
          }
          if (p.endsWith('/wardrobe')) {
            return Future.value(jsonResponse(_wardrobeJson()));
          }
          if (p.endsWith('/missions')) {
            return Future.value(jsonResponse(_missionsJson()));
          }
          if (p.endsWith('/rounds')) {
            return Future.value(jsonResponse({'roundId': 'r-rm'}));
          }
          return null;
        };
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final sound = _SpySound();
        addTearDown(sound.dispose);

        await _pumpApp(
          tester,
          StageRunnerScreen(controller: controller, sound: sound),
          disableAnimations: true,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('runner-start')));
        await tester.pump();
        final switcher = tester.widget<AnimatedSwitcher>(
          find.byType(AnimatedSwitcher),
        );
        expect(switcher.duration, Duration.zero);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
