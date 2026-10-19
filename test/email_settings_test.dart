import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/settings/settings.dart';

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

  testWidgets(
    'push switch explains its state, theme is a segmented choice and the test mail needs a connection',
    (tester) async {
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
      final push = find.widgetWithText(SwitchListTile, 'Push auf diesem Gerät');
      // Test builds have no push configuration.
      expect(tester.widget<SwitchListTile>(push).onChanged, isNull);
      expect(
        find.text('In dieser App-Version nicht eingerichtet'),
        findsOneWidget,
      );
      expect(find.textContaining('weder Push noch E-Mails'), findsOneWidget);
      expect(find.text('Einen Tag vor einem Termin'), findsOneWidget);
      expect(
        find.text('Zusätzliche Erinnerung zu einem selbst gewählten Zeitpunkt'),
        findsOneWidget,
      );
      expect(find.text('Offline'), findsNothing);

      await tester.tap(find.text('Dunkel'));
      await tester.pumpAndSettle();
      expect(controller.preferences['themeMode'], 'dark');

      await tester.tap(find.widgetWithText(SwitchListTile, 'Termin-E-Mails'));
      await tester.pumpAndSettle();
      // The test server does not persist settings like the real one does.
      server.data['reminders'] = jsonMap(server.actionBodies.last['value']);
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.textContaining('weder Push noch E-Mails'), findsNothing);

      server.offline = true;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(controller.isOffline, true);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Test-E-Mail an mich senden'),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  for (final (role, flagged, shown) in [
    ('admin', true, true),
    ('admin', false, false),
    ('member', true, false),
  ]) {
    testWidgets('short-notice decline alerts: $role, '
        '${flagged ? 'with' : 'without'} the flag', (tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _RoleServer(role);
      server.data['capabilities'] = {
        if (flagged) 'features': ['lateDeclines'],
      };
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
      final toggle = find.widgetWithText(
        SwitchListTile,
        'Kurzfristige Absagen melden',
      );
      expect(toggle, shown ? findsOneWidget : findsNothing);
      if (shown) {
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(
          jsonMap(server.actionBodies.last['value'])['lateDeclines'],
          isFalse,
        );
      } else {
        // Older servers never get the unknown key.
        await controller.saveReminders(controller.reminders);
        expect(
          jsonMap(
            server.actionBodies.last['value'],
          ).containsKey('lateDeclines'),
          flagged,
        );
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  for (final (role, flagged) in [
    ('admin', true),
    ('admin', false),
    ('member', true),
    ('member', false),
  ]) {
    testWidgets('personal push kinds: $role, '
        '${flagged ? 'with' : 'without'} the flag', (tester) async {
      tester.view.physicalSize = const Size(1000, 3600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _RoleServer(role);
      server.data['capabilities'] = {
        'features': ['lateDeclines', if (flagged) 'pushSettings'],
      };
      // A stored opt-out comes back from the server; a missing key means on.
      server.data['reminders'] = {'adminFeedback': false, 'polls': false};
      final controller = server.controller();
      await signIn(controller);
      expect(controller.reminders['adminRegistrations'], isTrue);
      expect(controller.reminders['messages'], isTrue);
      expect(controller.reminders['adminFeedback'], isFalse);
      expect(controller.reminders['polls'], isFalse);
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
      Finder toggle(String title) => find.widgetWithText(SwitchListTile, title);
      bool on(String title) =>
          tester.widget<SwitchListTile>(toggle(title)).value;
      final admin = role == 'admin';
      for (final title in [
        'Neue Termine',
        'Fehlende Rückmeldung',
        'Terminfinder',
        'Mitteilungen',
        'Abstimmungen',
        'Pushes der Leitung',
        'Antworten auf dein Feedback',
      ]) {
        expect(toggle(title), flagged ? findsOneWidget : findsNothing);
      }
      for (final title in ['Neue Registrierungen', 'Feedback']) {
        expect(toggle(title), flagged && admin ? findsOneWidget : findsNothing);
      }
      expect(
        toggle('Kurzfristige Absagen melden'),
        admin ? findsOneWidget : findsNothing,
      );
      if (flagged) {
        expect(on('Mitteilungen'), isTrue);
        expect(on('Abstimmungen'), isFalse);
        await tester.tap(toggle('Mitteilungen'));
        await tester.pumpAndSettle();
        var value = jsonMap(server.actionBodies.last['value']);
        expect(value['messages'], isFalse);
        expect(value['polls'], isFalse);
        expect(value['adminFeedback'], isFalse);
        expect(value['direct'], isTrue);
        if (admin) {
          expect(on('Neue Registrierungen'), isTrue);
          expect(on('Feedback'), isFalse);
          await tester.tap(toggle('Neue Registrierungen'));
          await tester.pumpAndSettle();
          value = jsonMap(server.actionBodies.last['value']);
          expect(value['adminRegistrations'], isFalse);
          expect(value['lateDeclines'], isTrue);
        }
      } else {
        // Older servers never get the unknown keys.
        await controller.saveReminders(controller.reminders);
        final value = jsonMap(server.actionBodies.last['value']);
        for (final key in ['messages', 'polls', 'adminRegistrations']) {
          expect(value.containsKey(key), isFalse);
        }
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}

class _RoleServer extends TestServer {
  _RoleServer(this.role);
  final String role;
  @override
  JsonMap get user => {...super.user, 'role': role};
}
