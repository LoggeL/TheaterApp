import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/accounts/accounts.dart';
import 'package:theater_app/features/casting/casting.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';

import 'account_roster_test.dart' show fixture;
import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

/// [fixture] as plain JSON plus Sam's approved account (person 2).
JsonMap _withSam({String role = 'member', List<String>? permissions}) {
  final data = jsonMap(jsonDecode(jsonEncode(fixture())));
  (data['accounts'] as List).add({
    'uid': 'sam',
    'name': 'Sam',
    'email': 'sam@example.test',
    'personId': 2,
    'role': role,
    'permissions': ?permissions,
    'status': 'approved',
    'identityReady': true,
    'version': 3,
  });
  return data;
}

void _features(TestServer server, List<String> features) =>
    server.data['capabilities'] = {
      ...jsonMap(server.data['capabilities']),
      'features': features,
    };

Future<AppController> _pump(
  WidgetTester tester,
  TestServer server,
  AccountsAdminScreen Function(AppController) screen, {
  Size size = const Size(1000, 2400),
}) async {
  tester.view.physicalSize = size;
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
  return controller;
}

/// Opens the "Zugang verwalten" menu of the row [key].
Future<void> _menu(WidgetTester tester, String key) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey('access-entry-$key')),
      matching: find.byTooltip('Zugang verwalten'),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the collapsed section of inactive people.
Future<void> _showInactive(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('access-inactive-toggle'));
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

Finder _inRow(String key, String text) => find.descendant(
  of: find.byKey(ValueKey('access-entry-$key')),
  matching: find.text(text),
);

/// Answers the account list from [data] and applies account changes to it;
/// [conflict] refuses them like a stale version.
void _serve(
  TestServer server,
  JsonMap data,
  List<JsonMap> changes, {
  bool Function()? conflict,
}) {
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (path.endsWith('/admin/accounts')) {
      return Future.value(jsonResponse(data));
    }
    if (path.endsWith('/actions')) {
      if (server.offline) {
        return Future<http.Response>.error(http.ClientException('offline'));
      }
      final body = jsonMap(jsonDecode(request.body));
      changes.add(body);
      if (conflict?.call() == true) {
        return Future.value(
          jsonResponse({
            'error': 'Das Konto hat sich geändert.',
            'code': 'version_conflict',
          }, 409),
        );
      }
      final account = (data['accounts'] as List).cast<JsonMap>().firstWhere(
        (a) => a['uid'] == body['uid'],
      );
      for (final key in ['status', 'role', 'permissions']) {
        if (body.containsKey(key)) account[key] = body[key];
      }
      if (body['action'] == 'account.role' &&
          !body.containsKey('permissions')) {
        account['permissions'] = <String>[];
      }
      account['version'] = intValue(account['version']) + 1;
      return Future.value(jsonResponse({'ok': true}));
    }
    return null;
  };
}

