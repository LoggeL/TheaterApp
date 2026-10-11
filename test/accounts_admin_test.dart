import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/accounts/accounts.dart';

import 'account_roster_test.dart' show fixture;
import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('admins delete an account only after confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    final deletions = <http.Request>[];
    server.override = (request) {
      if (request.method == 'DELETE' &&
          request.url.path.contains('/admin/accounts/')) {
        deletions.add(request);
        return Future.value(jsonResponse({'ok': true}));
      }
      return request.url.path.contains('/admin/accounts')
          ? Future.value(jsonResponse(fixture()))
          : null;
    };
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: AccountsAdminScreen(
          controller: controller,
          initialView: 'accounts',
          initialFilter: 'suspended',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Zugang verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konto löschen'));
    await tester.pumpAndSettle();
    expect(find.text('Konto löschen?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(deletions, isEmpty);
    await tester.tap(find.byTooltip('Zugang verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konto löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    expect(deletions.single.url.path, endsWith('/admin/accounts/kim/'));
    expect(jsonDecode(deletions.single.body), {'version': 2});
    expect(find.text('Konto gelöscht.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
