import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/accounts/accounts.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';
import 'package:theater_app/shared/widgets/member_avatar.dart';
import 'package:theater_app/shared/widgets/state_pill.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

/// Serves the account list with the app's own people and [accounts], and
/// applies status changes to them.
void _serve(TestServer server, List<JsonMap> accounts) {
  server.data['capabilities'] = {
    ...jsonMap(server.data['capabilities']),
    'features': ['accountRole', 'accountPermissions'],
  };
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (path.endsWith('/admin/accounts')) {
      return Future.value(
        jsonResponse({'members': server.data['members'], 'accounts': accounts}),
      );
    }
    if (path.endsWith('/actions')) {
      final body = jsonMap(jsonDecode(request.body));
      server.actionBodies.add(body);
      final account = accounts.firstWhere((a) => a['uid'] == body['uid']);
      account['status'] = body['status'];
      account['version'] = intValue(account['version']) + 1;
      return Future.value(jsonResponse({'ok': true}));
    }
    return null;
  };
}

Finder _inRow(int personId, String text) => find.descendant(
  of: find.byKey(ValueKey('access-entry-$personId')),
  matching: find.text(text),
);

Finder _inSection(String text) => find.descendant(
  of: find.byKey(const ValueKey('member-editor-account')),
  matching: find.text(text),
);

