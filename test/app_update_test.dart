import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:theater_app/ui/app_update.dart';

AppUpdateInfo info(UpdateAvailability availability, {bool immediate = true}) =>
    AppUpdateInfo(
      updateAvailability: availability,
      immediateUpdateAllowed: immediate,
      immediateAllowedPreconditions: null,
      flexibleUpdateAllowed: false,
      flexibleAllowedPreconditions: null,
      availableVersionCode: 12,
      installStatus: InstallStatus.unknown,
      packageName: AppUpdateCheck.packageName,
      clientVersionStalenessDays: null,
      updatePriority: 0,
    );

void main() {
  late BuildContext context;
  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    ),
  );

  testWidgets('an available update starts the Google Play update screen', (
    tester,
  ) async {
    await pump(tester);
    var updates = 0, opened = 0;
    final check = AppUpdateCheck(
      check: () async => info(UpdateAvailability.updateAvailable),
      update: () async {
        updates++;
        return AppUpdateResult.success;
      },
      open: (_) async => ++opened > 0,
    );
    await check.run(() => context);
    await tester.pumpAndSettle();
    expect(updates, 1);
    expect(find.text('Neue Version verfügbar'), findsNothing);
    expect(opened, 0);
  });

  testWidgets('a declined update offers the store page', (tester) async {
    await pump(tester);
    final opened = <Uri>[];
    var now = DateTime(2026, 10, 9, 8);
    final check = AppUpdateCheck(
      check: () async => info(UpdateAvailability.updateAvailable),
      update: () async => AppUpdateResult.userDeniedUpdate,
      open: (uri) async {
        opened.add(uri);
        return true;
      },
      clock: () => now,
    );
    final run = check.run(() => context);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zu Google Play'));
    await tester.pumpAndSettle();
    await run;
    expect(opened, [AppUpdateCheck.storeUri]);
    // Returning soon after does not ask again.
    now = now.add(const Duration(hours: 1));
    await check.run(() => context);
    await tester.pumpAndSettle();
    expect(find.text('Neue Version verfügbar'), findsNothing);
  });

  testWidgets('current or non-Play installs stay quiet', (tester) async {
    await pump(tester);
    for (final source in <Future<AppUpdateInfo> Function()>[
      () async => info(UpdateAvailability.updateNotAvailable),
      () async => throw Exception('ERROR_APP_NOT_OWNED'),
    ]) {
      await AppUpdateCheck(
        check: source,
        update: () async => fail('no update expected'),
      ).run(() => context);
      await tester.pumpAndSettle();
      expect(find.text('Neue Version verfügbar'), findsNothing);
    }
  });
}