void _clearSnackBars(WidgetTester tester) => ScaffoldMessenger.of(
  tester.element(find.byType(Scaffold).first),
).clearSnackBars();

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('admins delete an account only after confirmation', (
    tester,
  ) async {
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
    // The former "Konten" view with its filter still opens the right rows.
    await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(
        controller: c,
        initialView: 'accounts',
        initialFilter: 'suspended',
      ),
    );
    expect(find.text('1 Eintrag'), findsOneWidget);
    await _menu(tester, '4');
    await tester.tap(find.text('Konto löschen'));
    await tester.pumpAndSettle();
    expect(find.text('Konto löschen?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(deletions, isEmpty);
    await _menu(tester, '4');
    await tester.tap(find.text('Konto löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    expect(deletions.single.url.path, endsWith('/admin/accounts/kim/'));
    expect(jsonDecode(deletions.single.body), {'version': 2});
    expect(find.text('Konto gelöscht.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('suspending asks first and can be undone from the SnackBar', (
    tester,
  ) async {
    final server = TestServer();
    final data = jsonMap(jsonDecode(jsonEncode(fixture())));
    final statusChanges = <JsonMap>[];
    _serve(server, data, statusChanges);
    await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(
        controller: c,
        initialView: 'accounts',
        initialFilter: 'approved',
      ),
    );
    expect(find.text('1 Eintrag'), findsOneWidget);
    await _menu(tester, '1');
    await tester.tap(find.text('Zugang sperren'));
    await tester.pumpAndSettle();
    expect(find.text('Zugang sperren?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(statusChanges, isEmpty);

    await _menu(tester, '1');
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
    expect(find.text('0 Einträge'), findsOneWidget);

    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(statusChanges.last, {
      'action': 'account.status',
      'uid': 'admin',
      'version': 2,
      'status': 'approved',
    });
    expect(find.text('1 Eintrag'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the rights sheet gives and takes rights and the admin role', (
    tester,
  ) async {
    final server = TestServer();
    _features(server, ['accountRole', 'accountPermissions']);
    final data = _withSam();
    final changes = <JsonMap>[];
    var conflict = false;
    _serve(server, data, changes, conflict: () => conflict);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    expect(_inRow('2', 'Mitglied'), findsOneWidget);
    final admin = find.byKey(const ValueKey('rights-admin'));
    final events = find.byKey(const ValueKey('rights-permission-events'));

    Future<void> openSheet() async {
      await _menu(tester, '2');
      await tester.tap(find.text('Rechte bearbeiten…'));
      await tester.pumpAndSettle();
    }

    Future<void> save(String confirm) async {
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, confirm));
      await tester.pumpAndSettle();
    }

    // Grant "Termine verwalten"; nothing changes before the confirmation.
    await openSheet();
    expect(find.text('Rechte von Sam'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(admin).value, isFalse);
    await tester.tap(events);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Sam kann danach alle Termine, Serien und Terminfinder verwalten '
        'und Rückmeldungen mit Absagegründen sehen.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Abbrechen').last);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await save('Erlauben');
    expect(changes.single, {
      'action': 'account.permissions',
      'uid': 'sam',
      'version': 3,
      'permissions': ['events'],
    });
    expect(find.text('Sam darf jetzt Termine verwalten.'), findsOneWidget);
    expect(_inRow('2', 'Termine verwalten'), findsOneWidget);
    _clearSnackBars(tester);
    await tester.pumpAndSettle();

    // Admin covers every right; the boxes show it and cannot be changed.
    await openSheet();
    await tester.tap(admin);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(events).onChanged, isNull);
    expect(find.text('Admins haben alle Rechte'), findsOneWidget);
    await save('Admin-Rechte geben');
    expect(changes.last, {
      'action': 'account.role',
      'uid': 'sam',
      'version': 4,
      'role': 'admin',
    });
    expect(find.text('Sam ist jetzt Admin.'), findsOneWidget);
    expect(_inRow('2', 'Admin'), findsOneWidget);
    _clearSnackBars(tester);
    await tester.pumpAndSettle();

    // Back to member: managing events stays checked unless taken away.
    await openSheet();
    await tester.tap(admin);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(events).value, isTrue);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(find.textContaining('weiterhin alle Termine'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Entziehen'));
    await tester.pumpAndSettle();
    expect(changes.last, {
      'action': 'account.role',
      'uid': 'sam',
      'version': 5,
      'role': 'member',
      'permissions': ['events'],
    });
    expect(find.text('Sam ist jetzt Mitglied.'), findsOneWidget);
    expect(_inRow('2', 'Termine verwalten'), findsOneWidget);
    _clearSnackBars(tester);
    await tester.pumpAndSettle();

    // A conflict is reported and the list reloads the current rights.
    conflict = true;
    await openSheet();
    await tester.tap(events);
    await tester.pumpAndSettle();
    await save('Entziehen');
    expect(changes, hasLength(4));
    expect(changes.last['permissions'], <String>[]);
    expect(find.text('Sam verwaltet keine Termine mehr.'), findsNothing);
    expect(find.byType(AccountRightsSheet), findsNothing);
    expect(_inRow('2', 'Termine verwalten'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without server support the rights stay hidden', (tester) async {
    final server = TestServer();
    _serve(server, _withSam(), []);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    await _menu(tester, '2');
    expect(find.text('Zugang sperren'), findsOneWidget);
    expect(find.text('Person bearbeiten'), findsOneWidget);
    expect(find.text('Rechte bearbeiten…'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('servers without account rights only offer the admin role', (
    tester,
  ) async {
    final server = TestServer();
    _features(server, ['accountRole']);
    final changes = <JsonMap>[];
    _serve(server, _withSam(role: 'admin'), changes);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    await _menu(tester, '2');
    await tester.tap(find.text('Rechte bearbeiten…'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('rights-permission-events')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('rights-admin')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Verwaltung aber nicht mehr'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Entziehen'));
    await tester.pumpAndSettle();
    // Older servers get no rights along with the role.
    expect(changes.single, {
      'action': 'account.role',
      'uid': 'sam',
      'version': 3,
      'role': 'member',
    });
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rights of a suspended account rest and can still be taken', (
    tester,
  ) async {
    final server = TestServer();
    _features(server, ['accountRole', 'accountPermissions']);
    final data = jsonMap(jsonDecode(jsonEncode(fixture())));
    (data['accounts'] as List)[1]['permissions'] = ['events'];
    final changes = <JsonMap>[];
    _serve(server, data, changes);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    // Kim is inactive: the section at the end opens on demand.
    expect(find.byKey(const ValueKey('access-entry-4')), findsNothing);
    await _showInactive(tester);
    expect(_inRow('4', 'Termine verwalten · ruht'), findsOneWidget);
    expect(_inRow('4', 'Person inaktiv'), findsOneWidget);
    await _menu(tester, '4');
    await tester.tap(find.text('Rechte bearbeiten…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Die Rechte ruhen'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('rights-admin')))
          .onChanged,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('rights-permission-events')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Entziehen'));
    await tester.pumpAndSettle();
    expect(changes.single, {
      'action': 'account.permissions',
      'uid': 'kim',
      'version': 2,
      'permissions': <String>[],
    });
    expect(_inRow('4', 'Mitglied · ruht'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rights changes need a connection and are never queued', (
    tester,
  ) async {
    final server = TestServer();
    _features(server, ['accountRole', 'accountPermissions']);
    final changes = <JsonMap>[];
    _serve(server, _withSam(), changes);
    final controller = await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(controller: c),
    );
    // The connection breaks while saving: nothing waits in the outbox, and
    // the outcome is reported as open.
    server.offline = true;
    await _menu(tester, '2');
    await tester.tap(find.text('Rechte bearbeiten…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rights-permission-events')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Erlauben'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountRightsSheet), findsNothing);
    expect(
      find.textContaining('ob die Rechte geändert wurden, ist offen'),
      findsOneWidget,
    );
    expect(controller.outbox, isEmpty);
    expect(changes, isEmpty);
    expect(_inRow('2', 'Mitglied'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('known offline, the rights sheet says so and cannot save', (
    tester,
  ) async {
    final server = TestServer();
    _features(server, ['accountRole', 'accountPermissions']);
    final changes = <JsonMap>[];
    _serve(server, _withSam(), changes);
    final controller = await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(controller: c),
    );
    await _menu(tester, '2');
    await tester.tap(find.text('Rechte bearbeiten…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rights-permission-events')));
    await tester.pumpAndSettle();
    server.offline = true;
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(controller.isOffline, isTrue);
    // The note sits in the sheet, where a SnackBar would be covered.
    expect(find.byKey(const ValueKey('rights-offline')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountRightsSheet), findsOneWidget);
    expect(find.text('Termine verwalten erlauben?'), findsNothing);
    expect(changes, isEmpty);
    expect(controller.outbox, isEmpty);
    // Back online, saving works again.
    server.offline = false;
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rights-offline')), findsNothing);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Erlauben'));
    await tester.pumpAndSettle();
    expect(changes.single['permissions'], ['events']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a suspended registration without a person is not released', (
    tester,
  ) async {
    final server = TestServer();
    final data = jsonMap(jsonDecode(jsonEncode(fixture())));
    (data['accounts'] as List).add({
      'uid': 'blocked',
      'name': 'Block',
      'email': 'block@example.test',
      'personId': null,
      'role': 'member',
      'status': 'suspended',
      'identityReady': true,
      'version': 1,
    });
    _serve(server, data, []);
    await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(controller: c, initialStatus: 'suspended'),
    );
    expect(find.text('2 Einträge'), findsOneWidget);
    // Kim's linked account can return, with its resting right.
    await _menu(tester, '4');
    expect(find.text('Wieder freigeben'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(_inRow('blocked', 'Konto ohne Person'), findsOneWidget);
    expect(_inRow('blocked', 'Mitglied · ruht'), findsNothing);
    await _menu(tester, 'blocked');
    expect(find.text('Wieder freigeben'), findsNothing);
    expect(find.text('Konto löschen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed reload keeps the last list visible', (tester) async {
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
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    expect(find.text('Personen & Zugänge'), findsOneWidget);
    // Four people; the waiting registration stands apart on top.
    expect(find.text('4 Einträge'), findsOneWidget);
    expect(find.text('Wartet auf Zuordnung (1)'), findsOneWidget);
    expect(find.text('Drehbuchrollen (4)'), findsNothing);
    fail = true;
    await tester.tap(find.byTooltip('Aktualisieren'));
    await tester.pumpAndSettle();
    expect(find.text('4 Einträge'), findsOneWidget);
    expect(find.byKey(const ValueKey('access-not-loaded')), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a person far down the list is scrolled to and highlighted', (
    tester,
  ) async {
    final server = TestServer();
    final data = jsonMap(jsonDecode(jsonEncode(fixture())));
    (data['members'] as List).addAll([
      for (var i = 10; i < 50; i++)
        {'id': i, 'name': 'Person $i', 'active': true},
      {'id': 99, 'name': 'Zora Zuletzt', 'active': true},
    ]);
    _serve(server, data, []);
    await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(controller: c, initialPersonId: 99),
      size: const Size(400, 900),
    );
    expect(find.text('Zora Zuletzt').hitTestable(), findsOneWidget);
    final card = tester.widget<Card>(
      find.byKey(const ValueKey('access-entry-99')),
    );
    expect((card.shape! as RoundedRectangleBorder).side.width, 2);
    expect(
      tester.widget<Card>(find.byKey(const ValueKey('access-entry-3'))).shape,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a registration push highlights the waiting account', (
    tester,
  ) async {
    final server = TestServer();
    _serve(server, jsonMap(jsonDecode(jsonEncode(fixture()))), []);
    await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(
        controller: c,
        initialStatus: 'waiting',
        initialUid: 'new',
      ),
    );
    // The former waiting filter shows the whole list; the registration is
    // highlighted in the block on top.
    expect(find.text('4 Einträge'), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(find.byKey(const ValueKey('status-all')))
          .selected,
      isTrue,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('access-waiting')),
        matching: find.byKey(const ValueKey('access-entry-new')),
      ),
      findsOneWidget,
    );
    final card = tester.widget<Card>(
      find.byKey(const ValueKey('access-entry-new')),
    );
    expect((card.shape! as RoundedRectangleBorder).side.width, 2);
    expect(_inRow('new', 'Wartet auf Freigabe'), findsOneWidget);
    expect(_inRow('new', 'Konto ohne Person'), findsOneWidget);
    expect(_inRow('new', 'Prüfen & verknüpfen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (view, filter, status, count) in [
    // Waiting registrations always show on top, so no filter is needed.
    ('accounts', 'pending', 'all', '4 Einträge'),
    ('accounts', 'approved', 'approved', '1 Eintrag'),
    ('accounts', 'suspended', 'suspended', '1 Eintrag'),
    ('accounts', 'rejected', 'rejected', '0 Einträge'),
    ('people', 'linked', 'approved', '1 Eintrag'),
    ('people', 'unlinked', 'noAccount', '2 Einträge'),
    ('people', 'all', 'all', '4 Einträge'),
  ]) {
    testWidgets('the former view $view/$filter opens the $status filter', (
      tester,
    ) async {
      final server = TestServer();
      _serve(server, jsonMap(jsonDecode(jsonEncode(fixture()))), []);
      await _pump(
        tester,
        server,
        (c) => AccountsAdminScreen(
          controller: c,
          initialView: view,
          initialFilter: filter,
        ),
      );
      expect(
        tester
            .widget<FilterChip>(find.byKey(ValueKey('status-$status')))
            .selected,
        isTrue,
      );
      expect(find.text(count), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('the former roles view opens the script roles', (tester) async {
    final server = TestServer();
    var loads = 0;
    server.override = (request) {
      if (request.url.path.contains('/admin/accounts')) loads++;
      return null;
    };
    await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(
        controller: c,
        initialView: 'roles',
        initialFilter: 'unassigned',
      ),
    );
    // They live in "Produktionen & Besetzung" now and need no account list.
    expect(find.byType(ScriptRolesScreen), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('script-roles-unassigned')),
          )
          .selected,
      isTrue,
    );
    expect(loads, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a summary part clears the other filters and the search', (
    tester,
  ) async {
    final server = TestServer();
    server.data['personRoles'] = [
      {'id': 'role-3', 'name': 'Technik'},
    ];
    final data = jsonMap(jsonDecode(jsonEncode(fixture())));
    (data['members'] as List).first['roleIds'] = ['role-3'];
    _serve(server, data, []);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    await tester.tap(find.byKey(const ValueKey('access-role-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technik').last);
    await tester.pumpAndSettle();
    expect(find.text('1 Eintrag'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Alex');
    await tester.pumpAndSettle();
    final summary = find.byKey(const ValueKey('access-summary'));
    await tester.tap(
      find.descendant(of: summary, matching: find.text('4 Personen')),
    );
    await tester.pumpAndSettle();
    expect(find.text('4 Einträge'), findsOneWidget);
    expect(find.text('Alle Rollen'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    // Filters that find nobody say so.
    await tester.tap(find.byKey(const ValueKey('status-suspended')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('right-admin')));
    await tester.pumpAndSettle();
    expect(find.text('0 Einträge'), findsOneWidget);
    expect(find.text('Keine Treffer'), findsOneWidget);
    // The waiting registration stays on top, whatever the filters say.
    expect(find.text('Wartet auf Zuordnung (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the own row only links to the person', (tester) async {
    final server = TestServer()..userId = 'admin';
    _features(server, ['accountRole', 'accountPermissions']);
    _serve(server, jsonMap(jsonDecode(jsonEncode(fixture()))), []);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    expect(_inRow('1', 'Du'), findsOneWidget);
    await _menu(tester, '1');
    expect(find.byKey(const ValueKey('account-person-edit-1')), findsOneWidget);
    expect(find.text('Rechte bearbeiten…'), findsNothing);
    expect(find.text('Zugang sperren'), findsNothing);
    expect(find.text('Konto löschen'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('waiting registrations stay on top, inactive people at the end', (
    tester,
  ) async {
    final server = TestServer();
    _serve(server, jsonMap(jsonDecode(jsonEncode(fixture()))), []);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    final block = find.byKey(const ValueKey('access-waiting'));
    expect(
      find.descendant(of: block, matching: find.text('Prüfen & verknüpfen')),
      findsOneWidget,
    );
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(top(block), lessThan(top(find.byType(TextField))));
    // A search narrows the list below, never the block.
    await tester.enterText(find.byType(TextField), 'Alex');
    await tester.pumpAndSettle();
    expect(find.text('1 Eintrag'), findsOneWidget);
    expect(find.byKey(const ValueKey('access-entry-new')), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    // Kim is inactive: collapsed at the end until opened.
    expect(find.text('Nicht aktiv (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('access-entry-4')), findsNothing);
    await _showInactive(tester);
    expect(
      top(find.byKey(const ValueKey('access-entry-4'))),
      greaterThan(top(find.byKey(const ValueKey('access-entry-3')))),
    );
    // Searching shows inactive matches right away.
    await _showInactive(tester);
    expect(find.byKey(const ValueKey('access-entry-4')), findsNothing);
    await tester.enterText(find.byType(TextField), 'Kim');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('access-entry-4')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a row opens the person; the button creates one', (tester) async {
    final server = TestServer();
    _serve(server, jsonMap(jsonDecode(jsonEncode(fixture()))), []);
    await _pump(tester, server, (c) => AccountsAdminScreen(controller: c));
    await tester.tap(_inRow('1', 'Alex'));
    await tester.pumpAndSettle();
    expect(find.text('Person bearbeiten'), findsOneWidget);
    expect(find.byType(PersonAccessSection), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // A registration has no person to open.
    await tester.tap(_inRow('new', 'Sam'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberEditorScreen), findsNothing);
    await tester.tap(
      find.widgetWithText(FloatingActionButton, 'Person anlegen'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MemberEditorScreen), findsOneWidget);
    expect(
      tester.widget<MemberEditorScreen>(find.byType(MemberEditorScreen)).member,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without the account list the people stay editable', (
    tester,
  ) async {
    final server = TestServer();
    server.override = (request) => request.url.path.contains('/admin/accounts')
        ? Future.value(jsonResponse({'error': 'Server nicht erreichbar.'}, 503))
        : null;
    final controller = await _pump(
      tester,
      server,
      (c) => AccountsAdminScreen(controller: c),
    );
    expect(find.text('Zugänge nicht geladen'), findsOneWidget);
    // The people come from the app's own data, without access details.
    final person = controller.memberRecords.firstWhere(
      (m) => m['active'] != false,
    );
    final row = find.byKey(ValueKey('access-entry-${person['id']}'));
    expect(row, findsOneWidget);
    expect(find.byKey(const ValueKey('access-summary')), findsNothing);
    expect(find.byKey(const ValueKey('status-all')), findsNothing);
    expect(
      find.descendant(of: row, matching: find.text('Kein Konto')),
      findsNothing,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Person bearbeiten'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
