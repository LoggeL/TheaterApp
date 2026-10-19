import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/casting/casting.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';
import 'package:theater_app/features/galleries/galleries.dart';
import 'package:theater_app/features/scripts/ui/line_learning_screen.dart';
import 'package:theater_app/features/scripts/ui/script_reader_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

final _productions = <JsonMap>[
  {
    'id': 'summer',
    'title': 'Sommerstück 2026',
    'subtitle': 'Eine Komödie in drei Akten',
    'premiereAt': '2026-07-11',
    'revision': 'r1',
    'roles': [
      {'id': 'LENA', 'name': 'Lena'},
      {'id': 'OSKAR', 'name': 'Oskar'},
      {'id': 'BOTE', 'name': 'Bote'},
      {'id': 'MIRA', 'name': 'Mira'},
    ],
    'casting': {'LENA': 6, 'OSKAR': 5, 'BOTE': 5},
    'directorMemberIds': [7],
    'memberIds': [8],
    'memberFunctions': {'8': 'Licht'},
    'ensemble': [5, 6, 7, 8],
  },
  {
    'id': 'old',
    'title': 'Winterstück 2024',
    'archived': true,
    'roles': [
      {'id': 'JULIA', 'name': 'Julia'},
    ],
    'casting': {'JULIA': 6},
    'ensemble': [6],
  },
];

TestServer _server({
  String role = 'member',
  List<JsonMap> galleries = const [],
  List<String>? galleryRequests,
}) {
  final server = TestServer();
  server.data['members'] = [
    {'id': 5, 'name': 'Carina Beispiel', 'active': true},
    {'id': 6, 'name': 'Kim Beispiel', 'active': true},
    {'id': 7, 'name': 'Regina Regie', 'active': true},
    {'id': 8, 'name': 'Toni Lichtblick', 'active': true},
  ];
  server.data['productions'] = _productions;
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    final user = {...server.user, 'role': role, 'personId': 6};
    if (path.endsWith('/auth/login')) {
      return Future.value(
        jsonResponse({
          'token': server.token,
          'expiresAt': '2027-01-01T00:00:00Z',
          'user': user,
        }),
      );
    }
    if (path.endsWith('/snapshot')) {
      return Future.value(jsonResponse({...server.data, 'user': user}));
    }
    if (path.endsWith('/galleries')) {
      galleryRequests?.add(path);
      return Future.value(jsonResponse({'galleries': galleries}));
    }
    if (path.contains('/media/') || path.contains('/galleries/')) {
      return Future.value(http.Response('', 404));
    }
    return null;
  };
  return server;
}

Future<AppController> _pump(
  WidgetTester tester,
  TestServer server, {
  String productionId = 'summer',
  Size size = const Size(360, 2000),
  Brightness brightness = Brightness.light,
  Widget Function(AppController controller)? home,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(brightness),
      home:
          home?.call(controller) ??
          ProductionOverviewScreen(
            controller: controller,
            productionId: productionId,
          ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Finder _tile(String key) => find.byKey(ValueKey(key));

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('members see title, premiere, cast, direction and team', (
    tester,
  ) async {
    await _pump(tester, _server());
    expect(find.text('Admin-Zugang erforderlich.'), findsNothing);
    expect(find.text('Sommerstück 2026'), findsOneWidget);
    expect(find.text('Eine Komödie in drei Akten'), findsOneWidget);
    expect(find.text('Premiere: 11. Juli 2026'), findsOneWidget);

    final lena = _tile('production-overview-role-LENA');
    expect(
      find.descendant(of: lena, matching: find.text('Kim Beispiel (du)')),
      findsOneWidget,
    );
    // One person in two roles names the other one.
    final oskar = _tile('production-overview-role-OSKAR');
    expect(
      find.descendant(of: oskar, matching: find.text('Carina Beispiel')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: oskar, matching: find.text('Spielt auch: Bote')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _tile('production-overview-role-MIRA'),
        matching: find.text('Noch nicht besetzt'),
      ),
      findsOneWidget,
    );
    expect(find.text('Regie'), findsWidgets);
    expect(
      find.descendant(
        of: _tile('production-overview-director-7'),
        matching: find.text('Regina Regie'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _tile('production-overview-team-8'),
        matching: find.text('Licht'),
      ),
      findsOneWidget,
    );
    expect(find.text('Deine Rolle: Lena'), findsOneWidget);
    // Members cannot edit.
    expect(_tile('production-overview-edit'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a person opens their profile, the script opens the reader', (
    tester,
  ) async {
    await _pump(tester, _server());
    await tester.tap(_tile('production-overview-team-8'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberProfileScreen), findsOneWidget);
    expect(find.text('Toni Lichtblick'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(_tile('production-overview-open-script'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ScriptReaderScreen), findsOneWidget);
  });

  testWidgets('a cast member goes straight to learning their lines', (
    tester,
  ) async {
    await _pump(tester, _server());
    final mine = _tile('production-overview-mine');
    expect(
      find.descendant(of: mine, matching: find.text('Text lernen')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: mine, matching: find.text('Drehbuch öffnen')),
      findsOneWidget,
    );
    await tester.tap(_tile('production-overview-learn'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LineLearningScreen), findsOneWidget);
    expect(find.byType(ScriptReaderScreen), findsNothing);
  });

  testWidgets('linked albums are offered, others are left out', (tester) async {
    await _pump(
      tester,
      _server(
        galleries: [
          {
            'id': 'g1',
            'title': 'Premierenfotos',
            'productionId': 'summer',
            'count': 12,
          },
          {
            'id': 'g2',
            'title': 'Anderes Album',
            'productionId': 'old',
            'count': 3,
          },
        ],
      ),
    );
    expect(find.text('Premierenfotos'), findsOneWidget);
    expect(find.text('Galerie · 12 Aufnahmen'), findsOneWidget);
    expect(find.text('Anderes Album'), findsNothing);
    await tester.tap(_tile('production-overview-gallery-g1'));
    await tester.pumpAndSettle();
    expect(find.byType(GalleryScreen), findsOneWidget);
  });

  testWidgets('archived productions open from the profile history', (
    tester,
  ) async {
    await _pump(
      tester,
      _server(),
      home: (controller) =>
          MemberProfileScreen(controller: controller, personId: 6),
    );
    await tester.tap(find.text('Winterstück 2024'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductionOverviewScreen), findsOneWidget);
    expect(find.text('Archiviert'), findsOneWidget);
    expect(
      find.descendant(
        of: _tile('production-overview-role-JULIA'),
        matching: find.text('Kim Beispiel (du)'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('admins can switch to the casting editor', (tester) async {
    await _pump(tester, _server(role: 'admin'));
    await tester.tap(_tile('production-overview-edit'));
    await tester.pumpAndSettle();
    expect(find.byType(CastingScreen), findsOneWidget);
    expect(find.text('Admin-Zugang erforderlich.'), findsNothing);
  });

  testWidgets('fits a narrow phone in dark mode with large text', (
    tester,
  ) async {
    await _pump(
      tester,
      _server(),
      size: const Size(320, 2400),
      brightness: Brightness.dark,
      home: (controller) => MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 2400),
          textScaler: TextScaler.linear(1.6),
        ),
        child: ProductionOverviewScreen(
          controller: controller,
          productionId: 'summer',
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Deine Rolle: Lena'), findsOneWidget);
  });

  testWidgets('an unknown production says so', (tester) async {
    await _pump(tester, _server(), productionId: 'missing');
    expect(find.text('Produktion nicht verfügbar'), findsOneWidget);
  });
}
