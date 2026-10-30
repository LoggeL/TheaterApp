import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'perf_stats.dart';

// Optional browser APIs, read as nullable: Safari and Firefox lack some.
extension type _Navigator(JSObject _) implements JSObject {
  external JSString? get userAgent;
  external JSNumber? get hardwareConcurrency;
  external JSNumber? get deviceMemory;
  external JSNumber? get maxTouchPoints;
  external JSBoolean? get standalone;
  external _Connection? get connection;
  external _ServiceWorkers? get serviceWorker;
}

extension type _ServiceWorkers(JSObject _) implements JSObject {
  external JSObject? get controller;
}

extension type _Connection(JSObject _) implements JSObject {
  external JSString? get effectiveType;
}

extension type _Entry(JSObject _) implements JSObject {
  external JSString? get name;
  external JSString? get type;
  external JSNumber? get transferSize;
  external JSNumber? get decodedBodySize;
  external JSNumber? get startTime;
}

_Navigator get _navigator => _Navigator(web.window.navigator);

/// Milliseconds since the page started loading (`performance.now()`).
double? pageClockMs() => web.window.performance.now();

bool _standalone() =>
    web.window.matchMedia('(display-mode: standalone)').matches ||
    _navigator.standalone?.toDart == true;

/// Device facts that do not change while the app runs.
Future<Map<String, Object>> probeDevice() async {
  final nav = _navigator;
  final parsed = parseUserAgent(nav.userAgent?.toDart ?? '');
  var os = parsed.os, mobile = parsed.mobile;
  // iPadOS Safari presents itself as a Mac; only the touch points tell.
  if (os == 'macOS' && (nav.maxTouchPoints?.toDartInt ?? 0) > 1) {
    os = 'iPadOS';
    mobile = true;
  }
  final cores = nav.hardwareConcurrency?.toDartInt;
  final memory = nav.deviceMemory?.toDartDouble;
  return {
    'platform': 'web',
    // Flutter's loader starts the dart2wasm build with skwasm where WasmGC
    // exists (Chromium) and the dart2js build with CanvasKit elsewhere.
    'renderer': kIsWasm ? 'skwasm' : 'canvaskit',
    'compiler': kIsWasm ? 'dart2wasm' : 'dart2js',
    'browser': parsed.browser,
    'os': os,
    'mobile': mobile,
    'pwa': _standalone(),
    'cores': ?cores,
    'mem': ?memory,
  };
}

/// Context that can change while the app runs.
Map<String, Object> currentContext() {
  final net = _navigator.connection?.effectiveType?.toDart;
  return {'pwa': _standalone(), 'net': ?net};
}

/// How the page was loaded: the navigation type, whether the page was
/// visible and whether the app code came from a cache (HTTP cache or
/// service worker) instead of the network.
Map<String, Object> startInfo() {
  final out = <String, Object>{};
  try {
    out['vis'] = web.document.visibilityState;
    final performance = web.window.performance;
    final navigation = performance.getEntriesByType('navigation').toDart;
    final type = navigation.isEmpty ? null : _Entry(navigation.first).type;
    if (type != null) out['nav'] = type.toDart;
    for (final entry in performance.getEntriesByType('resource').toDart) {
      final e = _Entry(entry), name = e.name?.toDart ?? '';
      if (!RegExp(r'/main(\.[a-f0-9]+)?\.dart\.(wasm|js)$').hasMatch(name)) {
        continue;
      }
      final transferred = e.transferSize?.toDartDouble;
      final size = e.decodedBodySize?.toDartDouble ?? 0;
      // Cross-origin or unsupported entries report 0 for both.
      if (transferred != null && size > 0) {
        out['kind'] = transferred == 0 ? 'cached' : 'network';
      }
      break;
    }
    // Safari reports no sizes; a page under a service worker got the code
    // from its cache (theater-service-worker.js caches the app shell).
    if (!out.containsKey('kind') &&
        _navigator.serviceWorker?.controller != null) {
      out['kind'] = 'sw';
    }
  } catch (_) {
    // Timing APIs are optional; the start is reported without them.
  }
  return out;
}

/// Milliseconds from the navigation to the first contentful paint, once
/// the browser has painted (Safari since 14.1, not Firefox before 84).
double? firstPaintMs() {
  try {
    final paints = web.window.performance
        .getEntriesByName('first-contentful-paint')
        .toDart;
    return paints.isEmpty ? null : _Entry(paints.first).startTime?.toDartDouble;
  } catch (_) {
    return null;
  }
}

/// Calls [hidden] when the page is hidden or closed.
void onPageHidden(void Function() hidden) {
  web.document.addEventListener(
    'visibilitychange',
    ((web.Event _) {
      if (web.document.visibilityState == 'hidden') hidden();
    }).toJS,
  );
  web.window.addEventListener('pagehide', ((web.Event _) => hidden()).toJS);
}
