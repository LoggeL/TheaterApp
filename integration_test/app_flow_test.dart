import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:theater_app/main.dart' as app;
import 'package:theater_app/ui/events.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Firebase Android login, late response, reader, and pending account',
    (tester) async {
      await app.main();
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(finder, findsWidgets);
      }

      await waitFor(find.text('Anmelden'));
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'admin@theater.test',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'TheaterProbe!2026',
      );
      await tester.tap(find.text('Anmelden'));
      await waitFor(find.text('Heute'));
      final controller = tester
          .widget<app.TheaterApp>(find.byType(app.TheaterApp))
          .controller;
      expect(controller.user!.isAdmin, isTrue);
      await tester.tap(find.text('Termine'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(EventCard).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Komme später'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Späterkommen speichern'));
      await tester.tap(find.text('Späterkommen speichern'));
      await waitFor(find.text('Später · Uhrzeit offen'));
      expect(controller.events.first.response, 'late');
      await controller.refresh();
      expect(controller.events.first.response, 'late');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Zurück'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drehbücher'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wenn das Licht angeht'));
      await tester.pumpAndSettle();
      await waitFor(find.text('Szenen'));
      expect(find.text('DEIN TEXT'), findsNothing);
      expect(controller.scripts, isNotEmpty);
      await controller.logout();
      await tester.pumpAndSettle();
      await waitFor(find.text('Anmelden'));
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'sam@theater.test',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'TheaterProbe!2026',
      );
      await tester.tap(find.text('Anmelden'));
      for (var i = 0; i < 150 && controller.user == null; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(controller.user!.status, 'pending');
      expect(controller.hasAccess, isFalse);
      expect(controller.events, isEmpty);
      expect(find.text('Heute'), findsNothing);
      expect(tester.takeException(), isNull);
      await controller.logout();
      await tester.pumpAndSettle();
    },
  );
}
