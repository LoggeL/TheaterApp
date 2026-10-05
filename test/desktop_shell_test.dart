import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/main.dart';
import 'package:theater_app/ui/app_navigation.dart';
import 'package:theater_app/ui/events.dart';

Future<AppController> demoApp(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controller = AppController(
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
  );
  await controller.init();
  await controller.startDemo();
  await tester.pumpWidget(
    TheaterApp(controller: controller, enableDeviceServices: false),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> selectSection(WidgetTester tester, String title) async {
  await tester.tap(
    find.descendant(
      of: find.byType(AppNavigationRail),
      matching: find.text(title),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('desktop route navigation returns to the selected section', (
    tester,
  ) async {
    final controller = await demoApp(tester);
    expect(find.byKey(const ValueKey('today-primary-column')), findsOneWidget);
    await tester.tap(find.text('Termin ansehen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-route-frame')), findsOneWidget);
    await selectSection(tester, 'Drehbücher');
    expect(find.text('Aktuelle Produktionen'), findsOneWidget);
    await tester.tap(
      find.byKey(
        ValueKey('production.${controller.activeProductions.first.id}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-route-frame')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-desktop-workspace')),
      findsOneWidget,
    );
    await selectSection(tester, 'Termine');
    expect(find.text('Dein Probenplan.'), findsOneWidget);
    expect(find.byType(EventDetailContent), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-route-frame')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('desktop shell reflows with narrow windows and large text', (
    tester,
  ) async {
    final controller = await demoApp(tester);
    expect(
      find.byKey(const ValueKey('today-secondary-column')),
      findsOneWidget,
    );
    tester.view.physicalSize = const Size(900, 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('today-secondary-column')), findsNothing);
    expect(find.byType(AppNavigationRail), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1440, 1000);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('today-secondary-column')), findsNothing);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pumpAndSettle();
    expect(find.byType(AppNavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
