import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';
import 'http_client_io.dart'
    if (dart.library.js_interop) 'http_client_web.dart';

class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode = 0,
    this.code,
    this.retryAfter,
  });
  final String message;
  final int statusCode;

  /// The server's `Retry-After` wait, when it sent one in seconds.
  final Duration? retryAfter;

  /// The server's machine-readable reason, e.g. `closed` or
  /// `version_conflict`; null for older servers and local errors.
  final String? code;
  bool get isUnauthorized => statusCode == 401;
  bool get retryable =>
      statusCode == 0 ||
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode >= 500;
  @override
  String toString() => message;
}

/// Sees a request's method, path, status (0: no answer) and duration, the
/// server's own time (`Server-Timing: app;dur`) when it sent one, and
/// whether the call took longer than its timeouts allow (the app was frozen
/// meanwhile, e.g. a tab in the background).
typedef ApiObserver =
    void Function(
      String method,
      String path,
      int status,
      Duration elapsed, {
      double? serverMs,
      bool overdue,
    });

/// API origin is configuration. Credentials never go to redirects or script URLs.
class ApiClient {
  ApiClient({http.Client? client, this.timeout = const Duration(seconds: 20)})
    : _client = client ?? createHttpClient();
  final http.Client _client;
  final Duration timeout;
  Future<String> Function(String expectedUid)? firebaseToken;
  static const pathPrefix = '/api/mobile/v1';

  /// Sees every request; set by the performance telemetry.
  static ApiObserver? observer;

  /// Waiting for the bytes of a picture or sound may take this long, both
  /// for the answer and between two chunks.
  static const _binaryTimeout = Duration(seconds: 30);

  /// A wait longer than its timeout by this much means the timer fired
  /// late, which happens only when the app was not running meanwhile.
  static const _late = Duration(seconds: 1);

  /// Measures each request; tests can replace it.
  @visibleForTesting
  static Stopwatch Function() stopwatch = Stopwatch.new;

