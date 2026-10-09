import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/more.dart';
import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  testWidgets('email opt-in defaults off, persists and offers a self test', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    server.data['capabilities'] = {'emailConfigured': true};
    final controller = server.controller();
    await signIn(controller);
    final devices = DeviceServices(
      controller,
      onTarget: (_) {},
      onForegroundMessage: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(controller: controller, devices: devices),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, 'Termin-E-Mails');
    expect(tester.widget<SwitchListTile>(toggle).value, false);
    expect(find.text('Test-E-Mail an mich senden'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(jsonMap(server.actionBodies.last['value'])['emailEnabled'], true);
    await tester.tap(find.text('Test-E-Mail an mich senden'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'email.test');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
