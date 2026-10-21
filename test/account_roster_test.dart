import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/accounts/accounts.dart';

import 'firebase_access_test.dart' show FakeIdentity;

JsonMap fixture() => {
  'members': [
    {'id': 1, 'name': 'Alex', 'active': true},
    {'id': 2, 'name': 'Sam', 'active': true},
    {'id': 3, 'name': 'Sam', 'active': true},
    {'id': 4, 'name': 'Kim', 'active': false},
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
      'identityReady': true,
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

/// [fixture] plus an admin's own row, a holder of "Termine verwalten", a
/// director, an inactive person with an approved account, an unconfirmed
/// registration and a rejected account without a person.
JsonMap accessFixture() {
  // A JSON copy, so the lists take any entry.
  final data = jsonMap(jsonDecode(jsonEncode(fixture())));
  (data['members'] as List).addAll([
    {
      'id': 5,
      'name': 'Dana',
      'active': true,
      'roleIds': ['role-3'],
    },
    {'id': 6, 'name': 'Eli', 'active': true},
    {'id': 7, 'name': 'Fynn', 'active': false},
  ]);
  (data['accounts'] as List)
    ..first['emailVerified'] = true
    ..first['lastSeenAt'] = '2026-10-03T10:00:00Z'
    ..first['approvedAt'] = '2026-09-01T10:00:00Z'
    ..[1]['permissions'] = ['events']
    ..[2]['createdAt'] = '2026-09-11T10:00:00Z'
    ..addAll([
      {
        'uid': 'dana',
        'name': 'Dana',
        'email': 'dana@example.test',
        'personId': 5,
        'role': 'member',
        'permissions': ['events', 'unknown'],
        'status': 'approved',
        'identityReady': true,
        'emailVerified': true,
        'provider': 'password',
        'version': 4,
      },
      {
        'uid': 'eli',
        'name': 'Eli',
        'email': 'eli@example.test',
        'personId': 6,
        'role': 'member',
        'status': 'approved',
        'identityReady': true,
        'version': 1,
      },
      {
        'uid': 'fynn',
        'name': 'Fynn',
        'email': 'fynn@example.test',
        'personId': 7,
        'role': 'member',
        'status': 'approved',
        'identityReady': true,
        'version': 1,
      },
      {
        'uid': 'unverified',
        'name': 'Neu',
        'email': 'neu@example.test',
        'personId': null,
        'status': 'pending',
        'identityReady': false,
        'createdAt': '2026-09-10T10:00:00Z',
        'version': 1,
      },
      {
        'uid': 'gone',
        'name': 'Robo',
        'email': 'robo@example.test',
        'personId': null,
        'status': 'rejected',
        'identityReady': true,
        'botCheck': 'trap',
        'createdAt': '2026-09-01T10:00:00Z',
        'version': 2,
      },
    ]);
  (data['productions'] as List)
    ..first['directorMemberIds'] = [6]
    ..add({
      'id': 'old',
      'title': 'Altes Stück',
      'archived': true,
      'directorMemberIds': [5],
      'roles': [],
    });
  return data;
}

void main() {
  test(
    'joins by person IDs only, preserves multiple roles and inactive links',
    () {
      final r = AccountRoster(fixture());
      expect(r.linkedCount, 1);
      expect(r.withoutAccountCount, 2);
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

  test('one entry per person, then accounts without a person by age', () {
    final r = AccountRoster(accessFixture());
    expect(r.accessEntries.map((e) => e.key), [
      '1', '5', '6', '7', '4', '2', '3', 'new', 'unverified', 'gone', //
    ]);
    String status(String key) =>
        accessStatus(r.accessEntries.firstWhere((e) => e.key == key));
    expect(status('1'), 'approved');
    // An inactive person keeps the status of the account; the flag is apart.
    expect(status('7'), 'approved');
    expect(r.entryFor(personId: 7)!.inactive, isTrue);
    expect(status('4'), 'suspended');
    expect(status('2'), 'noAccount');
    expect(status('new'), 'waiting');
    expect(status('unverified'), 'unverified');
    expect(status('gone'), 'rejected');
    expect(r.entryFor(uid: 'gone')!.unassigned, isTrue);
    expect(accessStatusLabel('waiting'), 'Wartet auf Freigabe');
    expect(accountStatus(null), 'Kein Konto');

    expect(r.linkedCount, 4);
    expect(r.withoutAccountCount, 2);
    expect(r.waitingCount, 1);
    expect(r.unverifiedCount, 1);
    expect(r.adminCount, 1);
    // Kim's right rests while the account is suspended: the summary counts
    // only Dana, the filter still finds both.
    expect(r.permissionCount('events'), 1);
    expect(r.rightCount('events'), 2);
    expect(r.statusCount('inactive'), 2);
    expect(r.statusCount('unassigned'), 3);
    expect(r.rightCount('director'), 1);
    // Plain linked members; registrations are none.
    expect(r.rightCount('member'), 1);

    final dana = r.rights(r.entryFor(personId: 5)!);
    // Unknown rights and archived productions do not count.
    expect(dana.permissions, ['events']);
    expect(dana.directorOf, isEmpty);
    expect(r.rights(r.entryFor(personId: 6)!).directorOf, ['Sommerstück']);
    final kim = r.rights(r.entryFor(personId: 4)!);
    expect(
      [kim.resting, kim.memberOnly, kim.permissions],
      // A suspended account keeps its rights, resting.
      [
        true,
        false,
        ['events'],
      ],
    );
    expect(r.rights(r.entryFor(personId: 1)!).admin, isTrue);
    expect(r.rights(r.entryFor(uid: 'new')!).memberOnly, isFalse);

    // Search covers person roles by name; the role filter by id.
    final danaEntry = r.entryFor(personId: 5)!;
    expect(r.entryMatches(danaEntry, 'Technik'), isFalse);
    expect(r.entryMatches(danaEntry, 'Technik', roleNames: 'Technik'), isTrue);
    expect(r.entryMatches(danaEntry, '', roleId: 'role-3'), isTrue);
    expect(
      r.entryMatches(r.entryFor(personId: 6)!, '', roleId: 'role-3'),
      isFalse,
    );
    expect(r.entryMatches(r.entryFor(uid: 'gone')!, 'robo@'), isTrue);
    expect(
      r.entryMatches(danaEntry, '', status: 'approved', right: 'events'),
      isTrue,
    );
    expect(r.entryMatches(danaEntry, '', right: 'admin'), isFalse);
  });

  test('rejected and unlinked accounts hold no rights', () {
    final data = accessFixture();
    // A rejected former admin keeps the stored role, a suspended
    // registration never had a person.
    (data['accounts'] as List).addAll([
      {
        'uid': 'former',
        'name': 'Eli',
        'personId': 6,
        'role': 'admin',
        'permissions': ['events'],
        'status': 'rejected',
        'version': 3,
      },
      {
        'uid': 'blocked',
        'name': 'Block',
        'personId': null,
        'role': 'member',
        'status': 'suspended',
        'version': 2,
      },
    ]);
    // Eli's approved account goes, so the rejected one is his.
    (data['accounts'] as List).removeWhere((a) => a['uid'] == 'eli');
    final r = AccountRoster(data);
    final former = r.rights(r.entryFor(personId: 6)!);
    expect(
      [former.admin, former.permissions, former.resting, former.hasAccess],
      [false, isEmpty, false, false],
    );
    // Direction comes from the person and stays.
    expect(former.directorOf, ['Sommerstück']);
    expect(r.adminCount, 1);
    expect(r.rightCount('admin'), 1);
    final blocked = r.rights(r.entryFor(uid: 'blocked')!);
    expect([blocked.hasAccess, blocked.memberOnly], [false, false]);
  });

  for (final width in [320.0, 1100.0]) {
    testWidgets(
      'access overview summarises, filters, shows rights and starts explicit '
      'linking at $width px',
      (tester) async {
        tester.view.physicalSize = Size(width, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final data = accessFixture();
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
        final summary = find.byKey(const ValueKey('access-summary'));
        for (final part in [
          '7 Personen',
          '4 freigegeben',
          '2 ohne Konto',
          '1 wartet',
          '1 unbestätigt',
          '1 Admin',
          // Kim's suspended right rests and is not counted.
          '1 Termine verwalten',
        ]) {
          expect(
            find.descendant(of: summary, matching: find.text(part)),
            findsOneWidget,
            reason: part,
          );
        }
        expect(find.text('Zugänge (10)'), findsOneWidget);
        expect(find.text('10 Einträge'), findsOneWidget);
        // The own row with its admin rights and login details.
        final alex = find.byKey(const ValueKey('access-entry-1'));
        for (final text in [
          'Du',
          'Freigegeben',
          'Admin',
          'Google · bestätigt · zuletzt aktiv 3.10.2026 · freigegeben 1.9.2026',
        ]) {
          expect(
            find.descendant(of: alex, matching: find.text(text)),
            findsOneWidget,
            reason: text,
          );
        }

        Future<void> chip(String key) async {
          final chip = find.byKey(ValueKey(key));
          await tester.ensureVisible(chip);
          await tester.tap(chip);
          await tester.pumpAndSettle();
        }

        Future<void> search(String query) async {
          await tester.enterText(find.byType(TextField), query);
          await tester.pumpAndSettle();
        }

        await chip('status-inactive');
        expect(find.text('2 Einträge'), findsOneWidget);
        expect(find.text('Person inaktiv'), findsNWidgets(2));
        await chip('status-unassigned');
        expect(find.text('3 Einträge'), findsOneWidget);
        await chip('status-rejected');
        expect(find.text('Verdacht: Bot-Falle'), findsOneWidget);
        expect(find.text('Erneut prüfen'), findsOneWidget);
        await chip('status-unverified');
        expect(find.text('Wartet auf E-Mail-Bestätigung'), findsOneWidget);
        expect(find.text('Prüfen & verknüpfen'), findsNothing);
        await chip('status-all');

        await chip('right-events');
        expect(find.text('2 Einträge'), findsOneWidget);
        expect(find.text('Termine verwalten'), findsOneWidget);
        // Rights of a suspended account rest until a new approval.
        expect(find.text('Termine verwalten · ruht'), findsOneWidget);
        await chip('right-director');
        expect(find.text('Regie: Sommerstück'), findsOneWidget);
        expect(find.text('Regie: Altes Stück'), findsNothing);
        await chip('right-member');
        expect(find.text('1 Eintrag'), findsOneWidget);
        expect(find.text('Fynn'), findsOneWidget);
        expect(find.text('Mitglied'), findsOneWidget);
        await chip('right-all');

        await search('');
        final withoutAccount = find.descendant(
          of: summary,
          matching: find.text('2 ohne Konto'),
        );
        await tester.ensureVisible(withoutAccount);
        await tester.tap(withoutAccount);
        await tester.pumpAndSettle();
        expect(find.text('2 Einträge'), findsOneWidget);
        expect(find.text('alex@example.test'), findsNothing);
        await search('Graf');
        expect(find.text('1 Eintrag'), findsOneWidget);
        await tester.ensureVisible(find.text('Konto verknüpfen'));
        await tester.tap(find.text('Konto verknüpfen'));
        await tester.pumpAndSettle();
        // Unconfirmed registrations cannot be approved yet.
        final unconfirmed = find.widgetWithText(
          ListTile,
          'neu@example.test · E-Mail unbestätigt',
        );
        expect(tester.widget<ListTile>(unconfirmed).enabled, isFalse);
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
