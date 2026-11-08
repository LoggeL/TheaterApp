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
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/next_drop.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// The countdown to the next content drop (`nextDrop`, runner-next-drop.mjs):
// a card on the game menu and a line in the wardrobe, by the server's clock,
// with a fresh wardrobe at zero.

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

final _server = DateTime.utc(2026, 11, 8, 16, 0);

/// A drop [left] ahead of the server's time [_server] of a reply that
/// arrived at [receivedAt] on the countdown's clock.
NextDrop _drop({
  Duration left = const Duration(hours: 2),
  bool ready = true,
  Duration receivedAt = Duration.zero,
  String name = 'Eine höllische Herausforderung',
}) => NextDrop(
  id: 'hell-2026',
  name: name,
  startsAt: _server.add(left),
  ready: ready,
  serverNow: _server,
  receivedAt: receivedAt,
);

/// The countdown's clock on the test's fake time.
Duration _fakeClock(WidgetTester tester) =>
    Duration(microseconds: tester.binding.clock.now().microsecondsSinceEpoch);

JsonMap _item(String id, String kind) => {
  'id': id,
  'kind': kind,
  'name': id,
  'rarity': 'hell',
  'rarities': ['hell'],
  'default': true,
};

/// A plain wardrobe; [drop] is its `nextDrop` with the server time [now].
JsonMap _wardrobe({JsonMap? drop, DateTime? now}) => {
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hell', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
    ],
    'items': [
      _item('c0', 'character'),
      _item('b0', 'backdrop'),
      _item('o0', 'obstacles'),
      _item('f0', 'fx'),
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0'],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'progress': {'meters': 100, 'crates': 0, 'nextAt': 2000, 'poolSize': 1},
  'nextDrop': ?drop,
  if (drop != null) 'now': (now ?? _server).toIso8601String(),
};

JsonMap _dropJson({required Duration left, bool ready = true}) => {
  'id': 'hell-2026',
  'name': 'Eine höllische Herausforderung',
  'startsAt': _server.add(left).toIso8601String(),
  'ready': ready,
};

