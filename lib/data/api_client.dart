import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/models.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode = 0});
  final String message;
  final int statusCode;
  bool get isUnauthorized => statusCode == 401;
  bool get retryable =>
      statusCode == 0 ||
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode >= 500;
  @override
  String toString() => message;
}

/// API origin is configuration. Credentials never go to redirects or script URLs.
class ApiClient {
  ApiClient({http.Client? client, this.timeout = const Duration(seconds: 20)})
    : _client = client ?? http.Client();
  final http.Client _client;
  final Duration timeout;
  Future<String> Function(String expectedUid)? firebaseToken;
  static const pathPrefix = '/api/mobile/v1';

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
    try {
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
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
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString().timeout(timeout);
        String message = 'Das Bild konnte nicht geladen werden.';
        try {
          message = textValue(jsonMap(jsonDecode(body))['error'], message);
        } catch (_) {}
        throw ApiException(message, statusCode: response.statusCode);
      }
      final chunks = <List<int>>[];
      var size = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
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
}

class MediaData {
  const MediaData(this.bytes, this.mime);
  final Uint8List bytes;
  final String mime;
}
