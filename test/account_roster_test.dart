import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/core/account_roster.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/ui/accounts_admin.dart';
import 'package:theater_app/ui/admin.dart';
import 'package:theater_app/ui/theme.dart';
import 'firebase_access_test.dart' show FakeIdentity;

JsonMap fixture() => {
  'members': [
    {'id': 1, 'name': 'Alex', 'group': 'Theaterleitung', 'active': true},
    {'id': 2, 'name': 'Sam', 'group': 'Ensemble', 'active': true},
    {'id': 3, 'name': 'Sam', 'group': 'Technik', 'active': true},
    {'id': 4, 'name': 'Kim', 'group': 'Ensemble', 'active': false},
  ],
  'accounts': [
    {
      'uid': 'admin',
      'name': 'Alex',
      'email': 'alex@example.test',
      'personId': 1,
      'role': 'admin',
      'status': 'approved',
      'identityReady': true,
      'provider': 'google.com',
      'version': 1,
    },
    {
      'uid': 'kim',
      'name': 'Kim',
      'email': 'kim@example.test',
      'personId': 4,
      'role': 'member',
      'status': 'suspended',
      'version': 2,
    },
    {
      'uid': 'new',
      'name': 'Sam',
      'email': 'sam.real@example.test',
      'personId': null,
      'status': 'pending',
      'identityReady': true,
      'version': 1,
    },
  ],
  'productions': [
    {
      'id': 'one',
      'title': 'Sommerstück',
      'casting': {'A': 2, 'B': 2},
      'roles': [
        {'id': 'A', 'name': 'Graf', 'actor': 'Sam'},
        {'id': 'B', 'name': 'Bote', 'actor': 'Sam'},
        {'id': 'C', 'name': 'Chor', 'actor': ''},
      ],
    },
    {
      'id': 'two',
      'title': 'Winterstück',
      'casting': {'A': 3},
      'roles': [
        {'id': 'A', 'name': 'Geist', 'actor': 'Sam'},
      ],
    },
  ],
};
void main() {
  test(
    'joins by person IDs only, preserves multiple roles and inactive links',
    () {
      final r = AccountRoster(fixture());
      expect(r.linkedCount, 2);
      expect(r.pendingCount, 1);
      expect(
        r.accountFor(2),
        isNull,
      ); // Matching names never imply a login link.
      expect(r.accountFor(4)?['status'], 'suspended');
      expect(r.rolesFor(2).map((r) => r['name']), ['Graf', 'Bote']);
      expect(r.rolesFor(3).single['name'], 'Geist');
      expect(r.personMatches(r.memberFor(2)!, 'Sommerstück Graf'), isTrue);
      expect(r.personMatches(r.memberFor(3)!, 'Graf'), isFalse);
      expect(r.personMatches(r.memberFor(1)!, 'alex@example.test'), isTrue);
    },
  );
  for (final width in [320.0, 1100.0]) {
    testWidgets(
      'account overview filters, searches and starts explicit linking at $width px',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final data = fixture();
        final user = {
          'userId': 'alex@example.test',
          'displayName': 'Alex',
          'email': 'alex@example.test',
          'personId': 1,
          'role': 'admin',
          'status': 'approved',
          'identityReady': true,
        };
        final c = AppController(
          identity: FakeIdentity(),
          localStore: MemoryLocalStore(),
          credentialStore: MemoryCredentialStore(),
          apiClient: ApiClient(
            client: MockClient(
              (req) async => http.Response(
                jsonEncode(
                  req.url.path.contains('/admin/accounts')
                      ? data
                      : req.url.path.contains('/auth/session')
                      ? {'user': user}
                      : {'apiVersion': 1, ...data, 'user': user},
                ),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          ),
        );
        await c.init();
        await c.login(
          email: 'alex@example.test',
          password: 'Example long password',
          baseUrl: 'https://theater.example.test',
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: AccountsAdminScreen(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('2 verknüpft'), findsOneWidget);
        expect(find.text('2 ohne Konto'), findsOneWidget);
        await tester.tap(find.text('2 ohne Konto'));
        await tester.pumpAndSettle();
        expect(find.text('alex@example.test'), findsNothing);
        await tester.enterText(find.byType(TextField), 'Graf');
        await tester.pumpAndSettle();
        expect(find.text('1 Personen'), findsOneWidget);
        await tester.ensureVisible(find.text('Konto verknüpfen'));
        await tester.tap(find.text('Konto verknüpfen'));
        await tester.pumpAndSettle();
        expect(find.text('sam.real@example.test'), findsOneWidget);
        await tester.tap(find.text('sam.real@example.test'));
        await tester.pumpAndSettle();
        expect(find.byType(AccountApprovalScreen), findsOneWidget);
        final approval = tester.widget<AccountApprovalScreen>(
          find.byType(AccountApprovalScreen),
        );
        expect(approval.initialPersonId, 2);
        expect(approval.account['uid'], 'new');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}
