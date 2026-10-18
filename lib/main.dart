import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/theater_app.dart';
import 'core/app_controller.dart';
import 'core/identity.dart';

export 'app/shell/app_shell.dart' show AppShell;
export 'app/theater_app.dart' show TheaterApp;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On the web, Flutter builds its accessibility tree once a screen reader
  // asks for it (via its hidden "Enable accessibility" control). Forcing it
  // on for everyone roughly doubled the work of every scrolled frame.
  await initializeDateFormatting('de');
  runApp(TheaterApp(controller: AppController(identity: FirebaseIdentity())));
}
