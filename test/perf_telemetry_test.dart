import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/telemetry/perf_stats.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/telemetry/perf_telemetry.dart';
import 'package:theater_app/features/settings/settings.dart';
import 'package:theater_app/shared/navigation.dart';

import 'app_controller_test.dart' show TestServer, signIn;

class _Uplink implements PerfUplink {
  @override
  bool isDemo = false;
  @override
  bool hasAccess = true;
  @override
  bool featuresKnown = true;
  Set<String> features = {PerfTelemetry.feature};
  Object? failure;
  final sent = <Map<String, Object?>>[];
  @override
  bool supports(String feature) => features.contains(feature);
  @override
  Future<void> send(Map<String, Object?> report) async {
    if (failure != null) throw failure!;
    sent.add(jsonDecode(jsonEncode(report)) as Map<String, Object?>);
  }
}

class _TestPage extends StatelessWidget {
  const _TestPage();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

/// Frames every [ms] milliseconds while an animation runs.
void animate(PerfTelemetry t, int startUs, List<double> gaps) {
  var at = startUs;
  t.frameEnded(at, nextScheduled: true);
  for (final ms in gaps) {
    at += (ms * 1000).round();
    t.frameEnded(at, nextScheduled: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('frame statistics', () {
    test('percentiles, longest frame and jank counts', () {
      final stats = FrameStats();
      for (var i = 0; i < 900; i++) {
        stats.add(16.7);
      }
      for (var i = 0; i < 90; i++) {
        stats.add(33.4);
      }
      for (final ms in <double>[25, 51, 60, 70, 80, 90, 101, 120, 140, 400]) {
        stats.add(ms);
      }
      expect(stats.count, 1000);
      expect(stats.quantile(0.5), closeTo(16.7, 0.5));
      expect(stats.quantile(0.95), closeTo(33.4, 0.5));
      expect(stats.quantile(0.99), closeTo(33.4, 0.6));
      expect(stats.quantile(0.995), inInclusiveRange(51, 101));
      expect(stats.max, 400);
      expect(stats.over25, 99, reason: 'exactly 25 ms is no jank');
      expect(stats.over50, 9);
      expect(stats.over100, 4);
      final json = stats.toJson();
      final hist = json['h']! as List<int>;
      expect(hist, hasLength(frameEdges.length + 1));
      expect(hist.reduce((a, b) => a + b), 1000);
      expect(hist[bucketOf(frameEdges, 16.7)], 900);
      // The server derives jank from the buckets above 25, 50 and 100 ms.
      expect(
        hist.sublist(bucketOf(frameEdges, 25.01)).reduce((a, b) => a + b),
        99,
      );
      expect(
        hist.sublist(bucketOf(frameEdges, 100.01)).reduce((a, b) => a + b),
        4,
      );
      stats.reset();
      expect(stats.quantile(0.5), isNull);
      expect(stats.toJson()['n'], 0);
    });

    test('the worst frames keep the five longest janks', () {
      final worst = WorstFrames();
      for (final ms in <double>[20, 30, 80, 26, 90, 40, 70, 300]) {
        if (worst.qualifies(ms)) worst.offer(WorstFrame(ms, route: 'r$ms'));
      }
      expect(worst.toJson().map((f) => f['ms']), [300, 90, 80, 70, 40]);
      expect(worst.qualifies(39), isFalse);
      expect(worst.qualifies(41), isTrue);
    });

    test('API paths lose their ids', () {
      expect(apiPathPattern('/snapshot'), '/snapshot');
      expect(
        apiPathPattern('/productions/der-raub/script'),
        '/productions/:id/script',
      );
      expect(apiPathPattern('/admin/events/7f3c9a'), '/admin/events/:id');
      expect(
        apiPathPattern('/games/runner/skins/character-logge.webp?v=ab12'),
        '/games/runner/skins/:id',
      );
      expect(
        apiPathPattern('/galleries/g1/assets/a9/original'),
        '/galleries/:id/assets/:id/original',
      );
      expect(
        apiPathPattern('/admin/accounts/Xy7AbCdEfGhIjKlMnOpQrStUvWx1'),
        '/admin/accounts/:id',
      );
      expect(
        apiPathPattern('/feedback/abc/messages'),
        '/feedback/:id/messages',
      );
      expect(apiPathPattern('/admin/feedback'), '/admin/feedback');
      expect(
        apiPathPattern('/games/runner/wardrobe'),
        '/games/runner/wardrobe',
      );
    });

    test('user agents are shortened to browser, system and form factor', () {
      expect(
        parseUserAgent(
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
        ),
        (browser: 'Chrome 141', os: 'Android 10', mobile: true),
      );
      expect(
        parseUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1',
        ),
        (browser: 'Safari 18.4', os: 'iOS 18.4', mobile: true),
      );
      expect(
        parseUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0 Mobile/15E148 Safari/604.1',
        ).browser,
        'Chrome 141',
      );
      expect(
        parseUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0',
        ),
        (browser: 'Firefox 132', os: 'Windows', mobile: false),
      );
      expect(
        parseUserAgent(
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0',
        ),
        (browser: 'Edge 141', os: 'macOS', mobile: false),
      );
      expect(
        parseUserAgent(
          'Mozilla/5.0 (Linux; Android 14; SAMSUNG SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/27.0 Chrome/125.0.0.0 Mobile Safari/537.36',
        ).browser,
        'Samsung Internet 27',
      );
      expect(
        parseUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram',
        ).browser,
        'iOS WebView',
      );
    });
  });

  group('sampling', () {
    late PerfTelemetry t;
    late _Uplink uplink;
    setUp(() {
      uplink = _Uplink();
      t = PerfTelemetry(store: MemoryPerfStore(), random: Random(1))
        ..startForTest(uplink: uplink);
    });

    test('animations count frame distances, idle pauses do not', () {
      animate(t, 1000000, [16.7, 16.6, 50, 16.7]);
      // The last frame of the animation requests no further one; the next
      // frame comes after an idle pause.
      t.frameEnded(1116700, nextScheduled: false);
      t.frameEnded(9100000, nextScheduled: false);
      final frames = t.buildReport()['frames']! as Map;
      expect(frames['n'], 5);
      expect(frames['j25'], 1);
      expect(frames['max'], 50);
    });

    test('a frame caused by input counts from the input', () {
      t.frameEnded(1000000, nextScheduled: false);
      t.inputArrived(5000000, 'drag', requestedFrame: false);
      t.frameEnded(5010000, nextScheduled: false);
      expect(
        t.buildReport()['frames'],
        isNull,
        reason: 'input without a frame request',
      );
      t.inputArrived(6000000, 'tap', requestedFrame: true);
      t.inputArrived(6005000, 'tap', requestedFrame: true);
      t.frameEnded(6040000, nextScheduled: false);
      final report = t.buildReport();
      expect((report['frames']! as Map)['max'], 40);
      expect((report['worst']! as List).single, containsPair('in', 'tap'));
    });

    test('frames are counted per screen with context for janks', () {
      t.setRoot('today');
      animate(t, 1000000, [16.7, 16.7]);
      t.frameEnded(1050100, nextScheduled: false);
      t.setRoot('schedule');
      t
        ..clock = (() => 2000000)
        ..mark('api');
      animate(t, 2000000, [16.7, 80]);
      t.recordTiming(4, 6, 12);
      final report = t.buildReport();
      final routes = {
        for (final r in report['routes']! as List) (r as Map)['r']: r,
      };
      expect(routes['today']!['n'], 3);
      expect(routes['schedule']!['n'], 2);
      expect(routes['schedule']!['b95'], closeTo(4, 0.5));
      expect(routes['today']!.containsKey('b95'), isFalse);
      final worst = (report['worst']! as List).single as Map;
      expect(worst['r'], 'schedule');
      expect(worst['ev'], 'api');
      expect(worst['t'], closeTo(2.1, 0.01));
      expect((report['frames']! as Map)['ft'], 1);
    });

    test('API latencies are grouped by pattern with errors and offline', () {
      for (final ms in [120, 180, 300, 2400]) {
        t.recordApi('GET', '/snapshot', 200, Duration(milliseconds: ms));
      }
      t.recordApi('GET', '/snapshot', 0, const Duration(seconds: 20));
      t.recordApi(
        'GET',
        '/productions/p1/script',
        500,
        const Duration(milliseconds: 900),
      );
      t.recordApi(
        'POST',
        '/telemetry/perf',
        204,
        const Duration(milliseconds: 50),
      );
      final api = {
        for (final a in t.buildReport()['api']! as List)
          '${(a as Map)['m']} ${a['p']}': a,
      };
      expect(api.keys, ['GET /snapshot', 'GET /productions/:id/script']);
      expect(api['GET /snapshot'], containsPair('n', 5));
      expect(api['GET /snapshot'], containsPair('off', 1));
      expect(api['GET /snapshot']!['max'], 2400);
      expect(api['GET /productions/:id/script'], containsPair('err', 1));
    });

    test('a busy window stays below 4 KB', () {
      final random = Random(7);
      for (var r = 0; r < PerfTelemetry.maxRoutes; r++) {
        t.setRoot('VeryLongScreenNameNumber$r');
        animate(t, r * 10000000, [
          for (var i = 0; i < 300; i++) 8 + random.nextDouble() * 120,
        ]);
        t.frameEnded(r * 10000000 + 9000000, nextScheduled: false);
        t.recordTiming(5, 7, 14);
      }
      for (var p = 0; p < 40; p++) {
        t.recordApi(
          'GET',
          '/admin/path$p/x',
          200,
          Duration(milliseconds: 100 + p),
        );
      }
      final report = PerfTelemetry.fit(t.buildReport());
      final bytes = utf8.encode(jsonEncode(report)).length;
      expect(bytes, lessThanOrEqualTo(PerfTelemetry.maxBytes));
      expect((report['routes']! as List).length, greaterThan(3));
      expect(report['worst'], hasLength(5));
    });

    test('a typical window is about 2 KB', () {
      for (final (i, root) in [
        'today',
        'schedule',
        'scripts',
        'EventDetailScreen',
        'ScriptReaderScreen',
      ].indexed) {
        t.setRoot(root);
        animate(t, i * 10000000, [
          for (var f = 0; f < 600; f++) f % 97 == 0 ? 45 : 16.7,
        ]);
        t.frameEnded(i * 10000000 + 9000000, nextScheduled: false);
      }
      for (final p in [
        '/snapshot',
        '/participation',
        '/productions/x/script',
        '/media/a',
        '/games/runner/leaderboard',
      ]) {
        t.recordApi('GET', p, 200, const Duration(milliseconds: 240));
      }
      final bytes = utf8.encode(jsonEncode(t.buildReport())).length;
      // Printed for the record of the payload size.
      // ignore: avoid_print
      print('typical report: $bytes bytes');
      expect(bytes, lessThan(2600));
    });
  });

  group('sending', () {
    late PerfTelemetry t;
    late _Uplink uplink;
    late MemoryPerfStore store;
    setUp(() {
      uplink = _Uplink();
      store = MemoryPerfStore();
      t = PerfTelemetry(store: store, random: Random(2))
        ..startForTest(uplink: uplink);
      animate(t, 1000000, [16.7, 16.7, 40]);
    });

    test('reports go out when the server has the feature', () async {
      t.closeWindow();
      expect(t.queue, hasLength(1));
      expect(store.values['perf.queue'], isNotNull, reason: 'kept until sent');
      await t.flush();
      expect(uplink.sent, hasLength(1));
      final report = uplink.sent.single;
      expect(report['v'], 1);
      expect(report['kind'], 'app');
      expect(report['install'], matches(RegExp(r'^[a-f0-9]{32}$')));
      expect((report['frames']! as Map)['n'], 3);
      expect(jsonEncode(report), isNot(contains('uid')));
      expect(t.queue, isEmpty);
      expect(store.values['perf.queue'], isNull);
    });

    test('without the feature reports are dropped', () async {
      uplink.features = {};
      t.closeWindow();
      await t.flush();
      expect(uplink.sent, isEmpty);
      expect(t.queue, isEmpty);
    });

    test('the demo sends and keeps nothing', () async {
      uplink.isDemo = true;
      t.closeWindow();
      expect(t.queue, isEmpty);
      t.beginRun()
        ..frame(16, seconds: 1, meters: 5)
        ..finish(duration: const Duration(seconds: 2), meters: 5);
      await t.flush();
      expect(uplink.sent, isEmpty);
      expect(t.queue, isEmpty);
    });

    test('reports wait for access, known features and the network', () async {
      uplink.hasAccess = false;
      t.closeWindow();
      await t.flush();
      expect(t.queue, hasLength(1));
      uplink
        ..hasAccess = true
        ..featuresKnown = false;
      await t.flush();
      expect(t.queue, hasLength(1));
      uplink
        ..featuresKnown = true
        ..failure = Exception('offline');
      await t.flush();
      expect(t.queue, hasLength(1));
      uplink.failure = null;
      await t.flush();
      expect(uplink.sent, hasLength(1));
    });

    test('the local queue is bounded', () async {
      uplink.hasAccess = false;
      for (var i = 0; i < PerfTelemetry.maxQueue + 5; i++) {
        animate(t, 10000000 * (i + 2), [16.7]);
        t.closeWindow();
      }
      expect(t.queue, hasLength(PerfTelemetry.maxQueue));
    });
  });

  test('a stage runner run reports its frames with the events', () async {
    final uplink = _Uplink();
    final t = PerfTelemetry(store: MemoryPerfStore(), random: Random(3))
      ..startForTest(uplink: uplink);
    final run = t.beginRun();
    run.frame(16.7, seconds: 0.1, meters: 1);
    run
      ..mark(PerfRunEvent.pickup)
      ..mark(PerfRunEvent.sound);
    run.frame(70, seconds: 0.2, meters: 2);
    run.frame(16.7, seconds: 0.3, meters: 3);
    run.mark(PerfRunEvent.crash);
    run.frame(30, seconds: 0.4, meters: 4);
    t.recordTiming(3, 5, 10);
    run.finish(
      duration: const Duration(seconds: 12),
      meters: 4,
      score: 9,
      character: 'logge',
      end: 'crash',
    );
    run.frame(500, seconds: 1, meters: 4);
    await t.flush();
    final report = uplink.sent.single;
    expect(report['kind'], 'stageRunner');
    expect(report['run'], {
      'ms': 12000,
      'm': 4,
      'score': 9,
      'character': 'logge',
      'end': 'crash',
    });
    final frames = report['frames']! as Map;
    expect(frames['n'], 4, reason: 'frames after the end do not count');
    expect(frames['j50'], 1);
    expect(frames['ft'], 1);
    expect(report['worst'], [
      {'ms': 70, 't': 0.2, 'ev': 'pickup,sound', 'm': 2},
      {'ms': 30, 't': 0.4, 'ev': 'crash', 'm': 4},
    ]);
    expect(PerfRunEvent.describe(0), isNull);
  });

  test('a recorder without telemetry measures nothing', () {
    final run = PerfTelemetry(store: MemoryPerfStore()).beginRun()
      ..frame(16, seconds: 0, meters: 0);
    expect(
      () => run.finish(duration: Duration.zero, meters: 0),
      returnsNormally,
    );
  });

  testWidgets('pages opened with openPage are named after their screen', (
    tester,
  ) async {
    final t = PerfTelemetry(store: MemoryPerfStore())
      ..startForTest(uplink: _Uplink());
    t.setRoot('today');
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [t.navigatorObserver],
        home: const SizedBox(),
      ),
    );
    expect(t.routeName, 'today');
    openPage<void>(navigator.currentContext!, const _TestPage());
    await tester.pumpAndSettle();
    expect(t.routeName, '_TestPage');
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const Text('x'),
    );
    await tester.pumpAndSettle();
    expect(t.routeName, '_TestPage', reason: 'dialogs belong to their page');
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(t.routeName, 'today');
  });

  group('opt-out', () {
    final install = 'ab' * 16;

    test('switched off it sends nothing, drops its queue and id', () async {
      final uplink = _Uplink();
      final store = MemoryPerfStore()..values['perf.install'] = install;
      final t = PerfTelemetry(store: store, random: Random(4))
        ..startForTest(uplink: uplink);
      animate(t, 1000000, [16.7, 16.7, 40]);
      t.closeWindow();
      await Future<void>.delayed(Duration.zero);
      expect(t.queue, hasLength(1));
      expect(t.enabled.value, isTrue, reason: 'on by default');

      await t.setEnabled(false);
      expect(t.active, isFalse);
      expect(t.queue, isEmpty);
      expect(store.values['perf.enabled'], '0');
      expect(store.values['perf.queue'], isNull);
      expect(store.values['perf.install'], isNull);
      // Nothing is measured or queued any more.
      animate(t, 9000000, [16.7, 80, 16.7]);
      t.recordApi('GET', '/snapshot', 200, const Duration(milliseconds: 90));
      t.closeWindow();
      t.beginRun()
        ..frame(16, seconds: 1, meters: 5)
        ..finish(duration: const Duration(seconds: 2), meters: 5);
      await t.flush();
      expect(t.queue, isEmpty);
      expect(uplink.sent, isEmpty);

      // On again: measuring resumes under a new installation id.
      await t.setEnabled(true);
      expect(t.active, isTrue);
      expect(store.values['perf.enabled'], isNull);
      final fresh = store.values['perf.install'];
      expect(fresh, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(fresh, isNot(install));
      animate(t, 20000000, [16.7, 16.7]);
      t.closeWindow();
      await t.flush();
      expect(uplink.sent, hasLength(1));
      expect(uplink.sent.single['install'], fresh);
      expect(uplink.sent.single, isNot(contains('startup')));
    });

    test('a saved opt-out holds after a restart', () async {
      final store = MemoryPerfStore()
        ..values['perf.enabled'] = '0'
        ..values['perf.install'] = install
        ..values['perf.queue'] = '[{"kind":"app"}]';
      final t = PerfTelemetry(store: store)..startForTest(uplink: _Uplink());
      await t.loadForTest();
      expect(t.enabled.value, isFalse);
      expect(t.active, isFalse);
      expect(t.queue, isEmpty);
      expect(store.values['perf.install'], isNull);
      expect(store.values['perf.queue'], isNull);

      // Debug builds never measure, but the settings show the choice.
      final quiet = PerfTelemetry(
        store: MemoryPerfStore()..values.addAll({'perf.enabled': '0'}),
      )..start(uplink: _Uplink());
      await Future<void>.delayed(Duration.zero);
      expect(quiet.enabled.value, isFalse);
      expect(quiet.active, isFalse);
    });

    testWidgets('the settings switch it per device, on by default', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = TestServer();
      final controller = server.controller();
      await signIn(controller);
      final devices = DeviceServices(
        controller,
        onTarget: (_) {},
        onForegroundMessage: (_) {},
      );
      final store = MemoryPerfStore();
      final t = PerfTelemetry(store: store)..startForTest(uplink: _Uplink());
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            controller: controller,
            devices: devices,
            perf: t,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('perf-telemetry'));
      await tester.scrollUntilVisible(toggle, 200);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(find.text('Leistungsdaten senden'), findsOneWidget);
      expect(find.textContaining('Pseudonym, ohne Inhalte'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(t.active, isFalse);
      expect(store.values['perf.enabled'], '0');
      expect(server.actionBodies, isEmpty, reason: 'not an account setting');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(t.enabled.value, isTrue);
      expect(t.active, isTrue);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });
}