  /// The server's own time from `Server-Timing` (`app;dur=1.2`), or null.
  static double? serverTimeOf(String? header) {
    if (header == null) return null;
    final match = RegExp(
      r'(?:^|,)\s*app\s*;(?:[^,]*;)?\s*dur=([0-9]+(?:\.[0-9]+)?)',
    ).firstMatch(header);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  static void _observe(
    String method,
    String path,
    int status,
    Duration elapsed,
    String? serverTiming, {
    required bool overdue,
  }) => observer?.call(
    method,
    path,
    status,
    elapsed,
    serverMs: serverTimeOf(serverTiming),
    overdue: overdue,
  );

  static String normalizeBaseUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !const ['', '/'].contains(uri.path)) {
      throw const ApiException(
        'Bitte eine Serveradresse ohne Pfad eingeben, zum Beispiel https://theater.example.de.',
      );
    }
    final localDebug =
        kDebugMode &&
        const bool.fromEnvironment('ALLOW_INSECURE_HTTP') &&
        const {'localhost', '127.0.0.1', '10.0.2.2', '::1'}.contains(uri.host);
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && localDebug)) {
      throw const ApiException(
        'Die Serveradresse muss HTTPS verwenden. Lokales HTTP ist nur im ausdrücklich aktivierten Debug-Modus erlaubt.',
      );
    }
    return uri.replace(path: '').toString().replaceFirst(RegExp(r'/$'), '');
  }

  Future<JsonMap> request(
    String baseUrl,
    String method,
    String path, {
    String? token,
    JsonMap? body,
    String? idempotencyKey,
  }) async {
    final origin = normalizeBaseUrl(baseUrl);
    // The existing Next.js deployment uses trailingSlash:true. Avoid a 308
    // redirect (especially on POST); redirects intentionally never get tokens.
    final relative = Uri.parse(path);
    final canonicalPath = relative.path.endsWith('/')
        ? relative.path
        : '${relative.path}/';
    final uri = Uri.parse(
      '$origin$pathPrefix$canonicalPath',
    ).replace(query: relative.hasQuery ? relative.query : null);
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (token != null) {
      final actualToken = token.startsWith('firebase:')
          ? await (firebaseToken?.call(token.substring(9)) ??
                Future<String>.error(
                  const ApiException('Bitte erneut anmelden.', statusCode: 401),
                ))
          : token;
      request.headers['Authorization'] = 'Bearer $actualToken';
    }
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final watch = stopwatch()..start();
    var status = 0;
    String? serverTiming;
    try {
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
      status = response.statusCode;
      serverTiming = response.headers['server-timing'];
      if (response.bodyBytes.length > 30 * 1024 * 1024) {
        throw const ApiException(
          'Die Serverantwort ist zu groß. Bitte die Produktion in kleinere Abschnitte aufteilen.',
          statusCode: 413,
        );
      }
      JsonMap decoded;
      try {
        decoded = response.body.isEmpty
            ? <String, dynamic>{}
            : jsonMap(jsonDecode(utf8.decode(response.bodyBytes)));
      } on FormatException {
        throw ApiException(
          'Der Server hat keine gültige API-Antwort geliefert.',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final serverMessage = decoded['error'];
        throw ApiException(
          serverMessage is String && serverMessage.length <= 600
              ? serverMessage
              : 'Die Anfrage wurde vom Server abgelehnt (${response.statusCode}).',
          statusCode: response.statusCode,
          code: _errorCode(decoded['code']),
          retryAfter: retryAfterOf(response.headers['retry-after']),
        );
      }
      return decoded;
    } on TimeoutException {
      throw const ApiException(
        'Der Server antwortet nicht rechtzeitig. Die Verbindung kann später erneut versucht werden.',
      );
    } on http.ClientException {
      throw const ApiException(
        'Keine Verbindung zum Server. Bereits geladene Inhalte bleiben verfügbar.',
      );
    } finally {
      final elapsed = watch.elapsed;
      _observe(
        method,
        path,
        status,
        elapsed,
        serverTiming,
        overdue: elapsed > timeout + _late,
      );
    }
  }

  Future<MediaData> binary(
    String baseUrl,
    String path, {
    required String token,
  }) async {
    final origin = normalizeBaseUrl(baseUrl), relative = Uri.parse(path);
    final p = relative.path.endsWith('/') ? relative.path : '${relative.path}/';
    final uri = Uri.parse(
      '$origin$pathPrefix$p',
    ).replace(query: relative.hasQuery ? relative.query : null);
    final actualToken = token.startsWith('firebase:')
        ? await (firebaseToken?.call(token.substring(9)) ??
              Future<String>.error(
                const ApiException('Bitte erneut anmelden.', statusCode: 401),
              ))
        : token;
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $actualToken';
    final watch = stopwatch()..start();
    var status = 0;
    String? serverTiming;
    // The longest single wait: for the answer, for one chunk or for the
    // rest of an error body. Each has its own timeout, so only a timer
    // that fired late makes one longer; a slow but steady download, however
    // long in all, is no pause.
    var longestWait = Duration.zero, lastMark = Duration.zero;
    void waited() {
      final now = watch.elapsed;
      if (now - lastMark > longestWait) longestWait = now - lastMark;
      lastMark = now;
    }

    try {
      final response = await _client.send(request).timeout(_binaryTimeout);
      waited();
      status = response.statusCode;
      serverTiming = response.headers['server-timing'];
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString().timeout(timeout);
        String message = 'Das Bild konnte nicht geladen werden.';
        String? code;
        try {
          final decoded = jsonMap(jsonDecode(body));
          message = textValue(decoded['error'], message);
          code = _errorCode(decoded['code']);
        } catch (_) {}
        throw ApiException(
          message,
          statusCode: response.statusCode,
          code: code,
        );
      }
      final chunks = <List<int>>[];
      var size = 0;
      await for (final chunk in response.stream.timeout(_binaryTimeout)) {
        waited();
        size += chunk.length;
        if (size > 80 * 1024 * 1024) {
          throw const ApiException(
            'Die Bilddatei ist zu groß.',
            statusCode: 413,
          );
        }
        chunks.add(chunk);
      }
      final bytes = Uint8List(size);
      var offset = 0;
      for (final chunk in chunks) {
        bytes.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      return MediaData(
        bytes,
        response.headers['content-type']?.split(';').first ??
            'application/octet-stream',
      );
    } on TimeoutException {
      throw const ApiException(
        'Das Bild konnte nicht rechtzeitig geladen werden.',
      );
    } on http.ClientException {
      throw const ApiException('Keine Verbindung zur Fotogalerie.');
    } finally {
      waited();
      _observe(
        'GET',
        path,
        status,
        watch.elapsed,
        serverTiming,
        overdue: longestWait > _binaryTimeout + _late,
      );
    }
  }

  Future<JsonMap> login(String baseUrl, String email, String password) =>
      request(
        baseUrl,
        'POST',
        '/auth/login',
        body: {'email': email.trim(), 'password': password},
      );
  Future<JsonMap> snapshot(String baseUrl, String token) =>
      request(baseUrl, 'GET', '/snapshot', token: token);
  Future<JsonMap> action(String baseUrl, String token, PendingAction action) =>
      request(
        baseUrl,
        'POST',
        '/actions',
        token: token,
        body: action.payload,
        idempotencyKey: action.id,
      );
  Future<JsonMap> script(String baseUrl, String token, String productionId) =>
      request(
        baseUrl,
        'GET',
        '/productions/${Uri.encodeComponent(productionId)}/script',
        token: token,
      );
  void close() => _client.close();

  /// Reads a `Retry-After` header given in seconds; HTTP dates and
  /// unusable values count as absent.
  static Duration? retryAfterOf(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  /// A short machine-readable error code; anything else is ignored.
  static String? _errorCode(Object? value) =>
      value is String && RegExp(r'^[a-z_]{1,40}$').hasMatch(value)
      ? value
      : null;
}

class MediaData {
  const MediaData(this.bytes, this.mime);
  final Uint8List bytes;
  final String mime;
}
