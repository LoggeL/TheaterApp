import 'dart:math' as math;
import 'dart:typed_data';

/// Upper bounds (ms, inclusive) of the frame-time buckets sent to the server;
/// the last bucket is open. Same edges as `server/src/perf-telemetry.mjs`,
/// so the server can merge reports exactly.
const frameEdges = <double>[
  4, 8, 10, 12, 14, 16, 18, 20, 25, 33, 50, 67, 100, 150, 250, 500, 1000, //
];

/// Upper bounds (ms, inclusive) of the API latency buckets.
const latencyEdges = <double>[
  50, 100, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000, //
];

/// Upper bounds (ms, inclusive) of the server time buckets
/// (`Server-Timing: app;dur`), finer than the latency ones because the
/// server itself mostly needs a few milliseconds.
const serverEdges = <double>[
  1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, //
];

/// Index of the first bucket whose upper bound is at least [value].
int bucketOf(List<double> edges, double value) {
  for (var i = 0; i < edges.length; i++) {
    if (value <= edges[i]) return i;
  }
  return edges.length;
}

double _round(double v) => (v * 10).roundToDouble() / 10;

/// Frame times of one window (a session part, a screen or a game run):
/// a fine histogram for the percentiles, the coarse one for the server,
/// the longest frame and the jank counts. [add] never allocates.
class FrameStats {
  /// Fine buckets: 0.5 ms to 50 ms, 1 ms to 100 ms, 5 ms to 250 ms,
  /// 25 ms to 1 s, one open bucket above.
  static const _fineCount = 100 + 50 + 30 + 30 + 1;
  final _fine = Int32List(_fineCount);
  final _coarse = Int32List(frameEdges.length + 1);
  int count = 0, over25 = 0, over50 = 0, over100 = 0;
  double total = 0, max = 0;

  static int _fineIndex(double ms) {
    if (ms < 50) return ms <= 0 ? 0 : (ms * 2).floor();
    if (ms < 100) return 100 + (ms - 50).floor();
    if (ms < 250) return 150 + ((ms - 100) / 5).floor();
    if (ms < 1000) return 180 + ((ms - 250) / 25).floor();
    return _fineCount - 1;
  }

  static double _fineStart(int i) => i < 100
      ? i / 2
      : i < 150
      ? 50.0 + (i - 100)
      : i < 180
      ? 100.0 + (i - 150) * 5
      : i < 210
      ? 250.0 + (i - 180) * 25
      : 1000;

  static double _fineWidth(int i) => i < 100
      ? 0.5
      : i < 150
      ? 1
      : i < 180
      ? 5
      : 25;

  void add(double ms) {
    count++;
    total += ms;
    if (ms > max) max = ms;
    if (ms > 25) {
      over25++;
      if (ms > 50) {
        over50++;
        if (ms > 100) over100++;
      }
    }
    _fine[_fineIndex(ms)]++;
    _coarse[bucketOf(frameEdges, ms)]++;
  }

  /// The [q] quantile (0..1), interpolated inside its fine bucket.
  double? quantile(double q) {
    if (count == 0) return null;
    var target = q * count;
    for (var i = 0; i < _fineCount; i++) {
      final n = _fine[i];
      if (n == 0) continue;
      if (target <= n) {
        if (i == _fineCount - 1) return max;
        return math.min(_fineStart(i) + _fineWidth(i) * (target / n), max);
      }
      target -= n;
    }
    return max;
  }

  void reset() {
    _fine.fillRange(0, _fineCount, 0);
    _coarse.fillRange(0, _coarse.length, 0);
    count = over25 = over50 = over100 = 0;
    total = max = 0;
  }

  /// Frame statistics as sent: count, displayed time, percentiles, longest
  /// frame, jank counts and the coarse histogram.
  Map<String, Object> toJson() => {
    'n': count,
    'ms': total.round(),
    'p50': _round(quantile(0.5) ?? 0),
    'p95': _round(quantile(0.95) ?? 0),
    'p99': _round(quantile(0.99) ?? 0),
    'max': _round(max),
    'j25': over25,
    'j50': over50,
    'j100': over100,
    'h': List<int>.of(_coarse),
  };
}

