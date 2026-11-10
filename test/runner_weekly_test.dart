import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/runner_menu_preferences.dart';
import 'package:theater_app/features/games/data/weekly_api.dart';
import 'package:theater_app/features/games/domain/runner_ghost.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/runner_menu.dart';
import 'package:theater_app/features/games/ui/runner_news.dart';
import 'package:theater_app/features/games/ui/runner_weekly.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_ghosts.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart'
    show WardrobePictures;
import 'package:theater_app/features/games/ui/stage_runner_screen.dart'
    show stageLayout;
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

class _QuietSound implements RunnerSound {
  final _enabled = ValueNotifier(false);
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  void prepare() {}
  final played = <RunnerSfx>[];
  @override
  void play(RunnerSfx sfx) => played.add(sfx);
  @override
  void startMusic() {}
  @override
  void stopMusic() {}
  @override
  void dispose() => _enabled.dispose();
}

const _seed = 3141592653;

/// Counts what the stage draws of the ghosts: the ghosts themselves (as
/// silhouettes or in their figures), the crosses where they crashed and
/// the name tags (texts ending left of the own figure, at [runnerX]).
class _GhostCanvas implements Canvas {
  _GhostCanvas(this.runnerX);
  final double runnerX;
  int ghosts = 0, marks = 0, tags = 0;

  @override
  void drawPath(Path path, Paint paint) {
    final c = paint.color;
    if (c.a > 0 && (c.toARGB32() & 0xFFFFFF) == 0xDCE6F0) ghosts++;
  }

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    final c = paint.color;
    if (c.a > 0 && c.a <= .26 && (c.toARGB32() & 0xFFFFFF) == 0) ghosts++;
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    if (paint.color.toARGB32() == 0x40DCE6F0) marks++;
  }

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    if (offset.dx + paragraph.longestLine <= runnerX) tags++;
  }

  @override
  int getSaveCount() => 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// What the stage of the running game draws of the ghosts right now.
({int ghosts, int marks, int tags}) _ghostsDrawn(WidgetTester tester) {
  final stage = find.byKey(const ValueKey('runner-stage'));
  final size = tester.getSize(stage);
  final canvas = _GhostCanvas(StageRunner.runnerX * stageLayout(size).s);
  tester.widget<CustomPaint>(stage).painter!.paint(canvas, size);
  return (ghosts: canvas.ghosts, marks: canvas.marks, tags: canvas.tags);
}

ui.Image _picture(int width, int height) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF808080),
  );
  return recorder.endRecording().toImageSync(width, height);
}

/// The test clock's week (`fixedNow` is Saturday, 12 September 2026).
const _week = '2026-W37';
const _startsAt = '2026-09-06T22:00:00.000Z',
    _endsAt = '2026-09-13T22:00:00.000Z';

JsonMap _row(int rank, int person, String name, int score, {bool me = false}) =>
    {
      'rank': rank,
      'personId': person,
      'name': name,
      'score': score,
      'meters': score - 20,
      'at': '2026-09-10T18:00:00.000Z',
      'me': me,
    };

/// A ghost resting on the floor for [seconds], then crashed.
JsonMap _ghost(int rank, int person, String name, int score, double seconds) =>
    {
      'personId': person,
      'name': name,
      'rank': rank,
      'score': score,
      'meters': RunnerRules.maxMeters(seconds).floor(),
      'hz': ghostHz,
      'y': base64Encode(
        Uint8List((seconds * ghostHz).floor() + 1)..fillRange(
          0,
          (seconds * ghostHz).floor() + 1,
          ghostByte(StageRunner.floor - StageRunner.runnerHeight / 2),
        ),
      ),
      'crashed': true,
    };

/// The Wochenprobe on a test server: its week, the calls and their bodies.
class _Weekly {
  _Weekly({this.used = 1, this.lastWeek, this.figures = false});
  int used;
  JsonMap? lastWeek;

  /// Whether every ghost names a figure of its own to load.
  final bool figures;
  bool offline = false, startOffline = false, scoresRejected = false;

