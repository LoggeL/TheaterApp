import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/api_client.dart';
import '../app_version.dart';
import 'perf_platform.dart' as platform;
import 'perf_stats.dart';

/// Where reports go: the signed-in session (see `ControllerPerfUplink`).
abstract interface class PerfUplink {
  bool get isDemo;
  bool get hasAccess;

  /// Whether the server's features are known (from a cached or fresh
  /// snapshot), so a missing feature means "not supported".
  bool get featuresKnown;
  bool supports(String feature);
  Future<void> send(Map<String, Object?> report);
}

/// Keeps the installation id and unsent reports on the device.
abstract interface class PerfStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class PreferencesPerfStore implements PerfStore {
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String? value) async {
    final prefs = await SharedPreferences.getInstance();
    value == null ? await prefs.remove(key) : await prefs.setString(key, value);
  }
}

class MemoryPerfStore implements PerfStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async =>
      value == null ? values.remove(key) : values[key] = value;
}

/// What happened in a frame of the stage runner, as bits for
/// [PerfRunRecorder.mark]. [start] is the run's first step: setting up the
/// game and starting the music.
abstract final class PerfRunEvent {
  static const pickup = 1,
      sound = 2,
      obstacle = 4,
      debut = 8,
      skin = 16,
      crash = 32,
      curtain = 64,
      start = 128;
  static const _names = [
    'pickup',
    'sound',
    'obstacle',
    'debut',
    'skin',
    'crash',
    'curtain',
    'start',
  ];

  /// e.g. `pickup,sound`; null for no event.
  static String? describe(int mask) {
    if (mask == 0) return null;
    return [
      for (var i = 0; i < _names.length; i++)
        if (mask & (1 << i) != 0) _names[i],
    ].join(',');
  }
}

/// Frame times of one stage runner run. The game calls [frame] with every
/// game-loop step and [mark] for events; [finish] queues the report.
class PerfRunRecorder {
  PerfRunRecorder._(this._owner) : _epoch = _owner?._epoch ?? 0;
  final PerfTelemetry? _owner;

  /// The app's background/foreground count when the last step was taken.
  int _epoch;
  final frames = FrameStats();
  final _worst = WorstFrames();
  final _build = TimingStats(), _raster = TimingStats();
  int _timings = 0, _events = 0;
  bool _done = false;

  /// Notes [event] (a [PerfRunEvent] bit) for the next measured frame:
  /// work done in a frame shows up in the time until the following one.
  void mark(int event) => _events |= event;

  /// Forgets the events noted for the next frame except
  /// [PerfRunEvent.start]: what setting up a run marks (the first obstacle,
  /// a sound) belongs to the start, not to the game.
  void clear() => _events &= PerfRunEvent.start;

  /// One game-loop step of [ms] since the previous one, [seconds] and
  /// [meters] into the run.
  void frame(double ms, {required double seconds, required int meters}) {
    if (_done) return;
    final owner = _owner;
    // The step after a pause in the background measures the pause.
    if (owner != null && (owner._suspended || owner._epoch != _epoch)) {
      _epoch = owner._epoch;
      _events = 0;
      return;
    }
    if (ms >= 5000) return;
    frames.add(ms);
    if (_worst.qualifies(ms)) {
      final worst = WorstFrame(
        ms,
        at: seconds,
        meters: meters,
        events: PerfRunEvent.describe(_events),
      );
      _worst.offer(worst);
      owner?._awaitTimings(worst, ms);
    }
    _events = 0;
  }

  void _timing(double build, double raster) {
    _timings++;
    _build.add(build);
    _raster.add(raster);
  }

  /// Ends the run and queues its report. [end] is how it ended, e.g.
  /// `crash` or `quit`; [sound] whether sound was on, [firstStepMs] the
  /// run's first game-loop step.
  void finish({
    required Duration duration,
    required int meters,
    int? score,
    String? character,
    String? backdrop,
    String? fx,
    String end = 'crash',
    bool? sound,
    double? firstStepMs,
  }) {
    if (_done) return;
    _done = true;
    _owner?._finishRun(this, {
      'ms': duration.inMilliseconds,
      'm': meters,
      'score': ?score,
      'character': ?character,
      'backdrop': ?backdrop,
      'fx': ?fx,
      'end': end,
      'snd': ?sound,
      if (firstStepMs != null) 'f0': (firstStepMs * 10).roundToDouble() / 10,
    });
  }

  /// Drops the run, e.g. when the game is closed mid-run.
  void cancel() {
    _done = true;
    _owner?._finishRun(this, null);
  }

