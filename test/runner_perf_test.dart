import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/telemetry/perf_telemetry.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/stage_runner_perf.dart';

class _Uplink implements PerfUplink {
  @override
  bool isDemo = false;
  @override
  bool hasAccess = true;
  @override
  bool featuresKnown = true;
  final sent = <Map<String, Object?>>[];
  @override
  bool supports(String feature) => feature == PerfTelemetry.feature;
  @override
  Future<void> send(Map<String, Object?> report) async =>
      sent.add(jsonDecode(jsonEncode(report)) as Map<String, Object?>);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the first picture of a run carries only the start; the report says '
      'whether sound was on and how long that picture took', () async {
    final uplink = _Uplink();
    final t = PerfTelemetry(store: MemoryPerfStore(), random: Random(7))
      ..startForTest(uplink: uplink);
    var sound = false;
    final game = StageRunner(random: Random(1));
    final perf = RunnerPerf(
      game,
      curtainStart: 1,
      recorder: t.beginRun(),
      sound: () => sound,
    );
    // As in _play and the first tick: music, then a first update of no time
    // that places the first obstacle and plays a sound.
    perf
      ..start()
      ..played()
      ..step(0)
      ..observe()
      ..played();
    game.update(.016);
    perf
      ..observe()
      ..step(.24);
    // Later events are the game's again.
    perf
      ..played()
      ..step(.06);
    sound = true;
    perf.finish(null);
    await t.flush();
    final report = uplink.sent.single;
    expect((report['worst']! as List).map((w) => (w as Map)['ev']), [
      'start',
      'sound',
    ]);
    final run = report['run']! as Map;
    expect(run['snd'], true);
    expect(run['f0'], 240);
  });
}
