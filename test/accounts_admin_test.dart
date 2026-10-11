import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
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

  testWidgets('suspending asks first and can be undone from the SnackBar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    final data = fixture();
    final statusChanges = <JsonMap>[];
    server.override = (request) {
      final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
      if (path.endsWith('/admin/accounts')) {
        return Future.value(jsonResponse(data));
      }
      if (path.endsWith('/actions')) {
        final body = jsonMap(jsonDecode(request.body));
        statusChanges.add(body);
        final account = (data['accounts'] as List).cast<JsonMap>().firstWhere(
          (a) => a['uid'] == body['uid'],
        );
        account['status'] = body['status'];
        account['version'] = intValue(account['version']) + 1;
        return Future.value(jsonResponse({'ok': true}));
      }
      return null;
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: AccountsAdminScreen(
          controller: controller,
          initialView: 'accounts',
          initialFilter: 'approved',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 Konto'), findsOneWidget);
    await tester.tap(find.byTooltip('Zugang verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zugang sperren'));
    await tester.pumpAndSettle();
    expect(find.text('Zugang sperren?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(statusChanges, isEmpty);

    await tester.tap(find.byTooltip('Zugang verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zugang sperren'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sperren'));
    await tester.pumpAndSettle();
    expect(statusChanges.single, {
      'action': 'account.status',
      'uid': 'admin',
      'version': 1,
      'status': 'suspended',
    });
    expect(find.text('Zugang von Alex gesperrt.'), findsOneWidget);
    // The reloaded list keeps the screen; the filter now finds nobody.
    expect(find.text('0 Konten'), findsOneWidget);

    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(statusChanges.last, {
      'action': 'account.status',
      'uid': 'admin',
      'version': 2,
      'status': 'approved',
    });
    expect(find.text('1 Konto'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed reload keeps the last list visible', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    var fail = false;
    server.override = (request) {
      if (!request.url.path.contains('/admin/accounts')) return null;
      return Future.value(
        fail
            ? jsonResponse({'error': 'Server nicht erreichbar.'}, 503)
            : jsonResponse(fixture()),
      );
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: AccountsAdminScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('4 Personen'), findsOneWidget);
    expect(find.text('Drehbuchrollen (4)'), findsOneWidget);
    fail = true;
    await tester.tap(find.byTooltip('Aktualisieren'));
    await tester.pumpAndSettle();
    expect(find.text('4 Personen'), findsOneWidget);
    expect(find.text('Konten nicht geladen'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
