import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/ui/notes.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  testWidgets('admins publish notes for selected roles', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    server.data['personRoles'] = [
      {'id': 'role-light', 'name': 'Licht', 'version': 1},
      {'id': 'role-choir', 'name': 'Chor', 'version': 1},
    ];
    server.data['notes'] = [
      {
        'id': 'draft',
        'title': 'Packliste',
        'body': 'Kabel und Gaffa',
        'roleIds': ['role-light'],
        'published': false,
        'authorName': 'Regie',
        'updatedAt': '2026-09-12T10:00:00Z',
        'version': 3,
      },
    ];
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: NotesScreen(controller: controller),
      ),
    );
    expect(find.text('Packliste'), findsOneWidget);
    expect(find.text('Entwurf'), findsOneWidget);
    expect(find.text('Licht'), findsOneWidget);

    await tester.tap(find.text('Packliste'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Bearbeiten'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Chor'));
    await tester.tap(find.text('Freigeben'));
    await tester.pump();
    expect(find.text('Sichtbar für Licht · Chor.'), findsOneWidget);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final body = server.actionBodies.last;
    expect(body['action'], 'note.save');
    expect(body['id'], 'draft');
    expect(body['version'], 3);
    expect(body['published'], isTrue);
    expect(body['roleIds'], unorderedEquals(['role-light', 'role-choir']));
  });

  test('offline absences skip events addressed to other roles', () async {
    final server = TestServer();
    server.data['user'] = server.user;
    server.data['events'] = [
      for (final (id, roles) in [
        ('light', ['role-light']),
        ('all', <String>[]),
      ])
        {
          'id': id,
          'title': id,
          'startsAt': '2026-09-13T17:00:00Z',
          'endsAt': '2026-09-13T19:00:00Z',
          'eventDate': '2026-09-13',
          'roleIds': roles,
        },
    ];
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    server.offline = true;
    await controller.addAbsence(
      DateTime(2026, 9, 13),
      DateTime(2026, 9, 13),
      'Urlaub',
    );
    final responses = {for (final e in controller.events) e.id: e.response};
    expect(responses, {'light': 'open', 'all': 'no'});
  });
}
