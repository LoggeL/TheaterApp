import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/ui/admin.dart';
import 'package:theater_app/ui/more.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  for (final admin in [false, true]) {
    testWidgets(
      '${admin ? 'ensemble management' : 'ensemble list'} separates inactive people',
      (tester) async {
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
                ? MembersAdminScreen(controller: controller)
                : MembersScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final section = find.text('Nicht aktiv (1)');
        expect(section, findsOneWidget);
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