/// Durations reported by the engine (FrameTiming); only percentiles.
class TimingStats {
  final _frames = FrameStats();
  int get count => _frames.count;
  void add(double ms) => _frames.add(ms);
  double? quantile(double q) => _frames.quantile(q);
  void reset() => _frames.reset();
}

/// One of the worst frames with what happened around it.
class WorstFrame {
  WorstFrame(
    this.ms, {
    this.route,
    this.at,
    this.input,
    this.events,
    this.meters,
  });
  final double ms;
  final String? route, input, events;

  /// The longest build and raster time (FrameTiming) of the frames around
  /// this one; filled in when the engine reports them, a little later.
  double? build, raster;

  /// Seconds since the app (or the run) started.
  final double? at;

  /// Metres into a stage runner run.
  final int? meters;

  Map<String, Object> toJson() => {
    'ms': _round(ms),
    'r': ?route,
    if (at != null) 't': _round(at!),
    'in': ?input,
    'ev': ?events,
    'm': ?meters,
    if (build != null) 'b': _round(build!),
    if (raster != null) 'ra': _round(raster!),
  };
}

/// Keeps the [capacity] longest frames above 25 ms. Callers check
/// [qualifies] first, so ordinary frames allocate nothing.
class WorstFrames {
  WorstFrames([this.capacity = 5]);
  final int capacity;
  final _items = <WorstFrame>[];

  bool qualifies(double ms) =>
      ms > 25 && (_items.length < capacity || ms > _items.last.ms);

  void offer(WorstFrame frame) {
    if (!qualifies(frame.ms)) return;
    var i = _items.length;
    while (i > 0 && _items[i - 1].ms < frame.ms) {
      i--;
    }
    _items.insert(i, frame);
    if (_items.length > capacity) _items.removeLast();
  }

  bool get isEmpty => _items.isEmpty;
  void reset() => _items.clear();
  List<Map<String, Object>> toJson() => [for (final f in _items) f.toJson()];
}

/// Latencies of one API call pattern.
class LatencyStats {
  final _coarse = Int32List(latencyEdges.length + 1);
  final _server = Int32List(serverEdges.length + 1);
  final _samples = <double>[];
  int count = 0, errors = 0, offline = 0, suspended = 0, _serverCount = 0;
  double max = 0;

  /// One call of [ms]; [serverMs] is the server's own time when it sent
  /// one. A [isSuspended] call spanned a pause of the app (background,
  /// frozen tab): it only counts, its time says nothing about the network.
  void add(
    double ms, {
    bool error = false,
    bool isOffline = false,
    bool isSuspended = false,
    double? serverMs,
  }) {
    count++;
    if (serverMs != null) {
      _serverCount++;
      _server[bucketOf(serverEdges, serverMs)]++;
    }
    if (isSuspended) {
      suspended++;
      return;
    }
    if (isOffline) {
      offline++;
    } else if (error) {
      errors++;
    }
    if (isOffline) return;
    if (ms > max) max = ms;
    _coarse[bucketOf(latencyEdges, ms)]++;
    // Enough for the percentiles of one window; API calls are rare.
    if (_samples.length < 200) _samples.add(ms);
  }

  double? quantile(double q) {
    if (_samples.isEmpty) return null;
    final sorted = List<double>.of(_samples)..sort();
    final pos = (sorted.length - 1) * q, lo = pos.floor(), hi = pos.ceil();
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }

