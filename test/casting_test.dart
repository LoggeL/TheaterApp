import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/casting.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/ui/casting.dart';
import 'package:theater_app/ui/theme.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

const mainId = DemoData.mainProductionId,
    secondId = DemoData.secondProductionId;

const people = [
  TheaterMember(id: 1, name: 'Alex Bühnenfreund', initials: 'AB'),
  TheaterMember(id: 2, name: 'Robin Spielmann', initials: 'RS'),
  TheaterMember(id: 3, name: 'Toni Lichtblick', initials: 'TL'),
  TheaterMember(id: 4, name: 'Kim Kulisse', initials: 'KK'),
  TheaterMember(id: 5, name: 'Sam Vorhang', initials: 'SV'),
];

ProductionCast production(
  List<JsonMap> roles, {
  String id = 'p',
  String title = 'Stück',
  JsonMap casting = const {},
}) => ProductionCast.fromRecord({
  'id': id,
  'title': title,
  'roles': roles,
  'casting': casting,
});

/// A server stand-in that applies casting changes like the real one.
TestServer castingServer() {
  final server = TestServer();
  server.data['productions'] = jsonList(server.data['productions']).map((item) {
    final p = jsonMap(item);
    if (p['id'] == mainId) {
      return {
        ...p,
        'roles': [
          {'id': 'LENA', 'name': 'Lena', 'actor': 'Alex Bühnenfreund'},
          {'id': 'OSKAR', 'name': 'Oskar', 'actor': 'Robin S.'},
          {'id': 'MIRA', 'name': 'Mira', 'actor': ''},
        ],
        'memberIds': [3],
        'memberFunctions': {'3': 'Licht'},
        'ensemble': [3],
      };
    }
    return {
      ...p,
      'roles': [
        ...jsonList(p['roles']),
        {'id': 'MIRA', 'name': 'Mira', 'actor': ''},
      ],
      'casting': {'MIRA': 5},
      'ensemble': [5],
    };
  }).toList();
  server.override = (request) {
    if (!request.url.path
        .replaceFirst(RegExp(r'/$'), '')
        .endsWith('/actions')) {
      return null;
    }
    final body = jsonMap(jsonDecode(request.body));
    server.actionBodies.add(body);
    if (body['action'] == 'production.cast') {
      server.data['productions'] = jsonList(server.data['productions'])
          .map(jsonMap)
          .map(
            (p) => p['id'] == body['id']
                ? applyCastChanges(p, jsonList(body['changes']).map(jsonMap))
                : p,
          )
          .toList();
    }
    return Future.value(jsonResponse({'ok': true}));
  };
  return server;
}

