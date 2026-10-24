import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/score_outbox.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// "wenn man zu schnell neustarten drückt wurde der score nicht gespeichert":
// a quick "Nochmal" must not lose or swap the result of the run before.

class _QuietSound implements RunnerSound {
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

JsonMap _board() => {'players': 0, 'top': <JsonMap>[], 'own': null};

JsonMap _scored(JsonMap body) => {
  'score': body['score'],
  'improved': false,
  'leaderboard': _board(),
};

Future<void> _runUntilOver(WidgetTester tester) async {
  for (var i = 0; i < 60 * 20 && find.text('Nochmal').evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump();
}

Future<void> _open(
  WidgetTester tester,
  TestServer server,
  void Function(StageRunner) onRun,
) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: StageRunnerScreen(
        controller: controller,
        random: Random(3),
        onRun: onRun,
        sound: _QuietSound(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TestServer _server() => TestServer()
  ..data['capabilities'] = {
    'features': ['stageRunner'],
  };

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('"Nochmal" before the run started on the server still sends '
      'that run with its own round and numbers', (tester) async {
    final server = _server();
    final firstStart = Completer<http.Response>();
    var starts = 0;
    final scores = <JsonMap>[];
    server.override = (request) {
      final path = _path(request);
      if (path.endsWith('/leaderboard')) {
        return Future.value(jsonResponse(_board()));
      }
      if (path.endsWith('/rounds')) {
        return ++starts == 1
            ? firstStart.future
            : Future.value(jsonResponse({'roundId': 'r-$starts'}));
      }
      if (path.endsWith('/scores')) {
        final body = jsonMap(jsonDecode(request.body));
        scores.add(body);
        return Future.value(jsonResponse(_scored(body)));
      }
      return null;
    };
    final games = <StageRunner>[];
    await _open(tester, server, games.add);

    await tester.tap(find.text('Vorhang auf'));
    await _runUntilOver(tester);
    final a = games.single;
    expect(a.over, isTrue);
    expect(a.score, greaterThan(0));
    // At once again, while the server still starts run A.
    await tester.tap(find.text('Nochmal'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(games, hasLength(2));
    firstStart.complete(jsonResponse({'roundId': 'r-1'}));
    await tester.pump(const Duration(milliseconds: 200));

    expect(scores, [
      {
        'roundId': 'r-1',
        'score': a.score,
        'meters': a.meters,
        'hitBy': a.hitBy!.name,
        'missionStats': a.missionStats,
      },
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a result without connection is sent again after the next run, '
      'with its own round', (tester) async {
    final server = _server();
    var starts = 0;
    var offline = true;
    final scores = <JsonMap>[];
    server.override = (request) {
      final path = _path(request);
      if (path.endsWith('/leaderboard')) {
        return Future.value(jsonResponse(_board()));
      }
      if (path.endsWith('/rounds')) {
        return Future.value(jsonResponse({'roundId': 'r-${++starts}'}));
      }
      if (path.endsWith('/scores')) {
        final body = jsonMap(jsonDecode(request.body));
        scores.add(body);
        if (offline) {
          offline = false;
          return Future.error(http.ClientException('offline'));
        }
        return Future.value(jsonResponse(_scored(body)));
      }
      return null;
    };
    final games = <StageRunner>[];
    await _open(tester, server, games.add);

    await tester.tap(find.text('Vorhang auf'));
    await _runUntilOver(tester);
    expect(find.textContaining('werden nachgetragen'), findsOneWidget);
    await tester.tap(find.text('Nochmal'));
    await tester.pump();
    await _runUntilOver(tester);
    await tester.pump(const Duration(milliseconds: 200));

    final [a, b] = games;
    expect([for (final s in scores) (s['roundId'], s['score'])], [
      ('r-1', a.score),
      ('r-2', b.score),
      ('r-1', a.score),
    ]);
    expect(find.textContaining('werden nachgetragen'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a rejected result is not sent again', (tester) async {
    final server = _server();
    var sent = 0;
    server.override = (request) {
      if (!_path(request).endsWith('/scores')) return null;
      sent++;
      return Future.value(
        jsonResponse({
          'error': 'Dieser Lauf ist nicht bekannt.',
          'code': 'round_unknown',
        }, 409),
      );
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    final outbox = runnerScoreOutbox(controller);
    final run = RunScore(round: Future.value('r-x'), score: 5, meters: 5);
    await expectLater(outbox.send(run), throwsA(anything));
    expect(outbox.waits(run), isFalse);
    await outbox.retry();
    expect(sent, 1);
  });
}
