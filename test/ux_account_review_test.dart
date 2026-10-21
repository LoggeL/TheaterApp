import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/deep_links.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/app/shell/app_section.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/accounts/accounts.dart';
import 'package:theater_app/features/admin/admin.dart';
import 'package:theater_app/shared/navigation.dart';

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
    // The list gets the same registrations as the snapshot.
    final data = jsonMap(jsonDecode(jsonEncode(fixture())));
    (data['accounts'] as List).addAll([
      {
        'uid': 'unverified',
        'name': 'Neu',
        'personId': null,
        'status': 'pending',
        'identityReady': false,
        'version': 1,
      },
      {
        'uid': 'nameless',
        'email': 'nameless@example.test',
        'personId': null,
        'status': 'pending',
        'identityReady': true,
        'nameProvided': false,
        'version': 1,
      },
    ]);
    server.override = (request) => request.url.path.contains('/admin/accounts')
        ? Future.value(jsonResponse(data))
        : null;
    final controller = server.controller();
    await signIn(controller);
    // Registrations without a self-supplied name are linkable too.
    expect(controller.openRegistrationCount, 2);
    expect(AccountRoster(data).waitingCount, controller.openRegistrationCount);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: ManagementScreen(controller: controller),
      ),
    );
    expect(find.text('Personen & Zugänge'), findsOneWidget);
    await tester.tap(find.text('2 neue Registrierungen warten auf Zuordnung'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountsAdminScreen), findsOneWidget);
    // The waiting block on top, counted like the hub: confirmed
    // registrations.
    final block = find.byKey(const ValueKey('access-waiting'));
    expect(
      find.descendant(
        of: block,
        matching: find.text('Wartet auf Zuordnung (2)'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: block, matching: find.text('Prüfen & verknüpfen')),
      findsNWidgets(2),
    );
    expect(find.text('Prüfen & verknüpfen'), findsNWidgets(2));
    // The unconfirmed registration is counted apart.
    expect(find.text('Unbestätigt (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a registration push opens the waiting list at its account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    server.override = (request) => request.url.path.contains('/admin/accounts')
        ? Future.value(jsonResponse(fixture()))
        : null;
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    final navigator = GlobalKey<NavigatorState>();
    final messenger = GlobalKey<ScaffoldMessengerState>();
    final selection = ValueNotifier(AppSection.today.index);
    addTearDown(selection.dispose);
    await tester.pumpWidget(
      AppNavigationScope(
        selection: selection,
        controller: controller,
        child: MaterialApp(
          theme: StageTheme.build(Brightness.light),
          navigatorKey: navigator,
          scaffoldMessengerKey: messenger,
          home: const Scaffold(body: Text('Start')),
        ),
      ),
    );
    DeepLinkRouter(
      controller: controller,
      navigator: navigator,
      messenger: messenger,
      isMounted: () => true,
    ).handle(AppTarget.fromData({'accountUid': 'new'})!);
    await tester.pumpAndSettle();
    final screen = tester.widget<AccountsAdminScreen>(
      find.byType(AccountsAdminScreen),
    );
    expect((screen.initialStatus, screen.initialUid), (null, 'new'));
    expect(selection.value, AppSection.admin.index);
    final card = tester.widget<Card>(
      find.byKey(const ValueKey('access-entry-new')),
    );
    expect((card.shape! as RoundedRectangleBorder).side.width, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
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
    // The admin learns that the rejection went through.
    expect(find.textContaining('abgelehnt.'), findsOneWidget);
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
        final rejected = find.byKey(const ValueKey('status-rejected'));
        await tester.ensureVisible(rejected);
        await tester.tap(rejected);
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
