// Browser-only visual QA entry point for the *same* Flutter widget tree.
// Uses memory stores and synthetic data; never connects to a member server.
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/main.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');
  final controller = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
  );
  await controller.init();
  await controller.startDemo();
  runApp(TheaterApp(controller: controller, enableDeviceServices: false));
}
