import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/platform/pwa_install.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_version.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/features/changelog/changelog.dart';
import 'package:theater_app/features/me/me.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  test('the changelog starts with the current version', () {
    expect(changelog.first.version, appVersion);
    expect(
      changelog.map((e) => e.version).toSet(),
      hasLength(changelog.length),
    );
    for (final entry in changelog) {
      expect(entry.items, isNotEmpty, reason: entry.version);
      expect(entry.date, isNotEmpty, reason: entry.version);
    }
  });

  test('the changelog lists the versions newest first', () {
    List<int> parts(String version) =>
        version.split('.').map(int.parse).toList();
    for (var i = 1; i < changelog.length; i++) {
      final newer = parts(changelog[i - 1].version);
      final older = parts(changelog[i].version);
      var cmp = 0;
      for (var j = 0; j < newer.length && cmp == 0; j++) {
        cmp = newer[j].compareTo(older[j]);
      }
      expect(cmp, greaterThan(0), reason: changelog[i].version);
    }
  });

  testWidgets('the Changelog entry in the App section shows every version', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    final devices = DeviceServices(
      controller,
      onTarget: (_) {},
      onForegroundMessage: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(
          body: MyAreaScreen(
            controller: controller,
            devices: devices,
            installation: PwaInstallation(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.text('Changelog');
    await tester.scrollUntilVisible(tile, 200);
    // Listed under "Hilfe & Info", right before "Über die App".
    expect(
      tester.getTopLeft(tile).dy,
      greaterThan(tester.getTopLeft(find.text('Hilfe & Info')).dy),
    );
    expect(
      tester.getTopLeft(tile).dy,
      lessThan(tester.getTopLeft(find.text('Über die App')).dy),
    );
    expect(find.byKey(const ValueKey('changelog-new-badge')), findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.byType(ChangelogScreen), findsOneWidget);
    expect(controller.preferences[seenChangelogVersionKey], appVersion);
    // The newest 5 versions are shown at once; older versions expand on tap.
    for (final entry in changelog.take(5)) {
      final version = find.text('Version ${entry.version}');
      await tester.scrollUntilVisible(version, 200);
      expect(version, findsOneWidget, reason: entry.version);
    }
    if (changelog.length > 5) {
      expect(find.text('Version ${changelog[5].version}'), findsNothing);
      final showOlder = find.byKey(const ValueKey('changelog-show-older'));
      await tester.scrollUntilVisible(showOlder, 200);
      await tester.tap(showOlder);
      await tester.pumpAndSettle();
      for (final entry in changelog.skip(5)) {
        final version = find.text('Version ${entry.version}');
        await tester.scrollUntilVisible(version, 200);
        expect(version, findsOneWidget, reason: entry.version);
      }
    }

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('changelog-new-badge')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('non-admins hide leadership-only items until Alle zeigen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const entries = [
      ChangelogEntry(
        version: '0.16.2',
        date: '10. November 2026',
        items: ['Für die Theaterleitung: Nur Admin-Änderung.'],
      ),
      ChangelogEntry(
        version: '0.16.0',
        date: '8. November 2026',
        items: [
          'Für alle Mitglieder sichtbar.',
          'Für die Theaterleitung: Zweiter Admin-Hinweis.',
        ],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: const ChangelogScreen(entries: entries, isAdmin: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Für alle Mitglieder sichtbar.'), findsOneWidget);
    expect(find.textContaining('Für die Theaterleitung:'), findsNothing);
    expect(find.text('Version 0.16.2'), findsNothing);
    final toggle = find.byKey(const ValueKey('changelog-show-all'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Version 0.16.2'), findsOneWidget);
    expect(
      find.text('Für die Theaterleitung: Nur Admin-Änderung.'),
      findsOneWidget,
    );
    expect(
      find.text('Für die Theaterleitung: Zweiter Admin-Hinweis.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the version in Mein Bereich opens Was ist neu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    final controller = server.controller();
    await signIn(controller);
    final devices = DeviceServices(
      controller,
      onTarget: (_) {},
      onForegroundMessage: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(
          body: MyAreaScreen(
            controller: controller,
            devices: devices,
            installation: PwaInstallation(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('$appVersionLabel · Lizenzen'), findsOneWidget);
    final link = find.byKey(const ValueKey('version-link'));
    await tester.scrollUntilVisible(link, 200);
    expect(find.text('Was ist neu?'), findsOneWidget);
    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(find.byType(ChangelogScreen), findsOneWidget);
    expect(find.text('Neuigkeiten'.toUpperCase()), findsOneWidget);
    final current = find.text('Version $appVersion');
    expect(current, findsOneWidget);
    expect(find.text('Deine Version'), findsOneWidget);
    // The current version is the first entry on the page.
    final previous = find.text('Version ${changelog[1].version}');
    expect(
      tester.getTopLeft(current).dy,
      lessThan(tester.getTopLeft(previous).dy),
    );
    expect(
      find.descendant(
        of: find.ancestor(of: current, matching: find.byType(Card)),
        matching: find.text(changelog.first.items.first),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
