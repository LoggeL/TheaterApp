import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/accounts/accounts.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

const _people = [
  TheaterMember(id: 1, name: 'Alex Bühnenfreund'),
  TheaterMember(id: 2, name: 'Sam Vorhang'),
  TheaterMember(id: 3, name: 'Sam Vorang'),
  TheaterMember(id: 4, name: 'Kim Kulisse'),
];

JsonMap _account(String name) => {
  'uid': 'new',
  'name': name,
  'email': 'neu@example.test',
  'status': 'pending',
  'identityReady': true,
  'emailVerified': true,
  'version': 1,
};

Future<void> _pumpApproval(
  WidgetTester tester,
  TestServer server,
  JsonMap account, {
  List<JsonMap> accounts = const [],
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: AccountApprovalScreen(
        controller: controller,
        account: account,
        accounts: [...accounts, account],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

int? _selected(WidgetTester tester) =>
    tester.widget<RadioGroup<int>>(find.byType(RadioGroup<int>)).groupValue;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('candidates are ranked by name similarity', () {
    expect(rankApprovalCandidates('Sam Vorhang', _people).map((m) => m.id), [
      2,
      3,
      1,
      4,
    ]);
    // Accents and case do not matter; a typo still ranks as similar.
    expect(rankApprovalCandidates('alex buehnenfreund', _people).first.id, 1);
    expect(rankApprovalCandidates('Kim Kulise', _people).first.id, 4);
    expect(uniqueExactMatch('Sam Vorhang', _people)?.id, 2);
    expect(uniqueExactMatch('Vorhang', _people), isNull);
    expect(
      uniqueExactMatch('Sam Vorhang', [
        ..._people,
        const TheaterMember(id: 9, name: 'Sam Vorhang'),
      ]),
      isNull,
    );
  });

  testWidgets('a unique exact match is preselected as suggestion and '
      'linked people are collapsed', (tester) async {
    final server = TestServer();
    await _pumpApproval(
      tester,
      server,
      _account('Sam Vorhang'),
      accounts: [
        {'uid': 'alex', 'personId': 1, 'status': 'approved'},
      ],
    );
    expect(_selected(tester), 5);
    expect(find.text('Vorschlag'), findsOneWidget);
    // The suggestion is listed first.
    final first = find.byType(RadioListTile<int>).first;
    expect(
      find.descendant(of: first, matching: find.text('Sam Vorhang')),
      findsOneWidget,
    );
    expect(find.text('Bereits verknüpft (1)'), findsOneWidget);
    expect(find.text('Alex Bühnenfreund'), findsNothing);
    await tester.tap(find.text('Bereits verknüpft (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Alex Bühnenfreund'), findsOneWidget);

    await tester.tap(find.text('Kim Kulisse'));
    await tester.pumpAndSettle();
    expect(_selected(tester), 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new person is prefilled with the account name and selected', (
    tester,
  ) async {
    final server = TestServer();
    server.override = (request) {
      if (!request.url.path.contains('/actions')) return null;
      final body = jsonMap(jsonDecode(request.body));
      server.actionBodies.add(body);
      if (body['action'] == 'member.save') {
        (server.data['members'] as List).add({
          'id': 42,
          'name': body['name'],
          'active': true,
        });
        return Future.value(jsonResponse({'ok': true, 'id': 42}));
      }
      return Future.value(jsonResponse({'ok': true}));
    };
    await _pumpApproval(tester, server, _account('Nora Neu'));
    expect(_selected(tester), isNull);
    expect(find.text('Vorschlag'), findsNothing);
    await tester.ensureVisible(find.text('Person anlegen'));
    await tester.tap(find.text('Person anlegen'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberEditorScreen), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Nora Neu'), findsOneWidget);
    await tester.ensureVisible(find.text('Speichern'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['name'], 'Nora Neu');
    expect(find.byType(MemberEditorScreen), findsNothing);
    expect(_selected(tester), 42);
    expect(find.text('Person gespeichert.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
