import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/ui/reader.dart';

void main() {
  testWidgets('desktop scene navigation and modes survive mobile resizing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await controller.init();
    await controller.startDemo();
    await tester.pumpWidget(
      MaterialApp(
        home: ScriptReaderScreen(
          controller: controller,
          productionId: 'demo-midnight',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-desktop-workspace')),
      findsOneWidget,
    );
    final scenes = controller.scripts['demo-midnight']!.scenes;
    await tester.tap(find.byKey(ValueKey('reader-scene-${scenes.last.id}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(
            find.byKey(ValueKey('reader-scene-${scenes.last.id}')),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('reader-mode-cues')));
    await tester.pumpAndSettle();
    expect(controller.preferences['reader.demo-midnight.mode'], 'cues');
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('reader-mode-cues')))
          .selected,
      isTrue,
    );
    tester.view.physicalSize = const Size(1000, 844);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-desktop-workspace')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-desktop-workspace')),
      findsNothing,
    );
    expect(find.byTooltip('Lesemodus'), findsOneWidget);
    expect(find.text('Nur Cues'), findsOneWidget);
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: ScriptReaderScreen(
          controller: controller,
          productionId: 'demo-midnight',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-desktop-workspace')),
      findsNothing,
    );
    expect(find.byTooltip('Lesemodus'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