  /// The ranked start counts on the server, but its answer never comes.
  bool startLost = false;

  /// Holds the answer to a ranked start until completed.
  Completer<void>? hold;
  final calls = <String>[];
  final bodies = <String, List<JsonMap>>{};

  JsonMap week() => {
    'week': _week,
    'seed': _seed,
    'startsAt': _startsAt,
    'endsAt': _endsAt,
    'attempts': {'used': used, 'max': 3},
    'best': used > 1 ? {'score': 120, 'meters': 100} : null,
    'leaderboard': [
      _row(1, 7, 'Lena', 900),
      if (used > 1) _row(2, 3, 'Testmitglied', 120, me: true),
      _row(used > 1 ? 3 : 2, 8, 'Jonas', 80),
    ],
    'ghosts': [
      for (final ghost in [
        _ghost(1, 7, 'Lena', 900, 40),
        _ghost(3, 8, 'Jonas', 80, 3),
        for (var i = 0; i < 12; i++)
          _ghost(4 + i, 20 + i, 'P$i', 50, 2 + i * .5),
      ])
        {
          ...ghost,
          if (figures)
            'character': {
              'id': 'character.p${ghost['personId']}',
              'image':
                  '/games/runner/skins/character-p${ghost['personId']}.webp?v=1',
            },
        },
    ],
    'lastWeek': lastWeek,
  };

  Future<http.Response>? handle(http.Request request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (!path.contains('/games/runner/')) return null;
    final name = '${request.method} ${path.split('/games/runner/').last}';
    calls.add(name);
    final body = request.body.isEmpty
        ? const <String, Object?>{}
        : jsonMap(jsonDecode(request.body));
    (bodies[name] ??= []).add(body);
    switch (name) {
      case 'GET weekly':
        if (offline) return Future.error(http.ClientException('offline'));
        return Future.value(jsonResponse(week()));
      case 'PUT weekly/seen':
        lastWeek = null;
        return Future.value(jsonResponse({'ok': true}));
      case 'GET leaderboard':
        return Future.value(
          jsonResponse({'players': 0, 'top': <JsonMap>[], 'own': null}),
        );
      case 'POST rounds':
        final weekly = body['weekly'];
        if (weekly is! Map) {
          return Future.value(jsonResponse({'roundId': 'r-free'}));
        }
        final ranked = weekly['ranked'] == true;
        if (ranked && startOffline) {
          return Future.error(http.ClientException('offline'));
        }
        if (ranked && used >= 3) {
          return Future.value(
            jsonResponse({
              'error': 'Alle Versuche genutzt',
              'code': 'attempts_used',
            }, 409),
          );
        }
        if (ranked) used++;
        if (ranked && startLost) {
          return Future.error(TimeoutException('lost'));
        }
        final answer = Future.value(
          jsonResponse({
            'roundId': ranked ? 'w-$used' : 't-1',
            'startedAt': '2026-09-12T10:00:00.000Z',
            'weekly': {
              'week': _week,
              'seed': _seed,
              'ranked': ranked,
              'attempt': ranked ? used : 0,
            },
          }),
        );
        if (ranked && hold != null) return hold!.future.then((_) => answer);
        return answer;
      case 'POST scores':
        if (scoresRejected) {
          return Future.value(
            jsonResponse({'error': 'Passt nicht', 'code': 'implausible'}, 400),
          );
        }
        final ranked = body['ghost'] != null;
        return Future.value(
          jsonResponse({
            'improved': false,
            'leaderboard': {'players': 0, 'top': <JsonMap>[], 'own': null},
            'weekly': {
              'improved': ranked,
              'best': {'score': 150, 'meters': 130},
              'rank': 2,
              'attempts': {'used': used, 'max': 3},
            },
          }),
        );
    }
    return Future.value(jsonResponse({'error': 'not found'}, 404));
  }
}