  Map<String, Object> _framesJson() => {
    ...frames.toJson(),
    'ft': _timings,
    if (_timings > 0) ..._timingJson(_build, _raster, null),
  };
}

Map<String, Object> _timingJson(
  TimingStats build,
  TimingStats raster,
  TimingStats? total,
) {
  double r(double? v) => ((v ?? 0) * 10).roundToDouble() / 10;
  return {
    'b50': r(build.quantile(0.5)),
    'b95': r(build.quantile(0.95)),
    'r50': r(raster.quantile(0.5)),
    'r95': r(raster.quantile(0.95)),
    if (total != null) 't95': r(total.quantile(0.95)),
  };
}

/// A frame longer than [PerfTelemetry._holdMs] kept back for a moment: if
/// the app goes to the background right after it, it measured the way out.
class _HeldFrame {
  _HeldFrame(this.ms, this.atUs, this.route, this.worst);
  final double ms;
  final int atUs;
  final _RouteStats route;
  final WorstFrame? worst;
}

/// A worst frame waiting for the engine's FrameTimings of the frames that
/// began (vsync) between [fromUs] and [toUs].
class _AwaitedTiming {
  _AwaitedTiming(this.frame, this.fromUs, this.toUs);
  final WorstFrame frame;
  final int fromUs, toUs;
}

class _RouteStats {
  final frames = FrameStats();
  final build = TimingStats(), raster = TimingStats();
  void reset() {
    frames.reset();
    build.reset();
    raster.reset();
  }
}

/// Anonymous performance telemetry: frame times per session and screen,
/// start times and API latencies, plus frame times of stage runner runs.
///
/// Measuring is cheap and allocation free per frame; reports (< 4 KB) are
/// queued on the device and sent when the app goes to the background and
/// every few minutes while idle, only if the server announces
/// `perfTelemetry` and never in the demo. Reports carry a random
/// installation id, never the account. Switched off in the settings
/// ("Leistungsdaten senden", per installation), it sends nothing, drops
/// its queue and installation id and stops measuring. See
/// docs/operations.md ("Performance-Telemetrie").
class PerfTelemetry {
  PerfTelemetry({PerfStore? store, Random? random})
    : _store = store ?? PreferencesPerfStore(),
      _random = random ?? Random.secure();

  static final instance = PerfTelemetry();
  static const feature = 'perfTelemetry';
  static const maxBytes = 4000, maxQueue = 12, maxRoutes = 24;
  static const sendInterval = Duration(minutes: 5);

  /// Debug builds measure nonsense (no AOT, extra checks) and stay quiet
  /// unless built with `--dart-define=PERF_TELEMETRY_DEBUG=true`.
  static const _debugEnabled = bool.fromEnvironment('PERF_TELEMETRY_DEBUG');

  final PerfStore _store;
  final Random _random;
  final _clock = Stopwatch();

  /// Microseconds since the start; tests can replace the clock.
  @visibleForTesting
  int Function()? clock;
  int _now() => clock?.call() ?? _clock.elapsedMicroseconds;

  /// The current frame's vsync time stamp in the engine's clock (the one
  /// of FrameTiming), -1 when unknown; tests can replace it.
  @visibleForTesting
  int Function()? vsyncClock;
  int _vsyncNow() =>
      vsyncClock?.call() ??
      (_testing
          ? -1
          : SchedulerBinding
                .instance
                .currentSystemFrameTimeStamp
                .inMicroseconds);
  late final NavigatorObserver navigatorObserver = _PerfRouteObserver(this);
  PerfUplink? _uplink;
  bool _active = false, _flushing = false;

  /// Started by `main` (or a test); the engine hooks are added once.
  bool _started = false, _hooked = false, _testing = false;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  /// Readable screen names for [nameRoute]: release builds on the web
  /// shorten class names.
  Map<Type, String> screenNames = const {};
  static final _routeNames = Expando<String>('perfRoute');

  String _install = '', _sessionId = '';
  int _seq = 0;
  Map<String, Object> _device = const {};
  final _queue = <Map<String, Object?>>[];

  /// Ids of the last reports sent, so a saved queue read back late does not
  /// bring them back.
  final _sentIds = <Object?>[];

  /// Whether the saved queue was read at the start; until then reports
  /// queued meanwhile are not saved over it.
  bool _queueRead = false;

  // Start.
  double? _preMs, _firstFrameMs, _readyMs, _dataMs, _fcpMs;
  Map<String, Object> _startInfo = const {};
  bool _startupSent = false;

  /// Whether the page or app was hidden before its first frame: the start
  /// then waited for the user, not for the app.
  bool _hiddenAtStart = false;

