import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/accounts/accounts.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  testWidgets(
    'members list says when nobody matches and links admins to management',
    (tester) async {
      final server = TestServer();
      server.data['members'] = [
        {'id': 1, 'name': 'Alex', 'active': true},
        {'id': 2, 'name': 'Kim', 'active': false},
      ];
      final controller = server.controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: MembersScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Niemand gefunden'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Zoe');
      await tester.pumpAndSettle();
      expect(find.text('Niemand gefunden'), findsOneWidget);
      expect(find.textContaining('„Zoe“'), findsOneWidget);
      expect(find.text('Nicht aktiv (1)'), findsNothing);
      await tester.enterText(find.byType(TextField), 'ki');
      await tester.pumpAndSettle();
      expect(find.text('Niemand gefunden'), findsNothing);
      expect(find.text('Nicht aktiv (1)'), findsOneWidget);

      await tester.tap(find.byTooltip('Personen & Zugänge'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountsAdminScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
