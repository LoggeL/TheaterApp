import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

/// The HTTP client in the browser, which manages connections itself.
http.Client createHttpClient() => BrowserClient();
