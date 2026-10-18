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
    // The subtitle shows hint and roles only, never the member number, and
    // is left out instead of rendering an empty line.
    expect(find.textContaining('Mitglied Nr.'), findsNothing);
    for (final tile in tester.widgetList<RadioListTile<int>>(
      find.byType(RadioListTile<int>),
    )) {
      final subtitle = (tile.subtitle as Text?)?.data;
      if (subtitle == null) continue;
      expect(subtitle.trim(), isNotEmpty);
      expect(subtitle, isNot(startsWith('·')));
      expect(subtitle, isNot(endsWith('·')));
    }
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

  testWidgets('accounts without a supplied name can be linked after review', (
    tester,
  ) async {
    final server = TestServer();
    await _pumpApproval(tester, server, {
      ..._account('Sam Vorhang'),
      'nameProvided': false,
      'provider': 'google.com',
    });
    expect(find.text('Name laut Google-Konto'), findsOneWidget);
    expect(find.text('Name zur Zuordnung des Kontos'), findsNothing);
    expect(
      find.text(
        'Der Name stammt vom Google-Konto und wurde nicht selbst angegeben. '
        'Bitte prüfe die Zuordnung anhand der E-Mail-Adresse.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Diese Person muss noch einen Namen zur Zuordnung angeben.'),
      findsNothing,
    );
    final button = find.widgetWithText(FilledButton, 'Verknüpfen & freigeben');
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(server.actionBodies.last, {
      'action': 'account.approve',
      'uid': 'new',
      'version': 1,
      'personId': 5,
      'role': 'member',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('a self-supplied name keeps the usual caption', (tester) async {
    await _pumpApproval(tester, TestServer(), _account('Nora Neu'));
    expect(find.text('Name zur Zuordnung des Kontos'), findsOneWidget);
    expect(find.textContaining('nicht selbst angegeben'), findsNothing);
  });

  test('the name source follows the sign-in provider', () {
    expect(accountNameSource('google.com'), 'Google-Konto');
    expect(accountNameSource('apple.com'), 'Apple-Konto');
    expect(accountNameSource('password'), 'Anmeldekonto');
    expect(accountNameSource(null), 'Anmeldekonto');
    expect(accountNameSource('example.org'), 'Anmeldekonto');
  });

  testWidgets('registrations without bot check are marked for admins', (
    tester,
  ) async {
    await _pumpApproval(tester, TestServer(), {
      ..._account('Neu Ohne'),
      'botCheck': 'missing',
    });
    expect(find.text('Ohne Botschutz'), findsOneWidget);
    expect(find.textContaining('Botschutz-Frage nicht'), findsOneWidget);
    for (final check in ['passed', null]) {
      await _pumpApproval(tester, TestServer(), {
        ..._account('Neu Mit'),
        'botCheck': check,
      });
      expect(find.text('Ohne Botschutz'), findsNothing);
    }
  });
}