Future<AppController> _controller(
  _Weekly weekly, {
  List<String> features = const ['stageRunner', 'runnerWeekly'],
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = weekly.handle;
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

void _size(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The weekly page under a page that keeps what it hands over.
Future<List<WeeklyPlay?>> _openWeekly(
  WidgetTester tester,
  AppController controller,
) async {
  _size(tester);
  final handed = <WeeklyPlay?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async =>
                  handed.add(await openRunnerWeekly(context, controller)),
              child: const Text('öffnen'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('öffnen'));
  await tester.pumpAndSettle();
  return handed;
}

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed !=
    null;

Future<void> _tapKey(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('texts', () {
    test('the week, its countdown and the attempts', () {
      final starts = DateTime.parse(_startsAt), ends = DateTime.parse(_endsAt);
      expect(
        weeklyHeadline(_week, starts, ends),
        'Woche 37 · 7.–13. September',
      );
      expect(
        weeklyHeadline(
          '2026-W49',
          DateTime.parse('2026-11-29T23:00:00Z'),
          DateTime.parse('2026-12-06T23:00:00Z'),
        ),
        'Woche 49 · 30. November – 6. Dezember',
      );
      expect(
        weeklyCountdown(ends, DateTime.parse('2026-09-11T17:00:00Z')),
        'Neue Strecke in 2 Tagen 5 Std.',
      );
      expect(
        weeklyCountdown(ends, DateTime.parse('2026-09-12T21:30:00Z')),
        'Neue Strecke in 1 Tag',
      );
      expect(
        weeklyCountdown(ends, DateTime.parse('2026-09-13T19:15:00Z')),
        'Neue Strecke in 2 Std. 45 Min.',
      );
      expect(
        weeklyCountdown(ends, DateTime.parse('2026-09-13T22:00:00Z')),
        'Die neue Strecke ist da',
      );
      expect(weeklyAttemptsText(0, 3), 'Versuch 1 von 3');
      expect(weeklyAttemptsText(2, 3), 'Versuch 3 von 3');
      expect(weeklyAttemptsText(3, 3), 'Alle 3 Versuche genutzt');
      expect(weeklyRewardText(2, 40), 'Letzte Woche: Platz 2 · +40 Gage');
      expect(weeklyRewardText(9, 0), 'Letzte Woche: Platz 9');
    });

    test('the server’s answers are read as agreed', () {
      final week = WeeklyChallenge.fromJson(_Weekly(used: 2).week(), me: 3);
      expect(week.week, _week);
      expect(week.seed, _seed);
      expect(week.left, 1);
      expect(week.best!.score, 120);
      expect(week.own!.rank, 2);
      expect(week.ghosts, hasLength(14));
      expect(week.ghosts.where((g) => g.me), isEmpty);
      expect(week.lastWeek, isNull);
      final cached = WeeklyChallenge.fromCache(week.toCache());
      expect((cached.week, cached.seed, cached.cached), (_week, _seed, true));
      expect(cached.endsAt, DateTime.parse(_endsAt));
      final result = WeeklyRunResult.fromJson({
        'improved': true,
        'best': {'score': 150, 'meters': 130},
        'rank': 2,
        'attempts': {'used': 2, 'max': 3},
      });
      expect(
        (result.improved, result.best!.score, result.rank, result.used),
        (true, 150, 2, 2),
      );
    });
  });

  group('weekly page', () {
    testWidgets('with attempts left: the week, the ranking and both runs', (
      tester,
    ) async {
      final weekly = _Weekly(used: 1);
      final controller = await _controller(weekly);
      await _openWeekly(tester, controller);
      expect(find.text('Woche 37 · 7.–13. September'), findsOneWidget);
      expect(find.byKey(const ValueKey('weekly-countdown')), findsOneWidget);
      expect(find.text('Versuch 2 von 3'), findsOneWidget);
      expect(
        find.text('Ein Versuch zählt, sobald der Lauf startet.'),
        findsOneWidget,
      );
      expect(_enabled(tester, 'weekly-ranked'), isTrue);
      expect(_enabled(tester, 'weekly-training'), isTrue);
      expect(find.text('Lena'), findsOneWidget);
      expect(find.text('Jonas'), findsOneWidget);
      expect(find.byKey(const ValueKey('weekly-reward')), findsNothing);
      expect(weekly.calls, isNot(contains('PUT weekly/seen')));
    });

    testWidgets('a ranked run asks first, then starts on the server', (
      tester,
    ) async {
      final weekly = _Weekly(used: 1);
      final controller = await _controller(weekly);
      final handed = await _openWeekly(tester, controller);
      await _tapKey(tester, 'weekly-ranked');
      expect(find.text('Wertungslauf starten?'), findsOneWidget);
      expect(find.textContaining('Versuch 2 von 3'), findsWidgets);
      // Changing one's mind costs nothing.
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(weekly.calls, isNot(contains('POST rounds')));
      await _tapKey(tester, 'weekly-ranked');
      await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
      await tester.pumpAndSettle();
      expect(weekly.bodies['POST rounds'], [
        {
          'weekly': {'week': _week, 'ranked': true},
          // Its place among this app session's starts.
          'order': {'client': isA<String>(), 'seq': isA<int>()},
        },
      ]);
      final play = handed.single!;
      expect(play.ranked, isTrue);
      expect(play.seed, _seed);
      expect(play.attempt, 2);
      expect(play.start!.roundId, 'w-2');
    });

    testWidgets('with every attempt used only training is left', (
      tester,
    ) async {
      final weekly = _Weekly(used: 3);
      final controller = await _controller(weekly);
      final handed = await _openWeekly(tester, controller);
      expect(find.text('Alle 3 Versuche genutzt'), findsOneWidget);
      expect(_enabled(tester, 'weekly-ranked'), isFalse);
      expect(
        find.text('Nächste Woche gibt es neue Versuche. Training geht weiter.'),
        findsOneWidget,
      );
      expect(
        find.text('Dein Wochenbestwert: 120 Punkte · Platz 2'),
        findsOneWidget,
      );
      // "Geister: Wenige" until another is chosen, kept on this device:
      // "Aus / Wenige / Alle".
      expect(find.text(GhostModeChoice.note(GhostMode.few)), findsOneWidget);
      expect(
        [
          for (final m in GhostMode.values)
            tester.widget<Text>(find.byKey(ValueKey('ghosts-${m.name}'))).data,
        ],
        ['Aus', 'Wenige', 'Alle'],
      );
      await _tapKey(tester, 'ghosts-off');
      expect(find.text(GhostModeChoice.note(GhostMode.off)), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          RunnerMenuPreferences.ghostModeKey,
        ),
        'off',
      );
      await _tapKey(tester, 'ghosts-all');
      expect(find.text(GhostModeChoice.note(GhostMode.all)), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          RunnerMenuPreferences.ghostModeKey,
        ),
        'all',
      );
      await _tapKey(tester, 'weekly-training');
      final play = handed.single!;
      expect((play.ranked, play.seed), (false, _seed));
      // Training starts no attempt here.
      expect(weekly.calls, isNot(contains('POST rounds')));
    });

    testWidgets('a used-up week found at the start says so', (tester) async {
      final weekly = _Weekly(used: 2);
      final controller = await _controller(weekly);
      final handed = await _openWeekly(tester, controller);
      // Meanwhile the last attempt was started on another device.
      weekly.used = 3;
      await _tapKey(tester, 'weekly-ranked');
      await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
      await tester.pumpAndSettle();
      expect(
        find.text('Alle Versuche dieser Woche sind schon genutzt.'),
        findsOneWidget,
      );
      expect(handed, isEmpty);
      // The page shows the week anew.
      expect(weekly.calls.where((c) => c == 'GET weekly'), hasLength(2));
      expect(find.text('Alle 3 Versuche genutzt'), findsOneWidget);
    });

    testWidgets('without a connection no ranked run starts', (tester) async {
      final weekly = _Weekly(used: 0)..startOffline = true;
      final controller = await _controller(weekly);
      final handed = await _openWeekly(tester, controller);
      await _tapKey(tester, 'weekly-ranked');
      await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
      await tester.pumpAndSettle();
      // It may have reached the server: the attempts as it counted them.
      expect(find.text(weeklyNoAnswerText), findsOneWidget);
      expect(weekly.calls.where((c) => c == 'GET weekly'), hasLength(2));
      expect(handed, isEmpty);
    });

    testWidgets('a start without an answer may have counted: the attempts '
        'are loaded anew', (tester) async {
      final weekly = _Weekly(used: 1)..startLost = true;
      final controller = await _controller(weekly);
      final handed = await _openWeekly(tester, controller);
      expect(find.text(weeklyAttemptsText(1, 3)), findsOneWidget);
      await _tapKey(tester, 'weekly-ranked');
      await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
      await tester.pumpAndSettle();
      expect(find.text(weeklyNoAnswerText), findsOneWidget);
      expect(find.text(weeklyAttemptsText(2, 3)), findsOneWidget);
      expect(handed, isEmpty);
      // The next confirmation asks for the attempt the server will give.
      await _tapKey(tester, 'weekly-ranked');
      expect(find.textContaining('Versuch 3 von 3'), findsWidgets);
    });

    testWidgets('while a ranked start is on its way the page stays', (
      tester,
    ) async {
      final weekly = _Weekly(used: 1)..hold = Completer<void>();
      final controller = await _controller(weekly);
      final handed = await _openWeekly(tester, controller);
      await _tapKey(tester, 'weekly-ranked');
      await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_enabled(tester, 'weekly-training'), isFalse);
      expect(_enabled(tester, 'weekly-ranked'), isFalse);
      // Neither the system's back nor the app bar's leaves it.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pageBack();
      await tester.pump();
      expect(find.byKey(const ValueKey('weekly-course')), findsOneWidget);
      expect(handed, isEmpty);
      // The counted attempt is played.
      weekly.hold!.complete();
      await tester.pumpAndSettle();
      expect(handed.single?.start?.roundId, 'w-2');
    });

    testWidgets('offline, training runs on the course kept from before', (
      tester,
    ) async {
      final weekly = _Weekly(used: 1);
      final controller = await _controller(weekly);
      // A first visit keeps the course.
      final handed = await _openWeekly(tester, controller);
      expect(
        jsonDecode(
          (await SharedPreferences.getInstance()).getString(
            WeeklyCourseCache.key,
          )!,
        ),
        containsPair('seed', _seed),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      weekly.offline = true;
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weekly-offline')), findsOneWidget);
      expect(_enabled(tester, 'weekly-ranked'), isFalse);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('weekly-ranked-note')))
            .data,
        weeklyOfflineText,
      );
      expect(find.text('Lena'), findsNothing);
      await _tapKey(tester, 'weekly-training');
      final play = handed.last!;
      expect((play.ranked, play.seed), (false, _seed));
      expect(play.challenge.ghosts, isEmpty);
    });

    testWidgets('offline without a kept course it can only try again', (
      tester,
    ) async {
      final weekly = _Weekly()..offline = true;
      final controller = await _controller(weekly);
      await _openWeekly(tester, controller);
      expect(find.byKey(const ValueKey('weekly-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('weekly-training')), findsNothing);
      weekly.offline = false;
      await tester.tap(find.text('Erneut laden'));
      await tester.pumpAndSettle();
      expect(find.text('Versuch 2 von 3'), findsOneWidget);
    });

    testWidgets('last week’s reward shows once', (tester) async {
      final weekly = _Weekly(
        used: 0,
        lastWeek: {'week': '2026-W36', 'rank': 2, 'score': 640, 'gage': 40},
      );
      final controller = await _controller(weekly);
      await _openWeekly(tester, controller);
      expect(find.text('Letzte Woche: Platz 2 · +40 Gage'), findsOneWidget);
      expect(weekly.bodies['PUT weekly/seen'], [
        {'week': '2026-W36'},
      ]);
      // Closed, it stays away; the server leaves it out from now on.
      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weekly-reward')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weekly-reward')), findsNothing);
      expect(weekly.calls.where((c) => c == 'PUT weekly/seen'), hasLength(1));
    });
  });

  group('in the game', () {
    // "Neu im Bühnenlauf" was read already; runner_news_test.dart has it.
    setUp(
      () => SharedPreferences.setMockInitialValues({
        RunnerMenuPreferences.newsSeenKey: [for (final n in runnerNews) n.id],
      }),
    );

    Future<List<StageRunner>> pumpGame(
      WidgetTester tester,
      AppController controller, {
      _QuietSound? sound,
    }) async {
      _size(tester);
      final games = <StageRunner>[];
      final quiet = sound ?? _QuietSound();
      addTearDown(quiet.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: StageRunnerScreen(
            controller: controller,
            sound: quiet,
            onRun: games.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return games;
    }

    Future<void> untilCurtain(WidgetTester tester) async {
      for (
        var i = 0;
        i < 60 * 20 && find.text('Der Vorhang fällt!').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('the menu leads there only where the server has it', (
      tester,
    ) async {
      final controller = await _controller(
        _Weekly(),
        features: const ['stageRunner'],
      );
      await pumpGame(tester, controller);
      expect(find.byKey(const ValueKey('runner-weekly')), findsNothing);
    });

    testWidgets('a ranked run plays this week’s course with the ghosts and '
        'is sent with its own', (tester) async {
      final weekly = _Weekly(used: 1);
      final controller = await _controller(weekly);
      final games = await pumpGame(tester, controller);
      final card = find.byKey(const ValueKey('runner-weekly'));
      expect(
        find.descendant(of: card, matching: find.textContaining('Versuch 2')),
        findsOneWidget,
      );
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      await _tapKey(tester, 'weekly-ranked');
      await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final game = games.single;
      expect(game.seed, _seed);
      expect(
        find.textContaining('Wertungslauf · Versuch 2/3 · Lena: noch'),
        findsOneWidget,
      );
      await untilCurtain(tester);
      expect(tester.takeException(), isNull);
      expect(game.over, isTrue);

      // Only the ranked start; the score goes with the ghost.
      expect(weekly.bodies['POST rounds'], hasLength(1));
      final sent = weekly.bodies['POST scores']!.single;
      expect(sent['roundId'], 'w-2');
      expect(sent['score'], game.score);
      expect(sent['course'], StageRunner.courseVersion);
      final ghost = base64Decode(sent['ghost'] as String);
      // The samples up to the crash (within half a sample) and its flag.
      expect(ghost.length, (game.time * ghostHz).round() + 2);
      expect(ghost.first, ghostByte(StageRunner.floor - .055));
      expect(ghost.last, 1);

      expect(find.text('Wertungslauf · Versuch 2 von 3'), findsOneWidget);
      expect(find.text('Neuer Wochenbestwert!'), findsOneWidget);
      expect(
        find.text('Dein Wochenbestwert: 150 Punkte · Platz 2'),
        findsOneWidget,
      );
      expect(find.text('Noch 1 Versuch diese Woche'), findsOneWidget);
      expect(find.text('Nochmal'), findsNothing);
      // Another attempt only through the page, which asks again.
      await _tapKey(tester, 'runner-to-weekly');
      expect(find.text('Versuch 3 von 3'), findsOneWidget);
    });

    testWidgets('training starts its own round, without a ghost, as often as '
        'one likes', (tester) async {
      final weekly = _Weekly(used: 3);
      final controller = await _controller(weekly);
      final games = await pumpGame(tester, controller);
      await _tapKey(tester, 'runner-weekly');
      await tester.ensureVisible(find.byKey(const ValueKey('weekly-training')));
      await tester.tap(find.byKey(const ValueKey('weekly-training')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(games.single.seed, _seed);
      expect(find.textContaining('Training · Lena: noch'), findsOneWidget);
      await untilCurtain(tester);
      expect(weekly.bodies['POST rounds'], [
        {
          'weekly': {'week': _week, 'ranked': false},
          // Its place among this app session's starts.
          'order': {'client': isA<String>(), 'seq': isA<int>()},
        },
      ]);
      final sent = weekly.bodies['POST scores']!.single;
      expect(sent.containsKey('ghost'), isFalse);
      expect(sent['roundId'], 't-1');
      expect(find.text('Training · Wochenprobe'), findsOneWidget);
      expect(
        find.text('Training zählt nicht für die Wochenwertung.'),
        findsOneWidget,
      );
      expect(find.text('Neuer Wochenbestwert!'), findsNothing);

      await _tapKey(tester, 'runner-train-again');
      expect(games, hasLength(2));
      expect(games.last.seed, _seed);
      await untilCurtain(tester);
      expect(weekly.bodies['POST rounds'], hasLength(2));

      // A free run is a normal one again, on a course of its own.
      await _tapKey(tester, 'runner-free-run');
      expect(games, hasLength(3));
      expect(find.byKey(const ValueKey('runner-weekly-hud')), findsNothing);
      expect(weekly.bodies['POST rounds']!.last.keys, ['order']);
    });

    /// Starts a training run from the menu.
    Future<void> train(WidgetTester tester) async {
      await _tapKey(tester, 'runner-weekly');
      await tester.ensureVisible(find.byKey(const ValueKey('weekly-training')));
      await tester.tap(find.byKey(const ValueKey('weekly-training')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('a run that loses the app waits for a tap', (tester) async {
      final weekly = _Weekly(used: 1);
      final controller = await _controller(weekly);
      final games = await pumpGame(tester, controller);
      await train(tester);
      final game = games.single;
      for (var i = 0; i < 40 && game.time < .5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(game.time, greaterThan(0));
      // Control Center or a call: the run stops at once.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);
      final time = game.time;
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Back, it still waits.
      expect(game.time, time);
      expect(find.byKey(const ValueKey('runner-paused')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('runner-paused')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('runner-paused')), findsNothing);
      expect(game.time, greaterThan(time));
    });

    testWidgets('a training run breaks no record', (tester) async {
      // The own weekly best is 120 points.
      final weekly = _Weekly(used: 2);
      final controller = await _controller(weekly);
      final sound = _QuietSound();
      final games = await pumpGame(tester, controller, sound: sound);
      Future<void> past(StageRunner game, int score) async {
        game.invincible = true;
        for (var i = 0; i < 60 * 20 && game.score <= score; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(game.score, greaterThan(score));
      }

      await train(tester);
      await past(games.single, 150);
      expect(sound.played, isNot(contains(RunnerSfx.record)));
    });

    group('with the ghosts off', () {
      setUp(() {
        GhostSkins.reset();
        WardrobePictures.clear();
        // The game's pictures, so ghost figures would load at once.
        RunnerArt.useForTest(RunnerArt.test(_picture(8, 8), _picture(8, 8)));
      });
      tearDown(() => RunnerArt.useForTest(null));

      /// Runs on until [game] is [seconds] in, without crashing.
      Future<void> until(
        WidgetTester tester,
        StageRunner game,
        double seconds,
      ) async {
        game.invincible = true;
        for (var i = 0; i < 400 && game.time < seconds; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(game.time, greaterThanOrEqualTo(seconds));
      }

      bool loadedFigures(_Weekly weekly) =>
          weekly.calls.any((c) => c.startsWith('GET skins/'));

      testWidgets('a ranked run shows no ghost, no cross and no name, loads '
          'no figure and still sends its own ghost', (tester) async {
        SharedPreferences.setMockInitialValues({
          RunnerMenuPreferences.newsSeenKey: [for (final n in runnerNews) n.id],
          RunnerMenuPreferences.ghostModeKey: 'off',
        });
        final weekly = _Weekly(used: 1, figures: true);
        final controller = await _controller(weekly);
        final games = await pumpGame(tester, controller);
        await _tapKey(tester, 'runner-weekly');
        // The page shows the choice as it was left.
        expect(find.text(GhostModeChoice.note(GhostMode.off)), findsOneWidget);
        await _tapKey(tester, 'weekly-ranked');
        await tester.tap(find.byKey(const ValueKey('weekly-confirm-start')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final game = games.single;
        expect(game.time, lessThan(ghostNamesFor));
        // At the start the names would show, later the crosses.
        expect(_ghostsDrawn(tester), (ghosts: 0, marks: 0, tags: 0));
        await until(tester, game, 6);
        expect(_ghostsDrawn(tester), (ghosts: 0, marks: 0, tags: 0));
        expect(GhostSkins.asked, 0);
        expect(loadedFigures(weekly), isFalse);

        game.invincible = false;
        await untilCurtain(tester);
        expect(game.over, isTrue);
        final sent = weekly.bodies['POST scores']!.single;
        expect(sent['roundId'], 'w-2');
        expect(sent['ghost'], isA<String>());
        expect(loadedFigures(weekly), isFalse);
      });

      testWidgets('changed in the pause of a training run, the choice holds '
          'at once, and is kept', (tester) async {
        final weekly = _Weekly(used: 3, figures: true);
        final controller = await _controller(weekly);
        final games = await pumpGame(tester, controller);
        await train(tester);
        final game = games.single;
        await until(tester, game, .5);

        Future<void> choose(GhostMode mode) async {
          final segment = find.byKey(ValueKey('ghosts-${mode.name}'));
          await tester.ensureVisible(segment);
          await tester.tap(segment);
          await tester.pump();
        }

        // "Wenige" by default: here Lena, with her name.
        await _tapKey(tester, 'runner-settings');
        final time = game.time;
        final few = _ghostsDrawn(tester);
        expect(few.ghosts, greaterThan(0));
        expect(few.tags, greaterThan(0));
        expect(GhostSkins.asked, 1);
        await choose(GhostMode.off);
        expect(game.time, time, reason: 'the run waits');
        expect(_ghostsDrawn(tester), (ghosts: 0, marks: 0, tags: 0));
        expect(
          (await SharedPreferences.getInstance()).getString(
            RunnerMenuPreferences.ghostModeKey,
          ),
          'off',
        );
        // On again, they are back as they were; "Alle" loads their figures
        // only now.
        await choose(GhostMode.few);
        expect(_ghostsDrawn(tester), few);
        await choose(GhostMode.all);
        expect(_ghostsDrawn(tester).ghosts, greaterThan(few.ghosts));
        expect(GhostSkins.asked, greaterThan(1));
        await choose(GhostMode.off);
        await tester.tap(find.text('Fertig'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('runner-paused')));
        await tester.pump();

        // Later in the run the crashed ones would leave their crosses.
        await until(tester, game, 6);
        expect(_ghostsDrawn(tester), (ghosts: 0, marks: 0, tags: 0));
        await _tapKey(tester, 'runner-settings');
        await choose(GhostMode.all);
        expect(_ghostsDrawn(tester).marks, greaterThan(0));
        await choose(GhostMode.off);
        expect(_ghostsDrawn(tester), (ghosts: 0, marks: 0, tags: 0));
        await tester.tap(find.text('Fertig'));
        await tester.pumpAndSettle();

        // The next training starts without them.
        game.invincible = false;
        await tester.tap(find.byKey(const ValueKey('runner-paused')));
        await untilCurtain(tester);
        final again = find.byKey(const ValueKey('runner-train-again'));
        await tester.ensureVisible(again);
        await tester.tap(again);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(games, hasLength(2));
        expect(games.last.time, lessThan(ghostNamesFor));
        expect(_ghostsDrawn(tester), (ghosts: 0, marks: 0, tags: 0));
      });
    });

    testWidgets('the menu stops pointing to last week’s reward once the '
        'page showed it', (tester) async {
      final weekly = _Weekly(
        used: 0,
        lastWeek: {'week': '2026-W36', 'rank': 2, 'score': 640, 'gage': 40},
      )..scoresRejected = true;
      final controller = await _controller(weekly);
      await pumpGame(tester, controller);
      const hint = 'Deine Belohnung von letzter Woche wartet';
      expect(find.text(hint), findsOneWidget);
      await train(tester);
      // The result cannot be saved, so the week is not loaded again.
      await untilCurtain(tester);
      expect(weekly.bodies['POST scores'], hasLength(1));
      expect(find.byKey(const ValueKey('runner-weekly')), findsOneWidget);
      expect(find.text(hint), findsNothing);
    });
  });
}