Future<void> _pump(
  WidgetTester tester,
  TestServer server,
  Widget Function(AppController) screen,
) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: screen(controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('people and access share the status and rights pills', (
    tester,
  ) async {
    final server = TestServer();
    _serve(server, [
      {'uid': 'a', 'personId': 1, 'status': 'approved', 'role': 'admin'},
      {
        'uid': 'k',
        'personId': 4,
        'status': 'suspended',
        'permissions': ['events'],
      },
    ]);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    expect(_inRow(1, 'Freigegeben'), findsOneWidget);
    expect(_inRow(4, 'Gesperrt'), findsOneWidget);
    expect(_inRow(5, 'Kein Konto'), findsOneWidget);
    expect(_inRow(1, 'Admin'), findsOneWidget);
    expect(_inRow(4, 'Termine verwalten · ruht'), findsOneWidget);
    // Each person with avatar and roles.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('access-entry-5')),
        matching: find.byType(MemberAvatar),
      ),
      findsOneWidget,
    );
    expect(_inRow(5, 'Schauspiel'), findsOneWidget);
    final scheme = Theme.of(
      tester.element(find.byType(Card).first),
    ).colorScheme;
    StatePill pill(String label) =>
        tester.widget<StatePill>(find.widgetWithText(StatePill, label).first);
    expect(pill('Freigegeben').color, scheme.secondary);
    expect(pill('Freigegeben').icon, Icons.check_circle);
    expect(pill('Gesperrt').color, scheme.error);
    expect(pill('Kein Konto').icon, Icons.link_off);
    expect(pill('Admin').color, StageTheme.violet);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the person editor holds the whole app access', (tester) async {
    final server = TestServer();
    final accounts = <JsonMap>[
      {
        'uid': 'a',
        'personId': 1,
        'status': 'approved',
        'name': 'Alex Bühnenfreund',
        'email': 'alex@example.test',
        'provider': 'google.com',
        'emailVerified': true,
        'lastSeenAt': '2026-10-03T10:00:00Z',
        'approvedAt': '2026-09-01T10:00:00Z',
        'role': 'member',
        'permissions': ['events'],
        'identityReady': true,
        'version': 2,
      },
    ];
    _serve(server, accounts);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    expect(
      find.widgetWithText(FloatingActionButton, 'Person anlegen'),
      findsOne,
    );
    await tester.tap(_inRow(1, 'Alex Bühnenfreund'));
    await tester.pumpAndSettle();
    expect(find.text('Person bearbeiten'), findsOneWidget);
    for (final text in [
      'App-Zugang',
      'Freigegeben',
      'Termine verwalten',
      'alex@example.test',
      'Google · bestätigt · zuletzt aktiv 3.10.2026 · freigegeben 1.9.2026',
      'Rechte bearbeiten…',
      'Konto löschen',
    ]) {
      expect(_inSection(text), findsOneWidget, reason: text);
    }
    expect(_inSection('Konto verknüpfen'), findsNothing);

    // The shared rights sheet.
    await tester.ensureVisible(_inSection('Rechte bearbeiten…'));
    await tester.tap(_inSection('Rechte bearbeiten…'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountRightsSheet), findsOneWidget);
    expect(find.text('Rechte von Alex Bühnenfreund'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();

    // Suspending asks first and then shows the new status in place.
    await tester.ensureVisible(_inSection('Zugang sperren'));
    await tester.tap(_inSection('Zugang sperren'));
    await tester.pumpAndSettle();
    expect(find.text('Zugang sperren?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sperren'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'account.status',
      'uid': 'a',
      'version': 2,
      'status': 'suspended',
    });
    expect(_inSection('Gesperrt'), findsOneWidget);
    expect(_inSection('Termine verwalten · ruht'), findsOneWidget);
    expect(_inSection('Wieder freigeben'), findsOneWidget);
    await tester.ensureVisible(_inSection('Wieder freigeben'));
    await tester.tap(_inSection('Wieder freigeben'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['status'], 'approved');
    expect(_inSection('Freigegeben'), findsOneWidget);

    // Back in the list, the row shows the current access.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_inRow(1, 'Freigegeben'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a person without an account links one in the editor', (
    tester,
  ) async {
    final server = TestServer();
    _serve(server, [
      {
        'uid': 'new',
        'name': 'Sam',
        'email': 'sam@example.test',
        'personId': null,
        'status': 'pending',
        'identityReady': true,
        'version': 1,
      },
    ]);
    await _pump(
      tester,
      server,
      (c) => MemberEditorScreen(
        controller: c,
        member: jsonMap(jsonList(server.data['members'])[4]),
      ),
    );
    expect(_inSection('Kein Konto'), findsOneWidget);
    expect(_inSection('Konto löschen'), findsNothing);
    await tester.ensureVisible(_inSection('Konto verknüpfen'));
    await tester.tap(_inSection('Konto verknüpfen'));
    await tester.pumpAndSettle();
    expect(find.text('Konto für Sam Vorhang'), findsOneWidget);
    await tester.tap(find.text('sam@example.test'));
    await tester.pumpAndSettle();
    final approval = tester.widget<AccountApprovalScreen>(
      find.byType(AccountApprovalScreen),
    );
    expect(approval.initialPersonId, 5);
    expect(approval.account['uid'], 'new');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the editor marks resting rights and an inactive person', (
    tester,
  ) async {
    final server = TestServer();
    server.override = (request) => request.url.path.contains('/admin/accounts')
        ? Future.value(
            jsonResponse({
              'accounts': [
                {
                  'uid': 'k',
                  'personId': 4,
                  'status': 'suspended',
                  'role': 'member',
                  'permissions': ['events'],
                },
                {
                  'uid': 'f',
                  'personId': 7,
                  'status': 'approved',
                  'role': 'admin',
                },
              ],
            }),
          )
        : null;
    // Suspended: the right does not apply now.
    await _pump(
      tester,
      server,
      (c) => MemberEditorScreen(
        controller: c,
        member: const {'id': 4, 'name': 'Kim', 'active': true},
      ),
    );
    expect(_inSection('Gesperrt'), findsOneWidget);
    expect(_inSection('Termine verwalten · ruht'), findsOneWidget);
    // Inactive: the server denies access although the account is approved.
    await tester.pumpWidget(const SizedBox());
    await _pump(
      tester,
      server,
      (c) => MemberEditorScreen(
        controller: c,
        member: const {'id': 7, 'name': 'Fynn', 'active': false},
      ),
    );
    for (final text in ['Freigegeben', 'Person inaktiv', 'Admin']) {
      expect(_inSection(text), findsOneWidget, reason: text);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'roles still in use cannot be removed; others need a confirmation',
    (tester) async {
      final server = TestServer();
      server.data['personRoles'] = [
        ...server.data['personRoles'] as List,
        {'id': 'role-free', 'name': 'Maske', 'version': 2},
      ];
      await _pump(tester, server, (c) => RolesAdminScreen(controller: c));
      expect(find.text('Rolle anlegen'), findsOneWidget);
      expect(find.text('3 Personen'), findsOneWidget);
      expect(find.text('0 Personen'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Schauspiel'),
          matching: find.byTooltip('Rolle verwalten'),
        ),
      );
      await tester.pumpAndSettle();
      final blocked = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(
          PopupMenuItem<String>,
          'Entfernen (noch 3 Personen)',
        ),
      );
      expect(blocked.enabled, isFalse);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Maske'),
          matching: find.byTooltip('Rolle verwalten'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entfernen'));
      await tester.pumpAndSettle();
      expect(find.text('Rolle entfernen?'), findsOneWidget);
      expect(server.actionBodies, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Entfernen'));
      await tester.pumpAndSettle();
      expect(server.actionBodies.single, {
        'action': 'personRole.delete',
        'id': 'role-free',
        'version': 2,
      });
      expect(find.text('Rolle entfernt.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the role name dialog only saves a name', (tester) async {
    final server = TestServer();
    await _pump(tester, server, (c) => RolesAdminScreen(controller: c));
    await tester.tap(find.text('Rolle anlegen'));
    await tester.pumpAndSettle();
    FilledButton save() =>
        tester.widget(find.widgetWithText(FilledButton, 'Speichern'));
    expect(save().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '  Licht ');
    await tester.pump();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.single['action'], 'personRole.save');
    expect(server.actionBodies.single['name'], 'Licht');
    expect(find.text('Rolle angelegt.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