/// A signed-in app whose wardrobe answers come from [wardrobes] in turn (the
/// last one again), counting the requests in [calls].
Future<AppController> _signedIn(
  List<JsonMap> wardrobes,
  List<String> calls,
) async {
  final server = TestServer();
  server.data['capabilities'] = {
    'features': ['stageRunner', 'runnerUnlocks', 'runnerDupes'],
  };
  server.override = (http.Request request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (!path.contains('/games/runner/')) return null;
    if (path.endsWith('/wardrobe')) {
      calls.add('wardrobe');
      final i = (calls.length - 1).clamp(0, wardrobes.length - 1);
      return Future.value(jsonResponse(wardrobes[i]));
    }
    if (path.endsWith('/leaderboard')) {
      return Future.value(jsonResponse({'players': 0, 'top': []}));
    }
    return Future.value(jsonResponse({}));
  };
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

void main() {
  final monotonic = nextDropClock;
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    nextDropClock = monotonic;
    NextDropTicker.retryDelay = const Duration(seconds: 15);
  });

  group('countdown text', () {
    test('hours, minutes and seconds, rounded up to the second', () {
      expect(
        dropCountdown(const Duration(hours: 5, minutes: 3, seconds: 9)),
        '05:03:09',
      );
      expect(
        dropCountdown(
          const Duration(hours: 23, minutes: 59, seconds: 59, milliseconds: 1),
        ),
        '24:00:00',
      );
      expect(
        dropCountdown(const Duration(hours: 23, minutes: 58, seconds: 59)),
        '23:58:59',
      );
      expect(dropCountdown(const Duration(milliseconds: 300)), '00:00:01');
      expect(dropCountdown(Duration.zero), '00:00:00');
      expect(dropCountdown(const Duration(seconds: -5)), '00:00:00');
    });

    test('names the drop while it counts, then says what happens', () {
      final drop = _drop();
      expect(
        dropText(drop, const Duration(minutes: 90, seconds: 5)),
        'Neue Kostüme in 01:30:05 · Eine höllische Herausforderung',
      );
      expect(
        dropText(drop, Duration.zero),
        'Neue Kostüme sind da · Eine höllische Herausforderung',
      );
      final held = _drop(ready: false);
      expect(
        dropText(held, const Duration(seconds: 10)),
        'Neue Kostüme in 00:00:10 · Eine höllische Herausforderung',
      );
      expect(dropText(held, Duration.zero), 'Gleich soll es so weit sein …');
      expect(
        dropText(held, const Duration(seconds: -30)),
        'Gleich soll es so weit sein …',
        reason: 'never a negative countdown',
      );
      expect(
        dropText(_drop(name: ' '), const Duration(seconds: 1)),
        'Neue Kostüme in 00:00:01',
      );
    });

    test('ticks on the change of the shown second', () {
      expect(
        dropTickDelay(const Duration(seconds: 3, milliseconds: 250)),
        const Duration(milliseconds: 250),
      );
      expect(
        dropTickDelay(const Duration(seconds: 3)),
        const Duration(seconds: 1),
      );
      expect(dropTickDelay(Duration.zero), const Duration(seconds: 1));
    });
  });

  group('server clock', () {
    test('counts the time since the reply onto the server\'s time', () {
      // Whatever the device's wall clock says: only the time since the
      // reply on the monotonic clock counts.
      const at = Duration(hours: 7);
      final drop = _drop(receivedAt: at);
      expect(drop.remainingAt(at), const Duration(hours: 2));
      expect(
        drop.remainingAt(at + const Duration(minutes: 30)),
        const Duration(minutes: 90),
      );
      expect(
        drop.remainingAt(at + const Duration(hours: 3)),
        const Duration(hours: -1),
      );
      expect(drop.countsDown, isTrue);
      expect(_drop(left: Duration.zero).countsDown, isFalse);
      expect(_drop(left: const Duration(minutes: -5)).countsDown, isFalse);
    });

    test('a wall clock set while it counts does not move it', () {
      // The monotonic clock goes on by 10 minutes while the device's wall
      // clock is set back by an hour (a time sync): 10 minutes off the
      // countdown, no more.
      final uptime = <Duration>[const Duration(seconds: 100)];
      nextDropClock = () => uptime.last;
      final drop = NextDrop.fromJson(
        _dropJson(left: const Duration(hours: 1)),
        now: _server.toIso8601String(),
      )!;
      expect(drop.remaining, const Duration(hours: 1));
      uptime.add(const Duration(seconds: 700));
      expect(drop.remaining, const Duration(minutes: 50));
    });

    test('reads the reply; without a server time the device counts', () {
      const received = Duration(seconds: 42);
      final drop = NextDrop.fromJson(
        _dropJson(left: const Duration(hours: 1), ready: false),
        now: _server.toIso8601String(),
        receivedAt: received,
      )!;
      expect(drop.id, 'hell-2026');
      expect(drop.name, 'Eine höllische Herausforderung');
      expect(drop.ready, isFalse);
      expect(drop.remainingAt(received), const Duration(hours: 1));
      // The device's own time: a drop an hour from it.
      final plain = NextDrop.fromJson({
        'id': 'x',
        'startsAt': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      }, receivedAt: received)!;
      expect(plain.remainingAt(received).inMinutes, inInclusiveRange(59, 60));
      expect(plain.ready, isTrue);
      expect(NextDrop.fromJson(null), isNull);
      expect(NextDrop.fromJson({'id': 'x'}), isNull);
      expect(NextDrop.fromJson({'startsAt': 'nonsense', 'id': 'x'}), isNull);
    });

    test('the wardrobe carries it only when the server sends it', () {
      expect(Wardrobe.fromJson(_wardrobe()).nextDrop, isNull);
      final w = Wardrobe.fromJson(
        _wardrobe(drop: _dropJson(left: const Duration(minutes: 5))),
      );
      expect(w.nextDrop?.id, 'hell-2026');
    });
  });

  group('ticker', () {
    Future<void> pumpTicker(
      WidgetTester tester,
      NextDrop drop, {
      required DropDue onDue,
      bool ticking = true,
    }) => tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: ticking,
          child: NextDropTicker(
            drop: drop,
            onDue: onDue,
            builder: (context, text, _) => Text(text),
          ),
        ),
      ),
    );

    testWidgets('counts every second and asks once at zero', (tester) async {
      nextDropClock = () => _fakeClock(tester);
      var due = 0;
      final drop = _drop(
        left: const Duration(seconds: 3),
        receivedAt: nextDropClock(),
      );
      await pumpTicker(
        tester,
        drop,
        onDue: () async {
          due++;
          return true;
        },
      );
      expect(
        find.text('Neue Kostüme in 00:00:03 · Eine höllische Herausforderung'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('00:00:02'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('00:00:01'), findsOneWidget);
      expect(due, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        find.text('Neue Kostüme sind da · Eine höllische Herausforderung'),
        findsOneWidget,
      );
      expect(due, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(due, 1, reason: 'once, and no timer after zero');
    });

    testWidgets('a held pack says it is on its way, never below zero', (
      tester,
    ) async {
      nextDropClock = () => _fakeClock(tester);
      var due = 0;
      final drop = _drop(
        left: const Duration(seconds: 1),
        ready: false,
        receivedAt: nextDropClock(),
      );
      await pumpTicker(
        tester,
        drop,
        onDue: () async {
          due++;
          return true;
        },
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Gleich soll es so weit sein …'), findsOneWidget);
      expect(due, 1);
      // The fresh reply still has it waiting: no second request.
      final again = _drop(
        left: const Duration(seconds: -2),
        ready: false,
        receivedAt: nextDropClock(),
      );
      await pumpTicker(
        tester,
        again,
        onDue: () async {
          due++;
          return true;
        },
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Gleich soll es so weit sein …'), findsOneWidget);
      expect(due, 1);
    });

    testWidgets('a covered countdown waits and catches up when shown', (
      tester,
    ) async {
      nextDropClock = () => _fakeClock(tester);
      var due = 0;
      final drop = _drop(
        left: const Duration(seconds: 2),
        receivedAt: nextDropClock(),
      );
      await pumpTicker(
        tester,
        drop,
        onDue: () async {
          due++;
          return true;
        },
        ticking: false,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(find.textContaining('00:00:02'), findsOneWidget, reason: 'idle');
      expect(due, 0);
      await pumpTicker(
        tester,
        drop,
        onDue: () async {
          due++;
          return true;
        },
      );
      await tester.pump();
      expect(due, 1, reason: 'due while covered: asks once shown');
    });
    testWidgets('zero passed while no ticker showed it: asks once shown', (
      tester,
    ) async {
      // The menu's card is gone during a run and the drop starts meanwhile.
      nextDropClock = () => _fakeClock(tester);
      var due = 0;
      Future<bool> onDue() async {
        due++;
        return true;
      }

      final drop = _drop(
        left: const Duration(seconds: 2),
        receivedAt: nextDropClock(),
      );
      await pumpTicker(tester, drop, onDue: onDue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
      expect(due, 0);
      await pumpTicker(tester, drop, onDue: onDue);
      await tester.pump();
      expect(due, 1, reason: 'the reply came before the start');
      // Shown again with the same reply: the wardrobe came already.
      await tester.pumpWidget(const SizedBox());
      await pumpTicker(tester, drop, onDue: onDue);
      await tester.pump(const Duration(seconds: 30));
      expect(due, 1);
    });

    testWidgets('a reload that fails is asked again in a while', (
      tester,
    ) async {
      nextDropClock = () => _fakeClock(tester);
      NextDropTicker.retryDelay = const Duration(seconds: 10);
      var due = 0, fail = 2;
      Future<bool> onDue() async {
        due++;
        if (fail-- > 0) throw StateError('offline');
        return true;
      }

      final drop = _drop(
        left: const Duration(seconds: 1),
        receivedAt: nextDropClock(),
      );
      await pumpTicker(tester, drop, onDue: onDue);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(due, 1);
      await tester.pump(const Duration(seconds: 9));
      expect(due, 1, reason: 'not before the wait');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(due, 2);
      // A reload that only says no counts as failed as well.
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(due, 3);
      await tester.pump(const Duration(minutes: 1));
      expect(due, 3, reason: 'the wardrobe came');
      expect(
        find.text('Neue Kostüme sind da · Eine höllische Herausforderung'),
        findsOneWidget,
      );
    });
  });

  group('screens', () {
    testWidgets('the menu shows the card on top and reloads at zero', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      nextDropClock = () => _fakeClock(tester);
      final calls = <String>[];
      // The server's clock is not the device's: 2026 against today.
      final controller = await _signedIn([
        _wardrobe(drop: _dropJson(left: const Duration(seconds: 3))),
        _wardrobe(),
      ], calls);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: StageRunnerScreen(controller: controller, sound: _Sound()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final card = find.byKey(const ValueKey('runner-next-drop'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.textContaining(
            RegExp(r'^Neue Kostüme in 00:00:0[23] · Eine höllische'),
          ),
        ),
        findsOneWidget,
      );
      expect(calls, ['wardrobe']);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, ['wardrobe', 'wardrobe']);
      expect(card, findsNothing, reason: 'the drop is live');
      await tester.pumpWidget(const SizedBox());
    });

    for (final size in [const Size(390, 844), const Size(844, 390)]) {
      testWidgets(
        'the wardrobe header counts down (${size.width}×${size.height})',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          nextDropClock = () => _fakeClock(tester);
          final calls = <String>[];
          final controller = await _signedIn([
            _wardrobe(
              drop: _dropJson(left: const Duration(seconds: 2), ready: false),
            ),
            // At its start the pack still waits for its pictures.
            _wardrobe(
              drop: _dropJson(left: Duration.zero, ready: false),
              now: _server.add(const Duration(seconds: 3)),
            ),
          ], calls);
          await tester.pumpWidget(
            MaterialApp(
              theme: StageTheme.build(Brightness.light),
              home: WardrobeScreen(controller: controller, sound: _Sound()),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final line = find.byKey(const ValueKey('wardrobe-next-drop'));
          expect(
            tester.widget<Text>(line).data,
            startsWith('Neue Kostüme in 00:00:0'),
          );
          expect(find.text('Garderobe'), findsOneWidget);
          await tester.pump(const Duration(seconds: 2));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(calls, ['wardrobe', 'wardrobe']);
          expect(
            tester.widget<Text>(line).data,
            'Gleich soll es so weit sein …',
          );
          await tester.pump(const Duration(seconds: 5));
          expect(calls, hasLength(2), reason: 'no request loop while it waits');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  });
}
