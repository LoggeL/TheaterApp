import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/platform/pwa_install.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/me/domain/absence_summary.dart';
import 'package:theater_app/features/me/me.dart';
import 'package:theater_app/features/profile/profile.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

Future<DeviceServices> _pump(
  WidgetTester tester,
  AppController controller,
) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final devices = DeviceServices(
    controller,
    onTarget: (_) {},
    onForegroundMessage: (_) {},
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MyAreaScreen(
            controller: controller,
            devices: devices,
            installation: PwaInstallation(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return devices;
}

void main() {
  group('absenceSummary', () {
    final now = DateTime(2026, 10, 11, 9);
    Absence absence(DateTime from, DateTime to) =>
        Absence(id: '${from.day}', from: from, to: to);

    test('names the next absence and how many follow', () {
      expect(absenceSummary([], now), 'Keine Abwesenheit geplant');
      expect(
        absenceSummary([
          absence(DateTime(2026, 9, 1), DateTime(2026, 9, 3)),
          absence(DateTime(2026, 11, 2), DateTime(2026, 11, 2)),
          absence(DateTime(2026, 10, 20), DateTime(2026, 10, 24)),
        ], now),
        'Nächste: 20.10.–24.10. · 1 weitere',
      );
      expect(
        absenceSummary([
          absence(DateTime(2026, 11, 2), DateTime(2026, 11, 2)),
        ], now),
        'Nächste: 02.11.',
      );
    });

    test('a running absence shows its last day', () {
      expect(
        absenceSummary([
          absence(DateTime(2026, 10, 9), DateTime(2026, 10, 14)),
        ], now),
        'Abwesend bis 14.10.',
      );
      expect(
        absenceSummary([
          absence(DateTime(2026, 10, 9), DateTime(2026, 10, 11)),
        ], now),
        'Heute abwesend',
      );
    });
  });

  testWidgets('Mein Bereich groups personal entries without duplicates', (
    tester,
  ) async {
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    expect(controller.user!.isAdmin, true);
    await _pump(tester, controller);

    expect(find.text('Mein Bereich.'), findsOneWidget);
    for (final title in [
      'Für mich',
      'Ensemble',
      'Einstellungen',
      'Konto',
      'App',
      'Abwesenheiten',
      'Meine Teilnahme',
      'Unser Ensemble',
      'Galerien',
      'Benachrichtigungen & Darstellung',
      'Passwort ändern',
      'Synchronisierung',
      'Datenschutz',
      'Über die App',
      'Abmelden',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    // Reachable elsewhere: the Admin section, Mitteilungen and Termine.
    expect(find.text('Administration'), findsOneWidget); // only the role pill
    expect(find.text('Abstimmungen'), findsNothing);
    expect(find.text('Terminfinder'), findsNothing);
    // Sign-in by password without Firebase: no provider management.
    expect(find.text('Anmeldearten'), findsNothing);
    // No web installation on test hosts.
    expect(find.text('App installieren'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Profil bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the demo hides account entries and offers to leave the demo', (
    tester,
  ) async {
    final controller = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
      clock: () => fixedNow,
    );
    await controller.startDemo();
    await _pump(tester, controller);

    expect(find.text('Konto'), findsNothing);
    expect(find.text('Passwort ändern'), findsNothing);
    expect(find.text('Meine Teilnahme'), findsNothing);
    expect(find.text('Demo · alles bleibt auf diesem Gerät'), findsOneWidget);
    await tester.tap(find.text('Demo beenden'));
    await tester.pumpAndSettle();
    expect(find.text('Demo beenden?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Demo beenden'), findsOneWidget);
    await tester.tap(find.text('Hierbleiben'));
    await tester.pumpAndSettle();
    expect(controller.isDemo, true);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('logout warns about unsent changes and signs out on request', (
    tester,
  ) async {
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    server.offline = true;
    await controller.respond('demo-rehearsal', 'yes');
    expect(controller.pendingCount, 1);
    await _pump(tester, controller);

    await tester.tap(find.text('Abmelden'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Eine Änderung ist noch nicht'), findsOneWidget);
    // Offline a sync cannot help, so it is not offered.
    expect(find.text('Erst synchronisieren'), findsNothing);
    final confirm = find.widgetWithText(FilledButton, 'Trotzdem abmelden');
    expect(confirm, findsOneWidget);
    final style = tester.widget<FilledButton>(confirm).style!;
    final scheme = Theme.of(tester.element(confirm)).colorScheme;
    expect(style.backgroundColor!.resolve({}), scheme.error);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(controller.user, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
