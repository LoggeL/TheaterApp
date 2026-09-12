// Actual Flutter rendering, not a separate HTML mock-up.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/main.dart';

void main() {
  testWidgets('Capture mobile surfaces', (tester) async {
    await initializeDateFormatting('de');
    final font = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))
      ..addFont(rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
    await font.load();
    await (FontLoader('Ahem')
          ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))
          ..addFont(rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
      clock: () => DateTime(2026, 9, 12, 15),
    );
    await c.init();
    await c.startDemo();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: TheaterApp(controller: c, enableDeviceServices: false),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('../docs/screenshots/heute.png'),
    );
    await tester.tap(find.text('Termine'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('../docs/screenshots/termine.png'),
    );
    await tester.tap(find.text('Drehbücher'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('../docs/screenshots/drehbuecher.png'),
    );
    await tester.tap(find.text('Wenn das Licht angeht').first);
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('../docs/screenshots/leser.png'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
