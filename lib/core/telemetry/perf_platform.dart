// Device context for the performance telemetry: the browser on the web,
// a small platform channel of MainActivity on Android.
export 'perf_platform_io.dart'
    if (dart.library.js_interop) 'perf_platform_web.dart';
