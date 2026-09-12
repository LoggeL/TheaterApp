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
    final canonicalPath = path.endsWith('/') ? path : '$path/';
    final request =
        http.Request(method, Uri.parse('$origin$pathPrefix$canonicalPath'))
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
