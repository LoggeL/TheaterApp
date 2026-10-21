import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/accounts/accounts.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  for (final admin in [false, true]) {
    testWidgets(
      '${admin ? 'people and access' : 'ensemble list'} separates inactive people',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final server = TestServer();
        server.data['members'] = [
          {'id': 1, 'name': 'Alex', 'active': true},
          {'id': 2, 'name': 'Kim', 'active': false},
          {'id': 3, 'name': 'Sam', 'active': true},
        ];
        final controller = server.controller();
        await signIn(controller);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: admin
                ? AccountsAdminScreen(controller: controller)
                : MembersScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final section = find.text('Nicht aktiv (1)');
        expect(section, findsOneWidget);
        if (admin) {
          // Collapsed in the admin list until opened.
          expect(find.text('Kim'), findsNothing);
          await tester.tap(section);
          await tester.pumpAndSettle();
        }
        double top(Finder f) => tester.getTopLeft(f).dy;
        expect(top(find.text('Sam')), lessThan(top(section)));
        expect(top(find.text('Kim')), greaterThan(top(section)));
        expect(find.text('Inaktiv'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}