  Map<String, Object> toJson(String method, String path) => {
    'm': method,
    'p': path,
    'n': count,
    'err': errors,
    'off': offline,
    if (suspended > 0) 'susp': suspended,
    if (_serverCount > 0) 'srv': List<int>.of(_server),
    if (_samples.isNotEmpty) ...{
      'p50': quantile(0.5)!.roundToDouble(),
      'p95': quantile(0.95)!.roundToDouble(),
      'max': max.roundToDouble(),
      'h': List<int>.of(_coarse),
    },
  };
}

/// Collections whose next path segment is an id.
const _idCollections = {
  'productions',
  'events',
  'galleries',
  'assets',
  'media',
  'feedback',
  'accounts',
  'website-profiles',
  'skins',
};

final _idLike = RegExp(r'[0-9.%:@]');
final _fileType = RegExp(r'\.([a-z0-9]{2,4})$');

/// The API [path] without ids or query, e.g. `/productions/:id/script`.
/// Costume files keep their type (`/games/runner/skins/:id.webp`), so
/// pictures and music can be told apart.
String apiPathPattern(String path) {
  final clean = path.split('?').first;
  final segments = clean.split('/').where((s) => s.isNotEmpty).toList();
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    final collection = i > 0 ? segments[i - 1] : null;
    final afterCollection = _idCollections.contains(collection);
    // `/admin/feedback/<id>` and `/feedback/<id>` hold ids; a static word
    // after an id (`script`, `messages`) never contains digits or dots.
    final looksLikeId = _idLike.hasMatch(s) || s.length > 24;
    if (afterCollection || looksLikeId) {
      final type = collection == 'skins' ? _fileType.firstMatch(s) : null;
      segments[i] = type == null ? ':id' : ':id.${type.group(1)}';
    }
  }
  return '/${segments.join('/')}';
}

/// Browser, operating system and form factor read from a user agent.
typedef UserAgentInfo = ({String browser, String os, bool mobile});

UserAgentInfo parseUserAgent(String ua) {
  String? version(String pattern) => RegExp(pattern).firstMatch(ua)?.group(1);
  String major(String? v) => v == null ? '' : ' ${v.split('.').first}';
  String majorMinor(String? v) {
    if (v == null) return '';
    final parts = v.replaceAll('_', '.').split('.');
    return ' ${parts.take(2).join('.')}';
  }

  final ios = RegExp(r'iPhone|iPad|iPod').hasMatch(ua);
  final android = ua.contains('Android');
  final os = ios
      ? 'iOS${majorMinor(version(r'OS (\d+[_.]\d+)'))}'
      : android
      ? 'Android${major(version(r'Android (\d+)'))}'
      : ua.contains('CrOS')
      ? 'ChromeOS'
      : ua.contains('Mac OS X')
      ? 'macOS'
      : ua.contains('Windows')
      ? 'Windows'
      : ua.contains('Linux')
      ? 'Linux'
      : 'other';
  final edge = version(r'Edg(?:A|iOS)?/(\d+)');
  final samsung = version(r'SamsungBrowser/(\d+)');
  final opera = version(r'(?:OPR|OPT)/(\d+)');
  final firefox = version(r'(?:Firefox|FxiOS)/(\d+)');
  final chrome = version(r'(?:Chrome|CriOS)/(\d+)');
  final safari = version(r'Version/(\d+(?:\.\d+)?).*Safari');
  final browser = edge != null
      ? 'Edge${major(edge)}'
      : samsung != null
      ? 'Samsung Internet${major(samsung)}'
      : opera != null
      ? 'Opera${major(opera)}'
      : firefox != null
      ? 'Firefox${major(firefox)}'
      : chrome != null
      ? 'Chrome${major(chrome)}'
      : safari != null
      ? 'Safari $safari'
      // In-app web views on iOS (no Version/…), e.g. in messengers.
      : ios
      ? 'iOS WebView'
      : ua.length > 40
      ? ua.substring(0, 40)
      : ua;
  final mobile =
      ios || RegExp(r'Mobile|Android').hasMatch(ua) && !ua.contains('Tablet');
  return (browser: browser, os: os, mobile: mobile);
}
