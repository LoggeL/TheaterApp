import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/profile/profile.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  for (final width in [320.0, 1100.0]) {
    testWidgets(
      'calendar and profile remain usable at $width px in dark theme',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = TestServer().controller();
        await signIn(c);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.dark),
            home: Scaffold(body: ScheduleScreen(controller: c)),
          ),
        );
        await tester.pumpAndSettle();
        if (width < 1000) {
          await tester.tap(find.byTooltip('Kalender'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(RehearsalCalendar), findsOneWidget);
        expect(find.byTooltip('Datum auswählen'), findsNothing);
        await tester.tap(find.byTooltip('Vorheriger Monat'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.dark),
            home: ProfileScreen(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Bild auswählen'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}
