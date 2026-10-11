import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/features/slots/slots.dart';

import 'app_controller_test.dart' show TestServer, signIn;
import 'slots_test.dart' show SlotServer, pool, firstSlot;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  Future<void> surface(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget screen(Widget child) =>
      MaterialApp(theme: StageTheme.build(Brightness.light), home: child);

  Widget opener(Widget Function() page) => screen(
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => page()),
          ),
          child: const Text('öffnen'),
        ),
      ),
    ),
  );

  Future<AppController> start(TestServer server) async {
    final controller = server.controller();
    await signIn(controller);
    return controller;
  }

  Future<void> finish(WidgetTester tester, AppController controller) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  }

  testWidgets('the capacity stepper sets the places of new slots', (
    tester,
  ) async {
    await surface(tester, const Size(800, 3000));
    final server = SlotServer(role: 'admin');
    final controller = await start(server);
    await tester.pumpWidget(
      screen(SlotPoolEditorScreen(controller: controller)),
    );
    String capacity() =>
        tester.widget<Text>(find.byKey(const ValueKey('slot-capacity'))).data!;
    IconButton button(String tooltip) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );
    expect(capacity(), '1 Platz');
    expect(button('Ein Platz weniger').onPressed, isNull);
    await tester.tap(find.byTooltip('Ein Platz mehr'));
    await tester.pump();
    await tester.tap(find.byTooltip('Ein Platz mehr'));
    await tester.pump();
    expect(capacity(), '3 Plätze');
    await tester.tap(find.byTooltip('Ein Platz weniger'));
    await tester.pump();
    expect(capacity(), '2 Plätze');

    await tester.enterText(
      find.widgetWithText(TextField, 'Titel'),
      'Fototermin',
    );
    await tester.tap(find.text('Slots hinzufügen'));
    await tester.pumpAndSettle();
    expect(find.text('2 Plätze'), findsWidgets);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final slots = server.actionBodies.last['slots'] as List;
    expect(slots, isNotEmpty);
    expect(slots.every((s) => (s as Map)['capacity'] == 2), isTrue);
    await finish(tester, controller);
  });

  testWidgets('leaving the editor with changes asks first', (tester) async {
    await surface(tester, const Size(800, 3000));
    final server = SlotServer(role: 'admin')..data['slotPools'] = [pool()];
    final controller = await start(server);
    await tester.pumpWidget(
      opener(
        () => SlotPoolEditorScreen(
          controller: controller,
          pool: controller.slotPools.single,
        ),
      ),
    );
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();

    // Unchanged, back simply leaves.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('öffnen'), findsOneWidget);

    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Porträts');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Änderungen verwerfen?'), findsOneWidget);
    await tester.tap(find.text('Weiter bearbeiten'));
    await tester.pumpAndSettle();
    expect(find.text('Terminfinder bearbeiten'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Verwerfen'));
    await tester.pumpAndSettle();
    expect(find.text('öffnen'), findsOneWidget);
    expect(server.actionBodies, isEmpty);
    await finish(tester, controller);
  });

  testWidgets('people without a slot can be assigned from the list', (
    tester,
  ) async {
    await surface(tester, const Size(400, 2000));
    final server = SlotServer(role: 'admin')
      ..data['slotPools'] = [
        pool(personIds: [4]),
      ];
    final controller = await start(server);
    await tester.pumpWidget(
      screen(SlotPoolScreen(controller: controller, poolId: 'pool-1')),
    );
    await tester.tap(find.text('Noch ohne Zeitfenster: 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'Kim Kulisse'));
    await tester.pumpAndSettle();
    expect(find.text('Zeitfenster für Kim Kulisse'), findsOneWidget);
    // Only slots with room are offered; s2 is full.
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.byType(ListTile)),
      findsNWidgets(2),
    );
    await tester.tap(
      find.descendant(of: sheet, matching: find.text(firstSlot)),
    );
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'slot.assign',
      'poolId': 'pool-1',
      'personId': 4,
      'slotId': 's1',
    });
    expect(find.text('Kim Kulisse eingetragen: $firstSlot'), findsOneWidget);
    await finish(tester, controller);
  });
}
