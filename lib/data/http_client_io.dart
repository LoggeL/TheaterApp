import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The HTTP client on Android and other native platforms. dart:io closes
/// idle connections after 15 s, so every 45-s sync paid a new TLS
/// handshake; two minutes keep the connection between syncs. The number of
/// connections stays unlimited: a crate opening loads many pictures at once.
http.Client createHttpClient() =>
    IOClient(HttpClient()..idleTimeout = const Duration(seconds: 120));