Future<void> pumpCasting(
  WidgetTester tester,
  TestServer server, {
  Size size = const Size(412, 900),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  await signIn(controller);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: CastingScreen(controller: controller, productionId: mainId),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

List<JsonMap> castChanges(TestServer server) => server.actionBodies
    .where((b) => b['action'] == 'production.cast')
    .expand((b) => jsonList(b['changes']).map(jsonMap))
    .toList();

void main() {
  group('suggestions', () {
    test('explain script actors, names and earlier casting in order', () {
      final cast = production(
        [
          {'id': 'A', 'name': 'Lena', 'actor': 'Alex Bühnenfreund'},
          {'id': 'B', 'name': 'Kim Kulisse', 'actor': ''},
          {'id': 'C', 'name': 'Mira', 'actor': ''},
          {'id': 'D', 'name': 'Oskar', 'actor': 'robin s.'},
          {'id': 'E', 'name': 'Toni', 'actor': ''},
          {'id': 'F', 'name': 'Wirt', 'actor': 'Sam Vorhnag'},
          {'id': 'G', 'name': 'Gast', 'actor': 'Unbekannt'},
        ],
        casting: {'G': 4},
      );
      final earlier = production(
        [
          {'id': 'X', 'name': 'MIRA', 'actor': ''},
        ],
        id: 'old',
        title: 'Altes Stück',
        casting: {'X': 5},
      );
      final result = castingSuggestions(cast, people, [earlier]);
      expect(
        [for (final s in result) '${s.role.id}:${s.personId}:${s.reason}'],
        [
          'A:1:im Drehbuch als Darsteller:in genannt',
          'B:4:gleicher Name wie die Rolle',
          'C:5:spielte die Rolle in „Altes Stück“',
          'D:2:ähnlicher Name im Drehbuch: „robin s.“',
          'E:3:Rollenname wie der Vorname',
          'F:5:ähnlicher Name im Drehbuch: „Sam Vorhnag“',
        ],
      );
    });

    test('ambiguous or inactive matches propose nobody', () {
      final cast = production([
        {'id': 'A', 'name': 'Alex', 'actor': ''},
        {'id': 'B', 'name': 'Kim', 'actor': 'Kim Kulisse'},
      ]);
      final members = [
        ...people.where((m) => m.id != 4),
        const TheaterMember(id: 6, name: 'Alex Zweitname'),
        const TheaterMember(id: 4, name: 'Kim Kulisse', active: false),
      ];
      expect(castingSuggestions(cast, members, const []), isEmpty);
    });

    test('roles are sorted by spoken lines, else alphabetically', () {
      const roles = [
        ScriptRole(id: 'B', name: 'Berta'),
        ScriptRole(id: 'A', name: 'Anton'),
        ScriptRole(id: 'C', name: 'Clara'),
      ];
      ScriptCue line(String role) => ScriptCue(
        id: role,
        sceneId: '1',
        ordinal: 0,
        kind: 'dialogue',
        text: '…',
        role: role,
      );
      final script = ScriptDocument(
        productionId: 'p',
        revision: 'r',
        scenes: const [],
        roles: roles,
        cues: [line('C'), line('C'), line('b')],
      );
      expect(
        rolesByImportance(roles, roleLineCounts(script)).map((r) => r.id),
        ['C', 'B', 'A'],
      );
      expect(rolesByImportance(roles, const {}).map((r) => r.id), [
        'A',
        'B',
        'C',
      ]);
    });

    test('casting changes are projected like the server applies them', () {
      final record = applyCastChanges(
        {
          'id': 'p',
          'roles': [
            {'id': 'B', 'name': 'Berta'},
          ],
          'casting': {'A': 1},
          'memberIds': [3],
          'memberFunctions': {'3': 'Licht'},
          'version': 4,
        },
        [
          {'kind': 'role', 'roleId': 'B', 'personId': 2},
          {'kind': 'role', 'roleId': 'A', 'personId': null},
          {'kind': 'director', 'personId': 4, 'on': true},
          {'kind': 'member', 'personId': 3, 'on': false},
          {'kind': 'member', 'personId': 5, 'function': ' Maske '},
        ],
      );
      expect(record['casting'], {'B': 2});
      expect(record['memberIds'], [5]);
      expect(record['memberFunctions'], {'5': 'Maske'});
      expect((record['ensemble'] as List)..sort(), [2, 4, 5]);
      expect(record['version'], 5);
      final cast = ProductionCast.fromRecord(record);
      expect(cast.dutiesOf(5), ['Maske']);
      expect(cast.dutiesOf(4), ['Regie']);
      expect(creditsOf([cast], 2).single.duties, ['Berta']);
    });
  });

  testWidgets('open roles are highlighted and suggestions can be accepted', (
    tester,
  ) async {
    final server = castingServer();
    await pumpCasting(tester, server);

    expect(find.text('0 von 3 Rollen besetzt'), findsOneWidget);
    expect(find.text('Noch nicht besetzt'), findsNWidgets(3));
    expect(find.text('3 Rollen offen'), findsOneWidget);
    // The demo script gives Lena the most lines.
    expect(
      find.text(
        'Sortiert nach Textmenge. Tippe auf eine Rolle, um sie zu besetzen.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('spielte die Rolle in „Fünf Minuten im Foyer“'),
      findsOneWidget,
    );
    expect(find.text('ähnlicher Name im Drehbuch: „Robin S.“'), findsOneWidget);

    await tapVisible(tester, find.byKey(const ValueKey('casting-accept-LENA')));
    expect(castChanges(server).single, {
      'kind': 'role',
      'roleId': 'LENA',
      'personId': 1,
      'previous': null,
    });
    expect(find.text('1 von 3 Rollen besetzt'), findsOneWidget);
    expect(find.text('Noch nicht besetzt'), findsNWidgets(2));

    await tapVisible(tester, find.byKey(const ValueKey('casting-accept-all')));
    expect(find.text('3 von 3 Rollen besetzt'), findsOneWidget);
    expect(find.text('Noch nicht besetzt'), findsNothing);
    expect(find.byKey(const ValueKey('casting-suggestions')), findsNothing);
    expect(
      castChanges(server).skip(1).map((c) => '${c['roleId']}:${c['personId']}'),
      unorderedEquals(['OSKAR:2', 'MIRA:5']),
    );

    // The overview says who does what.
    final toni = find.byKey(const ValueKey('casting-ensemble-3'));
    await tester.ensureVisible(toni);
    expect(
      find.descendant(of: toni, matching: find.text('Licht')),
      findsOneWidget,
    );
    expect(find.text('Ensemble (4)'), findsOneWidget);
  });

  testWidgets('a role is recast through the searchable person sheet', (
    tester,
  ) async {
    final server = castingServer();
    await pumpCasting(tester, server);

    await tapVisible(tester, find.byKey(const ValueKey('casting-role-MIRA')));
    // The suggestion is listed first and explained.
    expect(
      find.textContaining(
        'Vorschlag: spielte die Rolle in „Fünf Minuten im Foyer“',
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('casting-person-search')),
      'kul',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('casting-person-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('casting-person-4')));
    await tester.pumpAndSettle();
    expect(castChanges(server).single, {
      'kind': 'role',
      'roleId': 'MIRA',
      'personId': 4,
      'previous': null,
    });
    final mira = find.byKey(const ValueKey('casting-role-MIRA'));
    expect(
      find.descendant(of: mira, matching: find.text('Kim Kulisse')),
      findsOneWidget,
    );

    // Removing the casting opens the role again.
    await tapVisible(tester, mira);
    await tester.tap(find.text('Besetzung entfernen'));
    await tester.pumpAndSettle();
    expect(castChanges(server).last, {
      'kind': 'role',
      'roleId': 'MIRA',
      'personId': null,
      'previous': 4,
    });
    expect(
      find.descendant(of: mira, matching: find.text('Noch nicht besetzt')),
      findsOneWidget,
    );

    // Team functions are edited in place.
    await tapVisible(tester, find.byKey(const ValueKey('casting-team-3')));
    await tester.tap(find.text('Souffleuse'));
    await tester.pumpAndSettle();
    expect(castChanges(server).last, {
      'kind': 'member',
      'personId': 3,
      'function': 'Souffleuse',
    });
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('casting-team-3')),
        matching: find.text('Souffleuse'),
      ),
      findsOneWidget,
    );
  });

  for (final (size, scale) in [
    (const Size(320, 640), 2.0),
    (const Size(412, 800), 2.0),
  ]) {
    testWidgets(
      'fits ${size.width.toInt()} px at text scale ${scale.toStringAsFixed(0)}',
      (tester) async {
        final server = castingServer();
        await pumpCasting(tester, server, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        for (final key in [
          'casting-accept-all',
          'casting-role-MIRA',
          'casting-add-director',
          'casting-team-3',
          'casting-ensemble-3',
        ]) {
          await tester.ensureVisible(find.byKey(ValueKey(key)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: key);
        }
        await tapVisible(
          tester,
          find.byKey(const ValueKey('casting-role-MIRA')),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('wide screens show roles and team side by side', (tester) async {
    final server = castingServer();
    await pumpCasting(tester, server, size: const Size(1280, 900));
    final roles = tester.getTopLeft(
      find.byKey(const ValueKey('casting-role-LENA')),
    );
    final director = tester.getTopLeft(
      find.byKey(const ValueKey('casting-add-director')),
    );
    expect(director.dx, greaterThan(roles.dx + 300));
    expect(director.dy, lessThan(500));
    expect(tester.takeException(), isNull);
  });
}
