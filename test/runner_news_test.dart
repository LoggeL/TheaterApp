import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/features/games/data/runner_menu_preferences.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/games/ui/runner_news.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// "Neu im Bühnenlauf": the news shown once as the game's menu opens.

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

const _key = RunnerMenuPreferences.newsSeenKey;
const _id = 'wochenprobe-2026-11';

/// The test clock's week (`fixedNow` is Saturday, 12 September 2026).
const _weekJson = {
  'week': '2026-W37',
  'seed': 31415,
  'startsAt': '2026-09-06T22:00:00.000Z',
  'endsAt': '2026-09-13T22:00:00.000Z',
  'attempts': {'used': 0, 'max': 3},
  'best': null,
  'leaderboard': <Object?>[],
  'ghosts': <Object?>[],
  'lastWeek': null,
};

Future<AppController> _controller({
  List<String> features = const [
    'stageRunner',
    'runnerWeekly',
    'runnerWeeklyRewards',
  ],
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = (http.Request request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (!path.contains('/games/runner/')) return null;
    if (path.endsWith('/games/runner/weekly')) {
      return Future.value(jsonResponse(_weekJson));
    }
    if (path.endsWith('/games/runner/leaderboard')) {
      return Future.value(
        jsonResponse({'players': 0, 'top': <Object?>[], 'own': null}),
      );
    }
    return Future.value(jsonResponse({'error': 'not found'}, 404));
  };
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpGame(WidgetTester tester, AppController controller) async {
  final sound = _QuietSound();
  addTearDown(sound.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: StageRunnerScreen(controller: controller, sound: sound),
    ),
  );
  await tester.pumpAndSettle();
}

/// What this device keeps, as a fresh start of the app finds it.
Future<void> _restart(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  final stored = await SharedPreferences.getInstance();
  SharedPreferences.setMockInitialValues({
    for (final key in stored.getKeys()) key: stored.get(key)!,
  });
}

final _news = find.byKey(const ValueKey('runner-news'));

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('which entry', () {
    const a = RunnerNews(id: 'a', title: 'A', points: []);
    const b = RunnerNews(id: 'b', title: 'B', points: []);
    const c = RunnerNews(id: 'c', title: 'C', points: []);

    test('only the newest unseen shows, the older count as seen with it', () {
      final pending = pendingRunnerNews([a, b, c], {}, (_) => true)!;
      expect(pending.news.id, 'c');
      expect(pending.seen, ['a', 'b', 'c']);
    });

    test('once the newest was seen, none', () {
      expect(pendingRunnerNews([a, b, c], {'c'}, (_) => true), isNull);
      expect(pendingRunnerNews(const [], {}, (_) => true), isNull);
    });

    test('an entry this server does not offer waits, unmarked', () {
      final pending = pendingRunnerNews([a, b, c], {}, (n) => n.id != 'c')!;
      expect(pending.news.id, 'b');
      expect(pending.seen, ['a', 'b']);
      expect(pendingRunnerNews([a, b], {'a'}, (n) => n.id == 'a'), isNull);
    });

    test('the Wochenprobe is the first entry', () {
      final first = runnerNews.first;
      expect(first.id, _id);
      expect(first.title, 'Neu: Die Wochenprobe');
      expect(first.actionLabel, 'Zur Wochenprobe');
      expect(first.action, RunnerNewsAction.weekly);
      expect(first.points, hasLength(5));
      expect(runnerNews.map((n) => n.id).toSet(), hasLength(runnerNews.length));
    });
  });

  group('in the menu', () {
    testWidgets('shows once; "Später" closes it, also after a restart', (
      tester,
    ) async {
      _size(tester, const Size(420, 1800));
      final controller = await _controller();
      await _pumpGame(tester, controller);
      expect(_news, findsOneWidget);
      expect(find.text('Neu im Bühnenlauf'.toUpperCase()), findsOneWidget);
      expect(find.text('Neu: Die Wochenprobe'), findsOneWidget);
      expect(find.textContaining('von Montag bis Sonntag'), findsOneWidget);
      expect(
        find.textContaining('Ein Versuch zählt, sobald der Lauf startet'),
        findsOneWidget,
      );
      expect(find.textContaining('so oft du willst'), findsOneWidget);
      expect(find.textContaining('wer direkt vor dir liegt'), findsOneWidget);
      expect(find.textContaining('Wochenkiste fürs Mitmachen'), findsOneWidget);
      expect(find.text('Zur Wochenprobe'), findsOneWidget);
      // Seen as soon as it shows.
      expect((await SharedPreferences.getInstance()).getStringList(_key), [
        _id,
      ]);

      await tester.tap(find.byKey(const ValueKey('runner-news-later')));
      await tester.pumpAndSettle();
      expect(_news, findsNothing);
      expect(find.text('Wochenprobe'), findsWidgets);
      expect(find.byKey(const ValueKey('weekly-course')), findsNothing);

      // The menu again in this session: nothing.
      await tester.pumpWidget(const SizedBox());
      await _pumpGame(tester, controller);
      expect(_news, findsNothing);

      await _restart(tester);
      await _pumpGame(tester, controller);
      expect(_news, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('its button opens the Wochenprobe', (tester) async {
      _size(tester, const Size(420, 1800));
      final controller = await _controller();
      await _pumpGame(tester, controller);
      await tester.tap(find.byKey(const ValueKey('runner-news-action')));
      await tester.pumpAndSettle();
      expect(_news, findsNothing);
      expect(find.byKey(const ValueKey('weekly-course')), findsOneWidget);
      // Back in the menu it stays away.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('runner-weekly')), findsOneWidget);
      expect(_news, findsNothing);
    });

    testWidgets('not when it was seen on this device before', (tester) async {
      SharedPreferences.setMockInitialValues({
        _key: [_id],
      });
      _size(tester, const Size(420, 1800));
      final controller = await _controller();
      await _pumpGame(tester, controller);
      expect(_news, findsNothing);
      expect(find.byKey(const ValueKey('runner-weekly')), findsOneWidget);
    });

    testWidgets('not where the server has no Wochenprobe, and it waits', (
      tester,
    ) async {
      _size(tester, const Size(420, 1800));
      final controller = await _controller(features: const ['stageRunner']);
      await _pumpGame(tester, controller);
      expect(_news, findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getStringList(_key),
        isNull,
      );
    });

    testWidgets('not where the Wochenprobe has no rewards yet, and it waits', (
      tester,
    ) async {
      _size(tester, const Size(420, 1800));
      final controller = await _controller(
        features: const ['stageRunner', 'runnerWeekly'],
      );
      await _pumpGame(tester, controller);
      expect(_news, findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getStringList(_key),
        isNull,
      );
    });

    testWidgets('not without storage: it would come at every start', (
      tester,
    ) async {
      _size(tester, const Size(420, 1800));
      final controller = await _controller();
      final sound = _QuietSound();
      addTearDown(sound.dispose);
      final menu = RunnerMenuPreferences(
        loadPreferences: () => Future.error(StateError('no storage')),
      );
      addTearDown(menu.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: StageRunnerScreen(
            controller: controller,
            sound: sound,
            menuPreferences: menu,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_news, findsNothing);
    });

    for (final (name, size) in [
      ('a small phone', const Size(320, 568)),
      ('a phone held sideways', const Size(568, 320)),
      ('a tablet sideways', const Size(1180, 820)),
    ]) {
      testWidgets('fits $name', (tester) async {
        _size(tester, size);
        final controller = await _controller();
        await _pumpGame(tester, controller);
        expect(_news, findsOneWidget);
        expect(tester.takeException(), isNull);
        final later = find.byKey(const ValueKey('runner-news-later'));
        final action = find.byKey(const ValueKey('runner-news-action'));
        for (final button in [later, action]) {
          final box = tester.getRect(button);
          expect(box.top, greaterThanOrEqualTo(0));
          expect(box.bottom, lessThanOrEqualTo(size.height));
        }
        // The last point can be scrolled to.
        await tester.ensureVisible(
          find.byKey(const ValueKey('runner-news-point-4')),
        );
        await tester.pumpAndSettle();
        await tester.tap(later);
        await tester.pumpAndSettle();
        expect(_news, findsNothing);
      });
    }

    testWidgets('reads well with a screen reader', (tester) async {
      final semantics = tester.ensureSemantics();
      _size(tester, const Size(420, 1800));
      final controller = await _controller();
      await _pumpGame(tester, controller);
      expect(
        tester.getSemantics(find.text('Neu: Die Wochenprobe')),
        isSemantics(
          label: 'Neu im Bühnenlauf\nNeu: Die Wochenprobe',
          isHeader: true,
        ),
      );
      expect(
        find.bySemanticsLabel(
          RegExp('^Neu im Bühnenlauf: Neu: Die Wochenprobe'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('runner-news-action'))),
        isSemantics(label: 'Zur Wochenprobe', isButton: true),
      );
      semantics.dispose();
    });
  });
}
