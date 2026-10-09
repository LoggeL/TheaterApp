import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/admin.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<void> openEditor(
    WidgetTester tester,
    TestServer server,
    JsonMap member,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openPage(
                context,
                MemberEditorScreen(controller: controller, member: member),
              ),
              child: const Text('Öffnen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'deleting a person needs the typed name and deletes linked accounts first',
    (tester) async {
      final server = TestServer();
      final member = {
        ...jsonMap(jsonList(server.data['members']).first),
        'active': false,
        'version': 4,
      };
      final id = intValue(member['id']), name = textValue(member['name']);
      final calls = <String>[];
      server.override = (request) {
        final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
        if (!path.contains('/admin/accounts')) return null;
        calls.add('${request.method} ${path.split('/v1').last}');
        if (request.method == 'DELETE') {
          expect(jsonDecode(request.body), {'version': 2});
          return Future.value(jsonResponse({'ok': true}));
        }
        return Future.value(
          jsonResponse({
            'accounts': [
              {
                'uid': 'linked-uid',
                'personId': id,
                'email': 'weg@example.invalid',
                'version': 2,
              },
              {'uid': 'other', 'personId': id + 1000, 'version': 1},
            ],
          }),
        );
      };
      await openEditor(tester, server, member);

      expect(find.text('Gefahrenbereich'), findsOneWidget);
      final open = find.widgetWithText(FilledButton, 'Person löschen');
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();

      expect(find.text('$name endgültig löschen?'), findsOneWidget);
      expect(find.textContaining('weg@example.invalid'), findsOneWidget);
      expect(find.textContaining('Besetzungen'), findsOneWidget);
      expect(find.textContaining('Rückmeldungen'), findsOneWidget);
      // Inactive people are already deactivated: no "Nur deaktivieren" here.
      expect(find.text('Nur deaktivieren'), findsNothing);
      FilledButton confirm() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Endgültig löschen'),
      );
      expect(confirm().onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, 'Jemand anderes');
      await tester.pump();
      expect(confirm().onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, ' $name ');
      await tester.pump();
      expect(confirm().onPressed, isNotNull);
      await tester.tap(find.text('Endgültig löschen'));
      await tester.pumpAndSettle();

      expect(calls, [
        'GET /admin/accounts',
        'DELETE /admin/accounts/linked-uid',
      ]);
      expect(server.actionBodies.last, {
        'action': 'member.delete',
        'id': id,
        'version': 4,
      });
      expect(find.byType(MemberEditorScreen), findsNothing);
      expect(find.text('$name wurde gelöscht.'), findsOneWidget);
    },
  );

  testWidgets('active people can be deactivated instead of deleted', (
    tester,
  ) async {
    final server = TestServer();
    final member = {
      ...jsonMap(jsonList(server.data['members']).first),
      'active': true,
      'version': 1,
    };
    server.override = (request) => request.url.path.contains('/admin/accounts')
        ? Future.value(jsonResponse({'accounts': <Object>[]}))
        : null;
    await openEditor(tester, server, member);
    final open = find.widgetWithText(OutlinedButton, 'Person löschen');
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.textContaining('kein App-Konto verknüpft'), findsOneWidget);
    expect(
      find.textContaining('Sanfter: Person nur deaktivieren'),
      findsOneWidget,
    );
    await tester.tap(find.text('Nur deaktivieren'));
    await tester.pumpAndSettle();
    expect(server.actionBodies.last['action'], 'member.save');
    expect(server.actionBodies.last['active'], false);
    expect(
      server.actionBodies.any((b) => b['action'] == 'member.delete'),
      isFalse,
    );
    expect(find.byType(MemberEditorScreen), findsNothing);
  });

  test(
    'a queued deletion hides the person until the server confirms',
    () async {
      final server = TestServer(), controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      final id = controller.members.first.id;
      server.offline = true;
      await controller.performAction({
        'action': 'member.delete',
        'id': id,
        'version': 1,
      });
      expect(controller.pendingCount, 1);
      expect(controller.members.any((m) => m.id == id), isFalse);
    },
  );
}