  // The current window.
  int _windowStartUs = 0;
  final _frames = FrameStats();
  final _build = TimingStats(), _raster = TimingStats(), _total = TimingStats();
  int _timings = 0;
  final _worst = WorstFrames();
  final _routes = <String, _RouteStats>{};
  final _api = <String, LatencyStats>{};

  // Frame sampling, in microseconds of [_now].
  int _lastFrameUs = -1, _inputAt = -1, _lastInputUs = -1;
  bool _continuous = false, _suspended = false;

  /// Frames longer than this are held back until the next frame shows the
  /// app is still in the foreground; within [_holdUs] before going to the
  /// background they are dropped.
  static const _holdMs = 250.0, _holdUs = 300000;
  _HeldFrame? _held;

  /// Worst frames waiting for their FrameTimings, which the engine reports
  /// in batches and late (on Android about once a second).
  final _awaited = List<_AwaitedTiming?>.filled(32, null);
  int _awaitedNext = 0, _awaitedCount = 0;

  /// Counts trips to the background, so a run skips the step across one.
  int _epoch = 0;

  /// When the app last went to the background or came back ([_now]); an
  /// API call across that time measured the pause.
  int _pausedUs = -1;
  String? _lastInput;

  /// When each app event (`route`, `api`, `skin`, `img`, `resume`) last
  /// happened ([_now]); a slow frame lists all of the last second.
  final _eventAt = <String, int>{};
  String _rootName = 'start';
  String? _pageName;
  _RouteStats? _route;
  PerfRunRecorder? _run;

  bool get active => _active;
  bool get _sending => !kDebugMode || _debugEnabled;

  /// Whether this build measures at all (not in debug builds); the route
  /// observer is attached then, even while the user has switched it off.
  bool get available => _testing || (_started && _sending);

  /// The user's choice on this installation ("Leistungsdaten senden"),
  /// on unless switched off; the telemetry knows no account.
  final enabled = ValueNotifier<bool>(true);
  static const _enabledKey = 'perf.enabled';
  String get routeName => _pageName ?? _rootName;
  @visibleForTesting
  List<Map<String, Object?>> get queue => List.unmodifiable(_queue);

