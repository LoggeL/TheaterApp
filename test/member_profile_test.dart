import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/ensemble/ensemble.dart';
import 'package:theater_app/features/profile/profile.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

final _productions = <JsonMap>[
  {
    'id': 'p-2026',
    'title': 'Sommerstück 2026 (Creepshow)',
    'roles': [
      {'id': 'DRUSILLA', 'name': 'DRUSILLA'},
    ],
    'casting': {'DRUSILLA': 5},
    'directorMemberIds': [5],
  },
  {
    'id': 'p-winter',
    'title': 'Winterstück 2025 (Kleines Stück)',
    'roles': [
      {'id': 'JULIA', 'name': 'Julia Capulet'},
    ],
    'casting': {'JULIA': 5},
  },
  {'id': 'p-other', 'title': 'Anderes Stück', 'roles': <JsonMap>[]},
];

JsonMap _carina() => {
  'slug': 'Carina',
  'name': 'Carina',
  'personId': 5,
  'since': 2016,
  'url': 'https://kolpingtheater-ramsen.de/team/Carina',
  'current': {
    'title': 'Creepshow',
    'year': 2026,
    'location': 'Open-Air-Bühne',
    'role': 'Drusilla',
    'productionId': 'p-2026',
  },
  'credits': [
    {
      'title': 'Creepshow',
      'year': 2026,
      'location': 'Open-Air-Bühne',
      'role': 'Drusilla',
      'productionId': 'p-2026',
    },
    {
      'title': 'Anno 1146',
      'year': 2025,
      'location': 'Open-Air-Bühne',
      'role': 'Maribel / Mathilde',
    },
    {
      'title': 'Die Geschichte der Black Swan',
      'year': 2016,
      'location': 'Kreativbühne',
      'role': 'Jacky',
    },
  ],
  'jobs': [
    {'job': 'Kostüme', 'description': 'Entwurf und Anfertigung der Kostüme'},
  ],
};

TestServer _server({
  int ownPersonId = 6,
  bool hidden = false,
  List<String>? mediaRequests,
  String? websitePhotoId,
}) {
  final server = TestServer();
  server.data['members'] = [
    {
      'id': 5,
      'name': 'Carina',
      'active': true,
      'about': 'Seit 2016 auf der Bühne.',
      'websiteHidden': hidden,
    },
    {'id': 6, 'name': 'Kim Beispiel', 'active': true},
  ];
  server.data['productions'] = _productions;
  server.data['capabilities'] = {
    'features': ['ensembleProfiles'],
  };
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (path.endsWith('/snapshot')) {
      return Future.value(
        jsonResponse({
          ...server.data,
          'user': {...server.user, 'personId': ownPersonId},
        }),
      );
    }
    if (path.endsWith('/ensemble/website-profiles')) {
      return Future.value(
        jsonResponse({
          'profiles': [
            {..._carina(), 'photoId': ?websitePhotoId},
          ],
        }),
      );
    }
    if (path.contains('/media/')) {
      mediaRequests?.add(path);
      return Future.value(http.Response('', 404));
    }
    return null;
  };
  return server;
}

