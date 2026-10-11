import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/theater_app.dart';
import 'core/app_controller.dart';
import 'core/identity.dart';

export 'app/shell/app_shell.dart' show AppShell;
export 'app/theater_app.dart' show TheaterApp;

SemanticsHandle? _webSemantics;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) _webSemantics ??= SemanticsBinding.instance.ensureSemantics();
  await initializeDateFormatting('de');
  runApp(TheaterApp(controller: AppController(identity: FirebaseIdentity())));
}