  /// Starts measuring; called once from `main` before `runApp`.
  ///
  /// The hooks go in right away so the start can be measured; reading the
  /// user's choice takes a moment, and switched off it stops again before
  /// anything is queued or sent.
  void start({required PerfUplink uplink}) {
    if (_started) return;
    _started = true;
    _uplink = uplink;
    if (!_sending) {
      // No measuring, but the settings show the saved choice.
      unawaited(_loadEnabled());
      return;
    }
    _clock.start();
    _preMs = platform.pageClockMs();
    _startInfo = platform.startInfo();
    _sessionId = _hex(8);
    // Frames before the first one is on screen belong to the start (see
    // `firstFrameMs`); on the web they include loading the renderer.
    _suspended = true;
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      _firstFrameMs ??= _ms();
      _suspended = false;
      _continuous = false;
    });
    _activate();
    unawaited(_load());
  }

  /// Measures: hooks into frames, timings, input, API calls and the app's
  /// lifecycle. The persistent frame callback, the input hook and the page
  /// listener cannot be removed and do nothing while off.
  void _activate() {
    _active = true;
    if (_testing) return;
    final binding = WidgetsBinding.instance;
    if (!_hooked) {
      _hooked = true;
      binding.addPersistentFrameCallback(_onFrame);
      _watchInput(binding.platformDispatcher);
      platform.onPageHidden(_background);
    }
    binding.addTimingsCallback(_onTimings);
    ApiClient.observer = recordApi;
    _lifecycle?.dispose();
    _lifecycle = AppLifecycleListener(onStateChange: _lifecycleChanged);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  /// Stops measuring and forgets everything not sent yet.
  void _deactivate() {
    _active = false;
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    if (_hooked) WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    if (ApiClient.observer == recordApi) ApiClient.observer = null;
    _run?.cancel();
    _resetWindow();
    _routes.clear();
    _route = null;
    _held = null;
    _awaited.fillRange(0, _awaited.length, null);
    _awaitedCount = 0;
    _queue.clear();
    // Start times measured before switching off are not sent later.
    _startupSent = true;
  }

  /// Switches sending on or off for this installation. Off: nothing is
  /// sent any more, the queue and the installation id are deleted and
  /// measuring stops; on again, a new installation id is drawn.
  Future<void> setEnabled(bool on) async {
    if (enabled.value == on) return;
    enabled.value = on;
    if (on) {
      _install = _hex(16);
      // Switching off deleted the saved queue.
      _queueRead = true;
      if (available && !_active) {
        _activate();
        _resetWindow();
        if (_device.isEmpty && !_testing) unawaited(_probeDevice());
      }
    } else {
      _deactivate();
      _install = '';
    }
    try {
      await _store.write(_enabledKey, on ? null : '0');
      await _store.write('perf.install', on ? _install : null);
      if (!on) await _store.write('perf.queue', null);
    } catch (_) {
      // The choice holds for this run; a broken store cannot keep it.
    }
  }

  /// Reads the saved choice; a store that cannot be read counts as on.
  Future<bool> _loadEnabled() async {
    try {
      final on = await _store.read(_enabledKey) != '0';
      enabled.value = on;
    } catch (_) {
      // Keeps the current value.
    }
    return enabled.value;
  }

  /// For tests: measures without engine hooks or timers. With
  /// [restoreQueue] the saved queue waits for [restoreForTest], as at a
  /// real start.
  @visibleForTesting
  void startForTest({
    required PerfUplink uplink,
    Map<String, Object>? device,
    bool restoreQueue = false,
  }) {
    _testing = true;
    _queueRead = !restoreQueue;
    _active = enabled.value;
    _uplink = uplink;
    _clock.start();
    _sessionId = _hex(8);
    _install = _hex(16);
    _device = device ?? {'platform': 'android', 'renderer': 'impeller'};
  }

  /// For tests: what [start] loads from the device.
  @visibleForTesting
  Future<void> loadForTest() => _load();

  /// For tests: reads the saved installation id and queue.
  @visibleForTesting
  Future<void> restoreForTest() => _restore();

  Future<void> _load() async {
    if (!await _loadEnabled()) {
      if (!_active) return;
      _deactivate();
      // An id saved by an older version goes as well.
      try {
        await _store.write('perf.install', null);
        await _store.write('perf.queue', null);
      } catch (_) {}
      _queueRead = true;
      return;
    }
    // Switched off (and maybe on again) while the choice was read.
    if (!_active || _install.isNotEmpty) return;
    await _restore();
    await _probeDevice(atStart: true);
  }

  /// The saved installation id and unsent reports.
  Future<void> _restore() async {
    try {
      final saved = await _store.read('perf.install');
      if (saved != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(saved)) {
        _install = saved;
      } else {
        _install = _hex(16);
        await _store.write('perf.install', _install);
      }
      final queued = await _store.read('perf.queue');
      if (queued != null) {
        // Reports queued while this was read were saved already and come
        // back here: the report id keeps each one once.
        final known = {for (final r in _queue) r['rid'], ..._sentIds};
        final saved = [
          for (final r in jsonDecode(queued) as List)
            if (r is Map<String, Object?> &&
                (r['rid'] == null || !known.contains(r['rid'])))
              r,
        ];
        _queue.insertAll(0, saved);
        while (_queue.length > maxQueue) {
          _queue.removeAt(0);
        }
      }
    } catch (_) {
      // A damaged store only costs old reports.
      if (_install.isEmpty) _install = _hex(16);
    }
    _queueRead = true;
    // Saves the merged queue (reports queued meanwhile were not saved).
    await _persist();
  }

  /// Device details; [atStart] also the process age before Dart started.
  Future<void> _probeDevice({bool atStart = false}) async {
    try {
      final asked = _now();
      final device = await platform.probeDevice();
      final age = device.remove('processAgeMs');
      // Process age at the start of Dart: its age when the channel
      // answered minus the time Dart has been running by then.
      if (atStart && age is int) {
        _preMs = max(0, age - (asked + _now()) / 2000);
      }
      _device = device;
    } catch (_) {
      _device = {'platform': kIsWeb ? 'web' : 'other'};
    }
  }

  String _hex(int bytes) => [
    for (var i = 0; i < bytes; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  double _ms() => _now() / 1000;

  // Screens.

  /// Tags [route] (opened with [screen]) with a readable name. Route names
  /// in [RouteSettings] would end up in the browser's address bar.
  static void nameRoute(Route<dynamic> route, Widget screen) =>
      _routeNames[route] = instance.screenName(screen);

  /// Tags [route] with [name] directly, e.g. for routes outside `openPage`.
  static void nameRouteAs(Route<dynamic> route, String name) =>
      _routeNames[route] = name;

  String screenName(Widget screen) {
    final known = screenNames[screen.runtimeType];
    if (known != null) return known;
    final name = screen.runtimeType.toString();
    return name.length < 6 || name.contains(':') ? 'page' : name;
  }

  /// The shell's section (or `gate` before access) shown below all pages.
  void setRoot(String name) {
    if (name == _rootName) return;
    _rootName = name;
    if (_pageName == null) _routeChanged();
  }

  void _pageShown(Route<dynamic>? route) {
    if (route == null || route is PopupRoute) return;
    final tagged = _routeNames[route];
    _pageName = tagged ?? (route.isFirst ? null : 'page');
    _routeChanged();
  }

  void _routeChanged() {
    if (!_active) return;
    _route = null;
    mark('route');
  }

  _RouteStats _currentRoute() {
    final cached = _route;
    if (cached != null) return cached;
    final name = _routes.length >= maxRoutes && !_routes.containsKey(routeName)
        ? 'other'
        : routeName;
    return _route = _routes.putIfAbsent(name, _RouteStats.new);
  }

  /// Notes an app event (e.g. `route`, `api`, `resume`) as context for a
  /// following slow frame.
  void mark(String event) => _eventAt[event] = _now();

  /// [count] pictures were handed to the screen in this frame (decoded
  /// costumes in the wardrobe); a slow frame then lists `img`.
  static void markImage(int count) {
    if (count > 0 && instance._active) instance.mark('img');
  }

  /// The events of the last second before [nowUs], e.g. `route,api`.
  String? _eventsBefore(int nowUs) {
    String? out;
    for (final e in _eventAt.entries) {
      if (e.value <= nowUs - 1000000) continue;
      out = out == null ? e.key : '$out,${e.key}';
    }
    return out;
  }

  /// The app shows content (from the cache or the first sync).
  void markReady() {
    if (!_active || _readyMs != null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) => _readyMs ??= _ms());
  }

  // Frames.

  void _watchInput(ui.PlatformDispatcher dispatcher) {
    final original = dispatcher.onPointerDataPacket;
    if (original == null) return;
    dispatcher.onPointerDataPacket = (packet) {
      if (!_active) return original(packet);
      final at = _now();
      original(packet);
      if (packet.data.isEmpty) return;
      final d = packet.data.first;
      final kind = d.signalKind == ui.PointerSignalKind.scroll
          ? 'wheel'
          : switch (d.change) {
              ui.PointerChange.down || ui.PointerChange.up => 'tap',
              ui.PointerChange.move => 'drag',
              ui.PointerChange.panZoomStart ||
              ui.PointerChange.panZoomUpdate => 'zoom',
              _ => null,
            };
      if (kind != null) {
        inputArrived(
          at,
          kind,
          requestedFrame: SchedulerBinding.instance.hasScheduledFrame,
        );
      }
    };
  }

  /// Input of [kind] arrived at [atUs]; it counts as the start of the next
  /// frame when it requested one.
  @visibleForTesting
  void inputArrived(int atUs, String kind, {required bool requestedFrame}) {
    _lastInput = kind;
    _lastInputUs = atUs;
    if (requestedFrame && _inputAt < 0) _inputAt = atUs;
  }

  void _onFrame(Duration _) {
    if (!_active) return;
    frameEnded(
      _now(),
      nextScheduled: SchedulerBinding.instance.hasScheduledFrame,
    );
  }

  /// A frame was built at [nowUs]. While frames follow each other (an
  /// animation requested the next one), the frame time is the distance to
  /// the previous frame; for a frame caused by input it is the time since
  /// the input. Other frames (after idle pauses) are not sampled.
  @visibleForTesting
  void frameEnded(int nowUs, {required bool nextScheduled}) {
    double? sample;
    String? input;
    if (!_suspended) {
      if (_continuous && _lastFrameUs >= 0) {
        sample = (nowUs - _lastFrameUs) / 1000;
      } else if (_inputAt >= 0) {
        sample = (nowUs - _inputAt) / 1000;
        input = _lastInput;
      }
    }
    _lastFrameUs = nowUs;
    _inputAt = -1;
    _continuous = nextScheduled;
    // Longer gaps are suspended pages (e.g. a locked screen), not frames.
    if (sample != null && sample >= 0 && sample < 5000) {
      _record(sample, nowUs, input);
    }
  }

  void _record(double ms, int nowUs, String? input) {
    _commitHeld();
    final route = _currentRoute();
    WorstFrame? worst;
    if (_worst.qualifies(ms)) {
      worst = WorstFrame(
        ms,
        route: routeName,
        at: nowUs / 1e6,
        input: input ?? (_lastInputUs > nowUs - 1000000 ? _lastInput : null),
        events: _eventsBefore(nowUs),
      );
      _awaitTimings(worst, ms);
    }
    if (ms > _holdMs) {
      _held = _HeldFrame(ms, nowUs, route, worst);
    } else {
      _add(ms, route, worst);
    }
  }

  void _add(double ms, _RouteStats route, WorstFrame? worst) {
    _frames.add(ms);
    route.frames.add(ms);
    if (worst != null) _worst.offer(worst);
  }

  /// Counts the held frame: the app went on drawing after it.
  void _commitHeld() {
    final held = _held;
    if (held == null) return;
    _held = null;
    _add(held.ms, held.route, held.worst);
  }

  /// Notes [worst] (of [ms], ending in the current frame) for the build and
  /// raster times of the frames that began meanwhile.
  void _awaitTimings(WorstFrame worst, double ms) {
    final vsync = _vsyncNow();
    if (vsync < 0) return;
    // The engine's vsync stamp is the frame's start or its target time,
    // and the web engine reads its clock a moment after the browser: the
    // window is generous by 2 ms on both sides.
    if (_awaited[_awaitedNext] == null) _awaitedCount++;
    _awaited[_awaitedNext] = _AwaitedTiming(
      worst,
      vsync - (ms * 1000).round() - 2000,
      vsync + 2000,
    );
    _awaitedNext = (_awaitedNext + 1) % _awaited.length;
  }

  /// Gives the worst frames around [vsyncUs] the longest [build] and
  /// [raster] time.
  void _matchTiming(int vsyncUs, double build, double raster) {
    if (_awaitedCount == 0) return;
    for (var i = 0; i < _awaited.length; i++) {
      final a = _awaited[i];
      if (a == null) continue;
      if (vsyncUs > a.toUs + 1000000) {
        // Timings arrive in order: nothing for this one will come.
        _awaited[i] = null;
        _awaitedCount--;
      } else if (vsyncUs >= a.fromUs && vsyncUs <= a.toUs) {
        final f = a.frame;
        f.build = max(f.build ?? 0, build);
        f.raster = max(f.raster ?? 0, raster);
      }
    }
  }

  void _onTimings(List<ui.FrameTiming> timings) {
    if (_suspended) return;
    final route = _currentRoute(), run = _run;
    for (final t in timings) {
      final build = _phase(
        t,
        ui.FramePhase.buildFinish,
        ui.FramePhase.buildStart,
      );
      final raster = _phase(
        t,
        ui.FramePhase.rasterFinish,
        ui.FramePhase.rasterStart,
      );
      final total = _phase(
        t,
        ui.FramePhase.rasterFinish,
        ui.FramePhase.vsyncStart,
      );
      _timing(build, raster, total, route, run);
      _matchTiming(
        t.timestampInMicroseconds(ui.FramePhase.vsyncStart),
        build,
        raster,
      );
    }
  }

  static double _phase(
    ui.FrameTiming t,
    ui.FramePhase end,
    ui.FramePhase start,
  ) =>
      (t.timestampInMicroseconds(end) - t.timestampInMicroseconds(start)) /
      1000;

  /// One FrameTiming: build, raster and total span in ms, for the frame
  /// whose vsync was at [vsyncUs].
  @visibleForTesting
  void recordTiming(
    double build,
    double raster,
    double total, {
    int vsyncUs = -1,
  }) {
    _timing(build, raster, total, _currentRoute(), _run);
    if (vsyncUs >= 0) _matchTiming(vsyncUs, build, raster);
  }

  void _timing(
    double build,
    double raster,
    double total,
    _RouteStats route,
    PerfRunRecorder? run,
  ) {
    _timings++;
    _build.add(build);
    _raster.add(raster);
    _total.add(total);
    route.build.add(build);
    route.raster.add(raster);
    run?._timing(build, raster);
  }

  // API.

  /// Called by [ApiClient] for every request; [status] 0 means no answer.
  /// A call that was [overdue] or across a trip to the background only
  /// counts as paused (`susp`): it measured the pause, not the network.
  void recordApi(
    String method,
    String path,
    int status,
    Duration elapsed, {
    double? serverMs,
    bool overdue = false,
  }) {
    if (!_active || path.startsWith('/telemetry/')) return;
    final pattern = apiPathPattern(path);
    final ms = elapsed.inMicroseconds / 1000;
    final now = _now();
    final paused =
        overdue ||
        (_pausedUs >= 0 && _pausedUs >= now - elapsed.inMicroseconds);
    if (_api.length < 40 || _api.containsKey('$method $pattern')) {
      _api
          .putIfAbsent('$method $pattern', LatencyStats.new)
          .add(
            ms,
            error: status >= 400,
            isOffline: status == 0,
            isSuspended: paused,
            serverMs: serverMs,
          );
    }
    if (pattern == '/snapshot' && status >= 200 && status < 300) {
      _dataMs ??= _ms();
    }
    // Costume pictures and sounds are decoded after the answer: their own
    // event tells them apart from data.
    if (status != 0) {
      mark(pattern.startsWith('/games/runner/skins/') ? 'skin' : 'api');
    }
  }

  // Stage runner.

  /// A recorder for one run; inert while the telemetry is off.
  PerfRunRecorder beginRun() {
    _run?.cancel();
    final run = PerfRunRecorder._(_active ? this : null);
    if (_active) _run = run;
    return run;
  }

  void _finishRun(PerfRunRecorder run, Map<String, Object>? details) {
    if (identical(_run, run)) _run = null;
    if (details == null || run.frames.count == 0 || _uplink?.isDemo == true) {
      return;
    }
    _enqueue({
      ..._header('stageRunner'),
      'frames': run._framesJson(),
      'run': details,
      if (!run._worst.isEmpty) 'worst': run._worst.toJson(),
    });
  }

  // Reports.

  Map<String, Object?> _header(String kind) {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final dpr = view?.devicePixelRatio ?? 0;
    return {
      'v': 1,
      'kind': kind,
      'install': _install,
      'session': _sessionId,
      'seq': _seq++,
      'up': (_ms() / 100).roundToDouble() / 10,
      'device': {
        ..._device,
        ...platform.currentContext(),
        if (dpr > 0) ...{
          'dpr': (dpr * 100).roundToDouble() / 100,
          'w': (view!.physicalSize.width / dpr).round(),
          'h': (view.physicalSize.height / dpr).round(),
          // The web engine always reports 60 Hz.
          if (!kIsWeb) 'hz': view.display.refreshRate.roundToDouble(),
        },
        'mode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
      },
      'app': {
        'version': appVersion,
        if (appBuild.isNotEmpty) 'build': appBuild,
      },
    };
  }

  Map<String, Object>? get _startup {
    if (_startupSent || _firstFrameMs == null) return null;
    final pre = _preMs;
    final kind =
        _startInfo['kind'] ??
        (kIsWeb || pre == null
            ? null
            : pre > 5000
            ? 'warm'
            : 'cold');
    _fcpMs ??= platform.firstPaintMs();
    return {
      'kind': ?kind,
      'nav': ?_startInfo['nav'],
      'vis': ?_startInfo['vis'],
      if (_hiddenAtStart) 'hidden': true,
      if (pre != null) 'preMs': pre.round(),
      if (_fcpMs != null) 'fcp': _fcpMs!.round(),
      'firstFrameMs': _firstFrameMs!.round(),
      if (_readyMs != null) 'readyMs': _readyMs!.round(),
      if (_dataMs != null) 'dataMs': _dataMs!.round(),
    };
  }

  bool get _hasWindowData =>
      _frames.count > 0 || _api.isNotEmpty || _startup != null;

  /// The report of the current window (frames, screens, API, start).
  @visibleForTesting
  Map<String, Object?> buildReport() {
    _commitHeld();
    final routes =
        _routes.entries.where((e) => e.value.frames.count > 0).toList()..sort(
          (a, b) => b.value.frames.count.compareTo(a.value.frames.count),
        );
    final api = _api.entries.toList()
      ..sort((a, b) => b.value.count.compareTo(a.value.count));
    final startup = _startup;
    return {
      ..._header('app'),
      'span': (_now() - _windowStartUs) ~/ 1000,
      'startup': ?startup,
      if (_frames.count > 0)
        'frames': {
          ..._frames.toJson(),
          'ft': _timings,
          if (_timings > 0) ..._timingJson(_build, _raster, _total),
        },
      'routes': [
        for (final e in routes)
          {
            'r': e.key,
            ...e.value.frames.toJson(),
            if (e.value.build.count > 0) ...{
              'b95': ((e.value.build.quantile(0.95) ?? 0) * 10).round() / 10,
              'r95': ((e.value.raster.quantile(0.95) ?? 0) * 10).round() / 10,
            },
          },
      ],
      if (!_worst.isEmpty) 'worst': _worst.toJson(),
      'api': [
        for (final e in api)
          e.value.toJson(e.key.split(' ').first, e.key.split(' ').last),
      ],
    };
  }

  /// Shortens [report] to [maxBytes] of JSON by dropping the least used
  /// screens and API calls, then details.
  static Map<String, Object?> fit(Map<String, Object?> report) {
    int size() => utf8.encode(jsonEncode(report)).length;
    final routes = report['routes'] as List? ?? [];
    final api = report['api'] as List? ?? [];
    var bytes = size();
    while (bytes > maxBytes && (routes.length > 1 || api.length > 1)) {
      (routes.length >= api.length ? routes : api).removeLast();
      bytes = size();
    }
    for (final drop in ['worst', 'routes', 'api']) {
      if (bytes <= maxBytes) break;
      report.remove(drop);
      bytes = size();
    }
    if (routes.isEmpty) report.remove('routes');
    if (api.isEmpty) report.remove('api');
    return report;
  }

  void _resetWindow() {
    _windowStartUs = _now();
    _frames.reset();
    _build.reset();
    _raster.reset();
    _total.reset();
    _timings = 0;
    _worst.reset();
    for (final r in _routes.values) {
      r.reset();
    }
    _api.clear();
  }

  /// Ends the current window and queues its report (dropped in the demo).
  @visibleForTesting
  void closeWindow() {
    _commitHeld();
    if (!_active || !_hasWindowData) return;
    if (_uplink?.isDemo == true) {
      _resetWindow();
      return;
    }
    final report = buildReport();
    if (report.containsKey('startup')) _startupSent = true;
    _resetWindow();
    _enqueue(report);
  }

  void _enqueue(Map<String, Object?> report) {
    if (!_active) return;
    // The id lets the server and [_restore] keep a report sent twice once.
    _queue.add(fit({...report, 'rid': _hex(8)}));
    while (_queue.length > maxQueue) {
      _queue.removeAt(0);
    }
    unawaited(_persist());
  }

  Future<void> _persist() async {
    if (!_queueRead) return;
    try {
      await _store.write(
        'perf.queue',
        _queue.isEmpty ? null : jsonEncode(_queue),
      );
    } catch (_) {
      // Unsent reports may get lost; measuring goes on.
    }
  }

  /// Sends queued reports, at most four at a time. Without the server
  /// feature or in the demo they are dropped; without access they wait.
  Future<void> flush() async {
    final uplink = _uplink;
    if (!_active || _flushing || uplink == null || _queue.isEmpty) return;
    _flushing = true;
    try {
      if (uplink.isDemo ||
          (uplink.hasAccess &&
              uplink.featuresKnown &&
              !uplink.supports(feature))) {
        _queue.clear();
        await _persist();
        return;
      }
      if (!uplink.hasAccess || !uplink.featuresKnown || _install.isEmpty) {
        return;
      }
      for (var sent = 0; sent < 4 && _queue.isNotEmpty; sent++) {
        final report = _queue.first;
        // Reports queued before the id was loaded get it now.
        if (report['install'] == '') report['install'] = _install;
        await uplink.send(report);
        _queue.remove(report);
        _sentIds.add(report['rid']);
        if (_sentIds.length > 32) _sentIds.removeAt(0);
        // Saved after every report: a page closed while sending would
        // otherwise send the earlier ones again on the next start.
        await _persist();
      }
    } catch (_) {
      // Offline or signed out: the reports wait for the next try.
      await _persist();
    } finally {
      _flushing = false;
    }
  }

  void _tick() {
    final now = _now();
    // Only while nothing is drawn, so a game or an animation never waits.
    final idle = now - _lastFrameUs > 2000000;
    if (!idle) return;
    if (now - _windowStartUs >= sendInterval.inMicroseconds) closeWindow();
    unawaited(flush());
  }

  @visibleForTesting
  void lifecycleChangedForTest(AppLifecycleState state) =>
      _lifecycleChanged(state);

  void _lifecycleChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _epoch++;
      _pausedUs = _now();
      _suspended = false;
      _continuous = false;
      _lastFrameUs = -1;
      mark('resume');
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _suspended = true;
      _continuous = false;
      _background();
    }
  }

  void _background() {
    if (!_active) return;
    if (_firstFrameMs == null) _hiddenAtStart = true;
    final now = _now(), held = _held;
    // A long frame right before this measured the way into the background.
    if (held != null && now - held.atUs < _holdUs) _held = null;
    _epoch++;
    _pausedUs = now;
    _suspended = true;
    _continuous = false;
    closeWindow();
    unawaited(flush());
  }

  @visibleForTesting
  void stopForTest() {
    _timer?.cancel();
    _lifecycle?.dispose();
    _active = false;
  }
}

/// Follows the visible page of the root navigator.
class _PerfRouteObserver extends NavigatorObserver {
  _PerfRouteObserver(this._owner);
  final PerfTelemetry _owner;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _owner._pageShown(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _owner._pageShown(previousRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.isCurrent ?? false) _owner._pageShown(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute?.isCurrent ?? false) _owner._pageShown(newRoute);
  }
}