void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pumpMembers(WidgetTester tester, TestServer server) async {
  _tallView(tester);
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: MembersScreen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('profile credits', () {
    test('merge website roles and app productions without duplicates', () {
      final credits = mergeProfileCredits(
        personId: 5,
        productionRecords: _productions,
        website: WebsiteProfile.fromJson(_carina()),
      );
      expect(
        credits.map((c) => (c.title, c.year, c.duties.join(' · '))).toList(),
        [
          ('Creepshow', 2026, 'Drusilla · Regie'),
          ('Anno 1146', 2025, 'Maribel / Mathilde'),
          ('Winterstück 2025 (Kleines Stück)', 2025, 'Julia Capulet'),
          ('Die Geschichte der Black Swan', 2016, 'Jacky'),
        ],
      );
      expect(credits.first.productionId, 'p-2026');
      expect(credits[1].productionId, isNull);
      expect(credits.first.location, 'Open-Air-Bühne');
    });

    test('without website data the app productions remain', () {
      final credits = mergeProfileCredits(
        personId: 5,
        productionRecords: _productions,
      );
      expect(credits.map((c) => c.title), [
        'Sommerstück 2026 (Creepshow)',
        'Winterstück 2025 (Kleines Stück)',
      ]);
      expect(
        mergeProfileCredits(personId: 99, productionRecords: _productions),
        isEmpty,
      );
    });

    test('role labels match across spelling and alternatives', () {
      expect(sameRoleLabel('FIONA', 'Fiona'), isTrue);
      expect(sameRoleLabel('GRAF', 'Graf Thaddäus von Falkenstein'), isTrue);
      expect(sameRoleLabel('Regie', 'Butler Wilson / Regie'), isTrue);
      expect(sameRoleLabel('JUNGE EMMA', 'Emma (jung)'), isTrue);
      expect(sameRoleLabel('MIA', 'Mias Mutter'), isFalse);
      expect(sameRoleLabel('Regie', 'Licht'), isFalse);
    });

    test('hidden or unlinked profiles belong to nobody', () {
      final profiles = [
        WebsiteProfile.fromJson(_carina()),
        WebsiteProfile.fromJson({
          'slug': 'Kim',
          'name': 'Kim',
          'personId': 6,
          'hidden': true,
        }),
        WebsiteProfile.fromJson({'slug': 'Zoe', 'name': 'Zoe'}),
      ];
      expect(websiteProfileOf(profiles, 5)?.slug, 'Carina');
      expect(websiteProfileOf(profiles, 6), isNull);
    });
  });

  testWidgets('tapping a person opens a short profile with roles and about', (
    tester,
  ) async {
    await _pumpMembers(tester, _server());
    await tester.tap(find.text('Carina'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberProfileScreen), findsOneWidget);
    expect(find.text('Über mich'), findsOneWidget);
    expect(find.text('Seit 2016 auf der Bühne.'), findsOneWidget);
    expect(find.text('DIESE SAISON · 2026'), findsOneWidget);
    expect(find.text('Dabei seit 2016'), findsOneWidget);
    expect(find.text('4 Produktionen'), findsOneWidget);
    expect(find.textContaining('Drusilla · Regie'), findsOneWidget);
    expect(find.textContaining('Maribel / Mathilde'), findsOneWidget);
    expect(find.text('Hinter den Kulissen'), findsOneWidget);
    expect(find.text('Kostüme'), findsOneWidget);
    expect(find.text('Profil auf der Website'), findsOneWidget);
    // No private data from the app on the profile.
    expect(find.textContaining('@'), findsNothing);
    expect(find.byTooltip('Profil bearbeiten'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('website photos are never shown, also when a server sends one', (
    tester,
  ) async {
    final media = <String>[];
    await _pumpMembers(
      tester,
      _server(mediaRequests: media, websitePhotoId: 'web-carina'),
    );
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.text('Carina'));
    await tester.pumpAndSettle();
    expect(find.byType(MemberProfileScreen), findsOneWidget);
    // Without an own profile picture the initials stay.
    expect(find.byType(Image), findsNothing);
    expect(media, isEmpty);
    expect(find.textContaining('Foto'), findsNothing);
  });

  testWidgets('the own profile invites to write a text', (tester) async {
    await _pumpMembers(tester, _server());
    await tester.tap(find.text('Kim Beispiel'));
    await tester.pumpAndSettle();
    expect(find.text('Über mich'), findsOneWidget);
    expect(find.text('Text schreiben'), findsOneWidget);
    expect(find.text('Noch keine Rollen eingetragen.'), findsOneWidget);
    expect(find.byTooltip('Profil bearbeiten'), findsOneWidget);
    expect(find.text('Profil auf der Website'), findsNothing);
  });

  testWidgets('hidden website data stays off the profile', (tester) async {
    await _pumpMembers(tester, _server(hidden: true));
    await tester.tap(find.text('Carina'));
    await tester.pumpAndSettle();
    expect(find.text('Seit 2016 auf der Bühne.'), findsOneWidget);
    expect(find.text('Hinter den Kulissen'), findsNothing);
    expect(find.textContaining('Maribel'), findsNothing);
    expect(find.text('Profil auf der Website'), findsNothing);
    // The app's own casting still shows.
    expect(find.text('Sommerstück 2026 (Creepshow)'), findsOneWidget);
  });

  testWidgets('people edit their about text and can hide website data', (
    tester,
  ) async {
    final server = _server(ownPersonId: 5);
    final saves = <JsonMap>[];
    final base = server.override!;
    server.override = (http.Request request) {
      if (request.url.path
          .replaceFirst(RegExp(r'/$'), '')
          .endsWith('/profile')) {
        saves.add(jsonMap(jsonDecode(request.body)));
        return Future.value(jsonResponse({'ok': true}));
      }
      return base(request);
    };
    _tallView(tester);
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ProfileScreen(controller: controller),
                ),
              ),
              child: const Text('Öffnen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Seit 2016 auf der Bühne.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('profile-about')),
      '  Ich mag Kostüme.  ',
    );
    await tester.tap(find.byKey(const ValueKey('profile-website-visible')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.pumpAndSettle();
    expect(saves.single['about'], 'Ich mag Kostüme.');
    expect(saves.single['websiteHidden'], isTrue);
    expect(saves.single.containsKey('avatarId'), isTrue);
    expect(find.text('Profil gespeichert.'), findsOneWidget);
  });

  testWidgets('older servers get no about fields', (tester) async {
    final server = _server(ownPersonId: 5);
    server.data['capabilities'] = {'features': <String>[]};
    _tallView(tester);
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(home: ProfileScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-about')), findsNothing);
    expect(find.byKey(const ValueKey('profile-website-visible')), findsNothing);
  });
}
