import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/features/admin/admin.dart';
import 'package:theater_app/features/casting/casting.dart';
import 'package:theater_app/features/productions/domain/ensemble_membership.dart';
import 'package:theater_app/features/productions/productions.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;

const mainId = DemoData.mainProductionId,
    secondId = DemoData.secondProductionId;

JsonMap _event(String id, int days, {List<String> productionIds = const []}) {
  final start = fixedNow.add(Duration(days: days));
  return {
    'id': id,
    'title': id,
    'type': 'rehearsal',
    'startsAt': start.toUtc().toIso8601String(),
    'endsAt': start.add(const Duration(hours: 2)).toUtc().toIso8601String(),
    'productionId': mainId,
    'productionIds': productionIds,
  };
}

/// Alex plays Lena, Kim directs, Toni does the light by hand; the server
/// applies casting changes and reports newly visible events for [notify].
TestServer _server({int newEvents = 2, bool pushed = true, TestServer? base}) {
  final server = base ?? TestServer();
  server.data['events'] = [
    _event('wed1', 3, productionIds: [mainId]),
    _event('wed2', 10, productionIds: [mainId]),
    _event('past', -3, productionIds: [mainId]),
    _event('all', 4),
  ];
  server.data['productions'] = jsonList(server.data['productions']).map((item) {
    final p = jsonMap(item);
    if (p['id'] != mainId) return p;
    return {
      ...p,
      'roles': [
        {'id': 'LENA', 'name': 'Lena', 'actor': ''},
        {'id': 'OSKAR', 'name': 'Oskar', 'actor': ''},
      ],
      'casting': {'LENA': 1},
      'directorMemberIds': [4],
      'memberIds': [3],
      'memberFunctions': {'3': 'Licht'},
      'ensemble': [1, 4, 3],
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
    final changes = jsonList(body['changes']).map(jsonMap).toList();
    final notify = [
      for (final c in changes)
        if (c['notify'] == true) intValue(c['personId']),
    ];
    server.data['productions'] = jsonList(server.data['productions'])
        .map(jsonMap)
        .map((p) => p['id'] == body['id'] ? applyCastChanges(p, changes) : p)
        .toList();
    return Future.value(
      jsonResponse({
        'ok': true,
        'newEvents': {
          if (newEvents > 0)
            for (final id in notify) '$id': newEvents,
        },
        'notified': [if (pushed && newEvents > 0) ...notify],
      }),
    );
  };
  return server;
}

Future<void> _pump(
  WidgetTester tester,
  Widget Function(AppController) page,
  TestServer server,
) async {
  tester.view.physicalSize = const Size(412, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: page(controller),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpPage(WidgetTester tester, TestServer server) => _pump(
  tester,
  (c) => EnsemblesAdminScreen(controller: c, productionId: mainId),
  server,
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

List<JsonMap> _changes(TestServer server) => server.actionBodies
    .where((b) => b['action'] == 'production.cast')
    .expand((b) => jsonList(b['changes']).map(jsonMap))
    .toList();

String _subtitle(WidgetTester tester, int personId) {
  final tile = tester.widget<ListTile>(
    find.byKey(ValueKey('ensemble-member-$personId')),
  );
  return (tile.subtitle! as Text).data!;
}

class _MemberServer extends TestServer {
  @override
  JsonMap get user => {...super.user, 'role': 'member'};
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('memberships name every reason from the one production record', () {
    final cast = ProductionCast.fromRecord({
      'id': 'p',
      'roles': [
        {'id': 'JULIA', 'name': 'JULIA'},
        {'id': 'AMME', 'name': 'AMME'},
      ],
      'casting': {'JULIA': 1, 'AMME': 1},
      'directorMemberIds': [2, 1],
      'memberIds': [3, 1],
      'memberFunctions': {'3': 'Licht'},
    });
    final byId = {for (final m in ensembleMemberships(cast)) m.personId: m};
    expect(byId.keys.toSet(), {1, 2, 3});
    expect(byId[1]!.reasons, [
      'Rolle JULIA',
      'Rolle AMME',
      'Regie',
      'Weitere Mitwirkende',
    ]);
    expect(byId[1]!.viaCasting, isTrue);
    expect(byId[2]!.castingReasons, ['Regie']);
    expect(byId[3]!.viaCasting, isFalse);
    expect(byId[3]!.reasons, ['Weitere Mitwirkende (Licht)']);
  });

  testWidgets('the page shows who belongs to the ensemble and why', (
    tester,
  ) async {
    await _pumpPage(tester, _server());
    expect(find.text('Ensembles & Verteiler'), findsOneWidget);
    expect(find.text('3 Personen'), findsOneWidget);
    // Only upcoming events limited to this ensemble count.
    expect(find.text('2 kommende Termine nur fürs Ensemble'), findsOneWidget);
    expect(find.text('Weitere Mitwirkende (1)'), findsOneWidget);
    expect(find.text('Über Rollen & Regie (2)'), findsOneWidget);
    expect(_subtitle(tester, 3), 'Licht');
    expect(_subtitle(tester, 1), 'Rolle Lena');
    expect(_subtitle(tester, 4), 'Regie');
    expect(find.byKey(const ValueKey('ensemble-remove-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('ensemble-remove-1')), findsNothing);
    expect(find.byKey(const ValueKey('ensemble-locked-1')), findsOneWidget);
  });

  testWidgets('adding a person asks the server to inform them once', (
    tester,
  ) async {
    final server = _server();
    await _pumpPage(tester, server);
    await _tap(tester, find.byKey(const ValueKey('ensemble-add')));
    // People already in the ensemble are not offered.
    for (final id in [1, 3, 4]) {
      expect(find.byKey(ValueKey('ensemble-pick-$id')), findsNothing);
    }
    await tester.enterText(
      find.byKey(const ValueKey('ensemble-person-search')),
      'robin',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ensemble-pick-5')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('ensemble-pick-2')));
    expect(_changes(server), [
      {'kind': 'member', 'personId': 2, 'on': true, 'notify': true},
    ]);
    expect(
      find.text(
        'Robin Spielmann gehört jetzt zum Ensemble. 2 kommende Termine '
        'gelten jetzt auch für Robin Spielmann – eine kurze Push-Info ist '
        'unterwegs.',
      ),
      findsOneWidget,
    );
    expect(find.text('Weitere Mitwirkende (2)'), findsOneWidget);
    expect(find.text('4 Personen'), findsOneWidget);

    // Undo takes the person out again, without any notice.
    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(_changes(server).last, {
      'kind': 'member',
      'personId': 2,
      'on': false,
    });
    expect(find.text('Weitere Mitwirkende (1)'), findsOneWidget);
  });

  testWidgets('without newly visible events or push nothing is promised', (
    tester,
  ) async {
    final server = _server(newEvents: 0);
    await _pumpPage(tester, server);
    await _tap(tester, find.byKey(const ValueKey('ensemble-add')));
    await _tap(tester, find.byKey(const ValueKey('ensemble-pick-5')));
    expect(find.text('Sam Vorhang gehört jetzt zum Ensemble.'), findsOneWidget);
    expect(find.textContaining('Push'), findsNothing);
  });

  testWidgets('removing a person added by hand can be undone with the '
      'function', (tester) async {
    final server = _server();
    await _pumpPage(tester, server);
    await _tap(tester, find.byKey(const ValueKey('ensemble-remove-3')));
    expect(_changes(server), [
      {'kind': 'member', 'personId': 3, 'on': false},
    ]);
    expect(
      find.text(
        'Toni Lichtblick gehört nicht mehr zum Ensemble und sieht Termine nur '
        'fürs Ensemble nicht mehr.',
      ),
      findsOneWidget,
    );
    expect(find.text('Weitere Mitwirkende (0)'), findsOneWidget);
    await tester.tap(find.text('Rückgängig'));
    await tester.pumpAndSettle();
    expect(_changes(server).last, {
      'kind': 'member',
      'personId': 3,
      'on': true,
      'function': 'Licht',
    });
    expect(_subtitle(tester, 3), 'Licht');
  });

  testWidgets('a cast person added by hand as well stays through the role', (
    tester,
  ) async {
    final server = _server();
    server.data['productions'] = [
      for (final p in jsonList(server.data['productions']).map(jsonMap))
        p['id'] == mainId
            ? {
                ...p,
                'memberIds': [3, 1],
              }
            : p,
    ];
    await _pumpPage(tester, server);
    expect(_subtitle(tester, 1), 'Weitere Mitwirkende · Rolle Lena');
    await _tap(tester, find.byKey(const ValueKey('ensemble-remove-1')));
    expect(
      find.text(
        'Alex Bühnenfreund ist nicht mehr unter „Weitere Mitwirkende“, bleibt '
        'aber über Rolle Lena im Ensemble.',
      ),
      findsOneWidget,
    );
    expect(find.text('Über Rollen & Regie (2)'), findsOneWidget);
    expect(find.text('3 Personen'), findsOneWidget);
  });

  testWidgets('cast people explain that casting decides and link to it', (
    tester,
  ) async {
    final server = _server();
    await _pumpPage(tester, server);
    await _tap(tester, find.byKey(const ValueKey('ensemble-locked-1')));
    expect(
      find.text('Alex Bühnenfreund gehört über die Besetzung dazu'),
      findsOneWidget,
    );
    expect(find.textContaining('Grund: Rolle Lena.'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('ensemble-open-casting')));
    expect(find.byType(CastingScreen), findsOneWidget);
    expect(server.actionBodies, isEmpty);
  });

  testWidgets('the productions are one tap apart', (tester) async {
    await _pumpPage(tester, _server());
    await _tap(
      tester,
      find.byKey(const ValueKey('ensemble-production-$secondId')),
    );
    expect(find.text('Fünf Minuten im Foyer'), findsWidgets);
    expect(find.text('Noch niemand von Hand hinzugefügt.'), findsOneWidget);
    expect(find.text('0 Personen'), findsOneWidget);
  });

  testWidgets('long titles and large text fit on small phones', (tester) async {
    final server = _server();
    server.data['productions'] = [
      for (final p in jsonList(server.data['productions']).map(jsonMap))
        {...p, 'title': 'Winterstück 2026 (Romeo und Julia) – ${p['id']}'},
    ];
    tester.view.physicalSize = const Size(320, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: EnsemblesAdminScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Weitere Mitwirkende (1)'), findsOneWidget);
  });

  testWidgets('members without admin rights cannot open the page', (
    tester,
  ) async {
    final server = _server(base: _MemberServer());
    await _pumpPage(tester, server);
    expect(find.text('Admin-Zugang erforderlich.'), findsOneWidget);
    expect(find.byKey(const ValueKey('ensemble-add')), findsNothing);
  });

  testWidgets('the admin hub and the production editor link to the page', (
    tester,
  ) async {
    final server = _server();
    await _pump(tester, (c) => ManagementScreen(controller: c), server);
    await _tap(tester, find.text('Ensembles & Verteiler'));
    expect(find.byType(EnsemblesAdminScreen), findsOneWidget);
    // A fresh app, so the hub's page does not stay on top.
    await tester.pumpWidget(const SizedBox());

    await _pump(
      tester,
      (c) => ProductionEditorScreen(
        controller: c,
        production: c.productionRecords.firstWhere((p) => p['id'] == mainId),
      ),
      server,
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('production-editor-ensemble')),
    );
    expect(find.byType(EnsemblesAdminScreen), findsOneWidget);
    expect(find.text('Wenn das Licht angeht'), findsWidgets);
  });
}
