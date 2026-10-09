import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/accounts_admin.dart';
import 'package:theater_app/ui/admin.dart';
import 'package:theater_app/ui/theme.dart';

import 'account_roster_test.dart' show fixture;
import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  test('registration pushes open the validated account target', () {
    final target = AppTarget.fromData({'accountUid': 'new'});
    expect(target?.kind, 'accounts');
    expect(target?.id, 'new');
    expect(AppTarget.fromData({'accountUid': ''}), isNull);
    expect(
      AppTarget.fromUri(Uri.parse('theaterapp://app/accounts/new'))?.kind,
      'accounts',
    );
  });

  testWidgets('admins see open registrations and land on pending accounts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    server.data['pendingAccounts'] = [
      {'uid': 'new', 'status': 'pending', 'identityReady': true},
      {'uid': 'unverified', 'status': 'pending', 'identityReady': false},
      {
        'uid': 'nameless',
        'status': 'pending',
        'identityReady': true,
        'nameProvided': false,
      },
    ];
    server.override = (request) => request.url.path.contains('/admin/accounts')
        ? Future.value(jsonResponse(fixture()))
        : null;
    final controller = server.controller();
    await signIn(controller);
    expect(controller.openRegistrationCount, 1);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: ManagementScreen(controller: controller),
      ),
    );
    await tester.tap(find.text('1 neue Registrierung wartet auf Zuordnung'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountsAdminScreen), findsOneWidget);
    expect(find.text('1 Konten'), findsOneWidget);
    expect(find.text('Prüfen & verknüpfen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('rejecting an account requires explicit confirmation', (
    tester,
  ) async {
    final server = TestServer(), controller = server.controller();
    await signIn(controller);
    expect(controller.user?.isAdmin, isTrue);
    final data = fixture();
    final account = jsonList(data['accounts']).map(jsonMap).last;
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openPage(
                context,
                AccountApprovalScreen(
                  controller: controller,
                  account: account,
                  accounts: jsonList(data['accounts']).map(jsonMap).toList(),
                ),
              ),
              child: const Text('Konto prüfen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Konto prüfen'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Anfrage ablehnen'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Anfrage ablehnen'));
    await tester.pumpAndSettle();
    expect(find.text('Anfrage ablehnen?'), findsOneWidget);
    expect(server.actionBodies, isEmpty);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('sam.real@example.test'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountApprovalScreen), findsOneWidget);
    expect(server.actionBodies, isEmpty);
    await tester.tap(find.text('Anfrage ablehnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ablehnen'));
    await tester.pumpAndSettle();
    expect(server.actionBodies, [
      {
        'action': 'account.status',
        'uid': 'new',
        'version': 1,
        'status': 'rejected',
      },
    ]);
    expect(find.byType(AccountApprovalScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final conflict in [false, true]) {
    testWidgets(
      conflict
          ? 'reconsider conflict leaves rejected account available for retry'
          : 'reconsider returns rejected account to normal pending approval',
      (tester) async {
        final server = TestServer(), controller = server.controller();
        final data = fixture();
        final account = jsonList(data['accounts']).map(jsonMap).last;
        jsonList(data['accounts'])[2] = account;
        account['status'] = 'rejected';
        account['version'] = 2;
        final requests = <JsonMap>[];
        server.override = (request) {
          final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
          if (path.endsWith('/admin/accounts')) {
            return Future.value(jsonResponse(data));
          }
          if (path.endsWith('/actions')) {
            final body = jsonMap(jsonDecode(request.body));
            requests.add(body);
            if (conflict) {
              return Future.value(
                jsonResponse({'error': 'Das Konto hat sich geändert.'}, 409),
              );
            }
            account.addAll({
              'status': 'pending',
              'personId': null,
              'role': 'member',
              'version': 3,
            });
            return Future.value(jsonResponse({'ok': true}));
          }
          return null;
        };
        await signIn(controller);
        expect(controller.user?.isAdmin, isTrue);
        expect(
          jsonList((await controller.remote('/admin/accounts'))['accounts']),
          hasLength(3),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: AccountsAdminScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Konten (3)'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilterChip, 'Abgelehnt'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Erneut prüfen'));
        await tester.tap(find.text('Erneut prüfen'));
        await tester.pumpAndSettle();
        expect(requests, [
          {'action': 'account.reconsider', 'uid': 'new', 'version': 2},
        ]);
        expect(
          find.text('Prüfen & verknüpfen'),
          conflict ? findsNothing : findsOneWidget,
        );
        expect(
          find.text('Erneut prüfen'),
          conflict ? findsOneWidget : findsNothing,
        );
        expect(account['status'], conflict ? 'rejected' : 'pending');
        if (!conflict) {
          expect(account['personId'], isNull);
          expect(account['role'], 'member');
          expect(find.byType(AccountApprovalScreen), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}
