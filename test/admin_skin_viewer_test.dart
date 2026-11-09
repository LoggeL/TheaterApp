import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/core/telemetry/perf_stats.dart';
import 'package:theater_app/features/games/data/admin_skins_api.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/admin_skin_viewer.dart';
import 'package:theater_app/features/games/ui/wardrobe_cards.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/settings/settings.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// The admins' Skin-Viewer (`runnerAdminCatalog`): an entry in the settings
// only admins see, a list of every skin grouped by play with filters and
// search, and a page with the figure's moves.

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerRoleFigures',
  'runnerAdminCatalog',
];

JsonMap _item(
  String id,
  String name, {
  String kind = 'character',
  String rarity = 'blau',
  String? role,
  String? play,
  int? year,
  Map<String, Object?> admin = const {
    'disabled': false,
    'live': true,
    'release': null,
    'secret': null,
  },
  Map<String, Object?> extra = const {},
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'rarity': rarity,
  'rarities': [rarity],
  'role': ?role,
  'play': ?play,
  'year': ?year,
  'admin': admin,
  ...extra,
};

final _catalog = <String, Object?>{
  'rarities': [
    {'id': 'blau', 'name': 'Blau', 'color': '#5E98D9', 'weight': 1},
    {'id': 'gold', 'name': 'Gold', 'color': '#E4AE39', 'weight': .1},
    {
      'id': 'legacy',
      'name': 'Legacy',
      'color': '#9C7A54',
      'weight': .2,
      'style': 'antique',
    },
  ],
  'departments': [
    {'id': 'licht', 'name': 'Lichttechnik', 'icon': 'light'},
  ],
  'uniqueRarity': {
    'id': 'unique',
    'name': 'Unique',
    'color': '#B388FF',
    'style': 'holo',
  },
  'items': [
    _item(
      'character.default',
      'Engel Logge',
      extra: {'default': true, 'placeholder': true},
    ),
    _item(
      'character.elena--creep',
      'Elena',
      role: 'Lucy',
      play: 'Creepshow',
      year: 2026,
      extra: {
        'personId': 6,
        'portrait': '/admin/runner/skins/elena-portrait.webp?v=1',
        'thumb': '/admin/runner/skins/elena-thumb.webp?v=1',
      },
    ),
    _item(
      'character.jonas--hell',
      'Jonas',
      rarity: 'gold',
      role: 'Luzifer',
      play: 'Hölle',
      year: 2027,
      admin: {
        'disabled': false,
        'live': false,
        'release': {
          'id': 'hell-2026',
          'name': 'Eine höllische Herausforderung',
          'startsAt': '2026-11-08T17:00:00.000Z',
          'active': false,
          'part': 'items',
        },
        'secret': null,
      },
    ),
    _item(
      'character.nora--anno',
      'Nora',
      rarity: 'legacy',
      role: 'Magd',
      play: 'Anno 1146',
      year: 2025,
      admin: {'disabled': true, 'live': false, 'release': null},
    ),
    _item(
      'character.unique-beatrice',
      'Beatrice',
      rarity: 'unique',
      role: 'Beatrice',
      play: 'Creepshow',
      year: 2026,
      admin: {
        'disabled': false,
        'live': true,
        'release': null,
        'secret': 'unique',
      },
      extra: {
        'unique': true,
        'unlock': {'play': 'Creepshow'},
      },
    ),
    _item(
      'character.florian',
      'Florian',
      role: 'Lichttechnik',
      extra: {
        'departments': ['licht'],
        'personId': 35,
      },
    ),
    // Disabled, with its picture, in a coming release.
    _item(
      'character.lea--freiheit',
      'Lea',
      role: 'Freya',
      play: 'Traum von Freiheit',
      year: 2026,
      admin: {
        'disabled': true,
        'live': false,
        'release': {
          'id': 'traum-2026',
          'name': 'Traum von Freiheit',
          'startsAt': '2026-11-22T17:00:00.000Z',
          'active': false,
          'ready': false,
          'part': 'items',
        },
        'waiting': false,
        'secret': null,
      },
      extra: {
        'portrait': '/admin/runner/skins/lea-portrait.webp?v=1',
        'thumb': '/admin/runner/skins/lea-thumb.webp?v=1',
      },
    ),
    // Its date has passed, but its pack still lacks pictures.
    _item(
      'character.emil--spaet',
      'Emil',
      role: 'Wache',
      play: 'Spät',
      year: 2026,
      admin: {
        'disabled': false,
        'live': false,
        'release': {
          'id': 'spaet',
          'name': 'Spätlese',
          'startsAt': '2026-11-01T17:00:00.000Z',
          'active': true,
          'ready': false,
          'part': 'items',
        },
        'waiting': true,
        'secret': null,
      },
    ),
    _item('backdrop.forest', 'Wald', kind: 'backdrop'),
    _item('obstacles.tech', 'Technik-Kram', kind: 'obstacles'),
  ],
  'releases': [
    {
      'id': 'hell-2026',
      'name': 'Eine höllische Herausforderung',
      'startsAt': '2026-11-08T17:00:00.000Z',
      'active': false,
      'ready': true,
      'missing': <Object?>[],
    },
    {
      'id': 'traum-2026',
      'name': 'Traum von Freiheit',
      'startsAt': '2026-11-22T17:00:00.000Z',
      'active': false,
      'ready': false,
      'missing': [
        {'id': 'character.lea--freiheit', 'name': 'Lea', 'reason': 'disabled'},
      ],
    },
    {
      'id': 'spaet',
      'name': 'Spätlese',
      'startsAt': '2026-11-01T17:00:00.000Z',
      'active': true,
      'ready': false,
      'missing': [
        {'id': 'character.gerda--spaet', 'name': 'Gerda', 'reason': 'disabled'},
        {
          'id': 'character.fritzi--spaet',
          'name': 'Fritzi',
          'reason': 'picture',
        },
      ],
    },
  ],
};

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

/// A signed-in controller; [role] `member` for anybody but an admin.
Future<(AppController, List<String>)> _signedIn({
  String role = 'admin',
  List<String> features = _features,
  List<String>? pictures,
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  final requests = <String>[];
  JsonMap user() => {...server.user, 'role': role};
  server.override = (request) {
    final path = _path(request);
    if (path.endsWith('/admin/runner/catalog')) {
      requests.add(path);
      return Future.value(jsonResponse(_catalog));
    }
    if (path.endsWith('/auth/login')) {
      return Future.value(
        jsonResponse({
          'token': server.token,
          'expiresAt': '2027-01-01T00:00:00Z',
          'user': user(),
        }),
      );
    }
    if (path.endsWith('/snapshot')) {
      return Future.value(jsonResponse({...server.data, 'user': user()}));
    }
    if (path.contains('/skins/')) {
      pictures?.add(path);
      return Future.value(jsonResponse({'error': 'not found'}, 404));
    }
    return null;
  };
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return (controller, requests);
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(900, 4000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(WardrobePictures.clear);

  test('every skin keeps its state: active, disabled, scheduled, gated', () {
    final data = AdminSkinCatalog.fromJson(_catalog);
    final byId = {for (final s in data.skins) s.item.id: s};
    expect(data.skins, hasLength(10));
    expect(byId['character.elena--creep']!.status, AdminSkinStatus.active);
    expect(byId['character.nora--anno']!.status, AdminSkinStatus.disabled);
    final jonas = byId['character.jonas--hell']!;
    expect(jonas.status, AdminSkinStatus.scheduled);
    expect(jonas.release?.name, 'Eine höllische Herausforderung');
    expect(statusText(jonas), 'Geplant');
    expect(
      releaseText(jonas),
      'Erscheint am So., 08.11.2026, 18:00 · Eine höllische Herausforderung',
    );
    final beatrice = byId['character.unique-beatrice']!;
    expect(beatrice.status, AdminSkinStatus.gated);
    expect(beatrice.unlock, 'alle Rollen aus Creepshow');
    expect(data.catalog.rarityOf(beatrice.item).name, 'Unique');
    expect(data.releases.map((r) => r.id), [
      'hell-2026',
      'traum-2026',
      'spaet',
    ]);
    // A disabled skin keeps the date of its release.
    final lea = byId['character.lea--freiheit']!;
    expect(lea.status, AdminSkinStatus.disabled);
    expect(lea.statuses, contains(AdminSkinStatus.scheduled));
    expect(
      lea.release!.startsAt!.isAtSameMomentAs(
        DateTime.parse('2026-11-22T17:00:00Z'),
      ),
      isTrue,
    );
    // A started release whose pack waits: the missing items come from the
    // catalog's list of releases.
    final emil = byId['character.emil--spaet']!;
    expect(emil.status, AdminSkinStatus.waiting);
    expect(emil.release?.ready, isFalse);
    expect(emil.release?.missing.map((m) => m.text), [
      'Gerda (deaktiviert)',
      'Fritzi (ohne Bild)',
    ]);
  });

  test('the telemetry never holds the name of a skin', () {
    expect(
      apiPathPattern('/admin/runner/skins/character-geheim-thumb.webp?v=abc'),
      '/admin/runner/skins/:id.webp',
    );
    expect(apiPathPattern('/admin/runner/catalog'), '/admin/runner/catalog');
  });

  testWidgets('only admins see the entry in the settings', (tester) async {
    for (final (role, features, shown) in [
      ('admin', _features, true),
      ('member', _features, false),
      // An older server without the viewer: no entry either.
      ('admin', _features.sublist(0, 3), false),
    ]) {
      final (controller, _) = await _signedIn(role: role, features: features);
      final devices = DeviceServices(
        controller,
        onTarget: (_) {},
        onForegroundMessage: (_) {},
      );
      await _pump(
        tester,
        SettingsScreen(controller: controller, devices: devices),
      );
      expect(
        find.byKey(const ValueKey('admin-skin-viewer')),
        shown ? findsOneWidget : findsNothing,
        reason: '$role $features',
      );
      expect(find.text('Admin'), shown ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('members get no viewer and no request, even when opened', (
    tester,
  ) async {
    final (controller, requests) = await _signedIn(role: 'member');
    await _pump(tester, AdminSkinViewerScreen(controller: controller));
    expect(find.text('Nur für Admins.'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('admins see every skin grouped by play, with filters', (
    tester,
  ) async {
    final (controller, requests) = await _signedIn();
    await _pump(tester, AdminSkinViewerScreen(controller: controller));
    expect(requests, hasLength(1));
    expect(
      find.text('10 von 10 Skins · nur für Admins sichtbar'),
      findsOneWidget,
    );
    // Grouped by play, newest first, then technicians and scenery.
    for (final group in [
      'Hölle 2027 · 1',
      'Creepshow 2026 · 2',
      'Anno 1146 2025 · 1',
      'Technik · 1',
      'Kulissen · 1',
      'Hindernis-Sets · 1',
      'Standard · 1',
    ]) {
      expect(find.text(group), findsOneWidget, reason: group);
    }
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('Hölle 2027 · 1'), lessThan(top('Creepshow 2026 · 2')));
    expect(top('Creepshow 2026 · 2'), lessThan(top('Anno 1146 2025 · 1')));
    // Names, roles and the status of each card.
    expect(find.text('Beatrice'), findsOneWidget);
    expect(find.text('Gated · Unique'), findsOneWidget);
    expect(find.text('Deaktiviert'), findsNWidgets(2));
    expect(
      find.text(
        'Erscheint am So., 08.11.2026, 18:00 · Eine höllische Herausforderung',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('admin-skins-status-disabled')));
    await tester.pump();
    expect(
      find.text('2 von 10 Skins · nur für Admins sichtbar'),
      findsOneWidget,
    );
    expect(find.text('Nora'), findsWidgets);
    expect(find.text('Lea'), findsOneWidget);
    expect(find.text('Elena'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('admin-skins-status-all')));
    await tester.tap(find.byKey(const ValueKey('admin-skins-category-legacy')));
    await tester.pump();
    expect(find.text('Nora'), findsWidgets);
    expect(
      find.text('1 von 10 Skins · nur für Admins sichtbar'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('admin-skins-category-all')));
    await tester.enterText(
      find.byKey(const ValueKey('admin-skins-search')),
      'creepshow lucy',
    );
    await tester.pump();
    expect(find.text('Elena'), findsOneWidget);
    expect(find.text('Beatrice'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the cards load the small pictures from the admins\' route', (
    tester,
  ) async {
    final pictures = <String>[];
    final (controller, _) = await _signedIn(pictures: pictures);
    await _pump(tester, AdminSkinViewerScreen(controller: controller));
    expect(pictures, isNotEmpty);
    expect(pictures, everyElement(contains('/admin/runner/skins/')));
    expect(pictures.where((p) => p.endsWith('elena-thumb.webp')), isNotEmpty);
    expect(pictures.where((p) => p.endsWith('elena-portrait.webp')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Sagenhaft previews the scheduled backdrop, all hazards and pickups',
    (tester) async {
      final (controller, _) = await _signedIn();
      final source = jsonDecode(
        File('server/src/wardrobe/catalog.json').readAsStringSync(),
      );
      final item = Map<String, dynamic>.from(
        source['items'].firstWhere((e) => e['id'] == 'backdrop.sagenhaft'),
      );
      for (final key in ['image', 'obstacles', 'collectibles', 'portrait']) {
        final file = item[key] as String;
        final path = '/admin/runner/skins/$file';
        WardrobePictures.keepFileForTest(
          path,
          File('server/src/wardrobe/images/$file').readAsBytesSync(),
        );
        item[key] = path;
      }
      final art = await tester.runAsync(() async {
        for (final key in ['image', 'obstacles', 'collectibles', 'portrait']) {
          final image = await WardrobePictures.load(
            controller,
            item[key] as String,
          );
          expect(image, isNotNull);
          if (key == 'obstacles')
            await RunnerArt.draws(image!, RunnerSprite.pile);
        }
        return RunnerArt.test(
          await createTestImage(width: 1124, height: 577),
          await createTestImage(width: 64, height: 32),
        );
      });
      final skin = AdminSkin(
        item: WardrobeItem.fromJson(item)!,
        live: false,
        release: AdminSkinRelease(
          id: 'sagenhaft-2027',
          active: false,
          name: 'Sagenhaft',
          startsAt: DateTime.parse('2027-03-14T17:00:00Z'),
        ),
      );
      await _pump(
        tester,
        AdminSkinDetailPage(
          skin: skin,
          catalog: AdminSkinCatalog.fromJson(_catalog).catalog,
          controller: controller,
          art: art,
        ),
      );
      for (
        var i = 0;
        i < 8 && find.text('Eigene Hindernisse').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Eigene Hindernisse'), findsOneWidget);
      expect(find.text('Eigene Sammelobjekte'), findsOneWidget);
      final icons = tester
          .widgetList<ObstacleIcon>(find.byType(ObstacleIcon))
          .toList();
      expect(icons.length, 9);
      final rendered = icons.first.art!;
      expect(rendered.ownPile, isTrue);
      expect(rendered.ownTruss, isTrue);
      expect(rendered.border, const Color(0xFF16482F));
      for (final name in [
        'Soffitte',
        'Kistenstapel',
        'Lichttraverse',
        'Pergamentrolle',
        'Blumenstrauß',
        'Ritterhelm',
      ]) {
        expect(find.text(name), findsOneWidget);
      }
    },
  );

  testWidgets('the page of a figure plays its moves and shows every pose', (
    tester,
  ) async {
    final (controller, _) = await _signedIn();
    final data = AdminSkinCatalog.fromJson(_catalog);
    final atlas = await tester.runAsync(
      () => createTestImage(width: 1124, height: 577),
    );
    final backdrop = await tester.runAsync(
      () => createTestImage(width: 64, height: 32),
    );
    final skin = data.skins.firstWhere((s) => s.item.id == 'character.default');
    await _pump(
      tester,
      AdminSkinDetailPage(
        skin: skin,
        catalog: data.catalog,
        controller: controller,
        art: RunnerArt.test(atlas!, backdrop!),
      ),
    );
    for (final move in ['stage', 'run', 'fly', 'dangle', 'cheer', 'crash']) {
      expect(find.byKey(ValueKey('admin-move-$move')), findsOneWidget);
    }
    for (final pose in RunnerSprite.values.where(
      (s) => s.layer == RunnerLayer.runner,
    )) {
      expect(find.byKey(ValueKey('admin-pose-${pose.name}')), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey('admin-showcase-character.default')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('admin-move-run')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('admin-move-character.default-run')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('admin-move-crash')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ID'), findsOneWidget);
    expect(find.text('Live'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  test('release dates read in Berlin time, with the weekday', () {
    // Winter time (UTC+1) and summer time (UTC+2), whatever the device's
    // time zone.
    expect(
      releaseDateText(DateTime.parse('2026-11-22T17:00:00Z').toLocal()),
      'So., 22.11.2026, 18:00',
    );
    expect(
      releaseDateText(DateTime.parse('2027-04-11T16:00:00Z')),
      'So., 11.04.2027, 18:00',
    );
    expect(
      releaseDateText(DateTime.parse('2027-03-28T00:30:00Z')),
      'So., 28.03.2027, 01:30',
    );
    expect(
      releaseDateText(DateTime.parse('2027-03-28T01:30:00Z')),
      'So., 28.03.2027, 03:30',
    );
    expect(
      releaseDateText(DateTime.parse('2026-12-31T23:05:00Z')),
      'Fr., 01.01.2027, 00:05',
    );
  });

  test('every skin says when it comes', () {
    final item = WardrobeItem.fromJson(_item('character.x', 'X'))!;
    AdminSkinRelease release({
      bool active = false,
      bool ready = true,
      String part = 'items',
    }) => AdminSkinRelease(
      id: 'traum-2026',
      name: 'Traum von Freiheit',
      startsAt: DateTime.parse('2026-11-22T17:00:00Z'),
      active: active,
      ready: ready,
      part: part,
    );
    const coming = 'Erscheint am So., 22.11.2026, 18:00 · Traum von Freiheit';
    for (final (skin, text) in [
      (AdminSkin(item: item), 'Live'),
      (AdminSkin(item: item, live: false, release: release()), coming),
      (
        AdminSkin(
          item: item,
          disabled: true,
          live: false,
          release: release(ready: false),
        ),
        coming,
      ),
      (
        AdminSkin(
          item: item,
          live: false,
          waiting: true,
          release: release(active: true, ready: false),
        ),
        'Termin vorbei, wartet auf Bilder',
      ),
      (
        AdminSkin(
          item: item,
          disabled: true,
          live: false,
          waiting: true,
          release: release(active: true, ready: false),
        ),
        'Termin vorbei, wartet auf Bilder',
      ),
      (
        AdminSkin(item: item, disabled: true, live: false),
        'Deaktiviert · kein Termin',
      ),
      (AdminSkin(item: item, secret: 'unique'), 'Gated · Unique'),
      (AdminSkin(item: item, secret: 'reward'), 'Gated · Ensemble'),
      (AdminSkin(item: item, release: release(active: true)), 'Live'),
      (
        AdminSkin(
          item: item,
          release: release(part: 'free'),
        ),
        'Live · Geschenk am So., 22.11.2026, 18:00 · Traum von Freiheit',
      ),
    ]) {
      expect(releaseText(skin), text);
    }
    // A server before `waiting`: a started release that is not live yet.
    final old = AdminSkin.fromJson(
      _item(
        'character.y',
        'Y',
        admin: {
          'disabled': false,
          'live': false,
          'release': {
            'id': 'spaet',
            'name': 'Spätlese',
            'startsAt': '2026-11-01T17:00:00.000Z',
            'active': true,
          },
          'secret': null,
        },
      ),
    )!;
    expect(old.waiting, isTrue);
    expect(old.status, AdminSkinStatus.waiting);
  });

  testWidgets('disabled skins show their state, date and a placeholder', (
    tester,
  ) async {
    final pictures = <String>[];
    final (controller, _) = await _signedIn(pictures: pictures);
    await _pump(tester, AdminSkinViewerScreen(controller: controller));
    // Nora has no picture yet: a placeholder with name, role and play.
    final nora = find.byKey(
      const ValueKey('admin-skin-placeholder-character.nora--anno'),
    );
    expect(nora, findsOneWidget);
    for (final text in [
      'Nora',
      'als Magd',
      'Anno 1146 2025',
      'Noch kein Bild',
    ]) {
      expect(
        find.descendant(of: nora, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    expect(
      find.byKey(const ValueKey('admin-skin-release-character.nora--anno')),
      findsOneWidget,
    );
    expect(find.text('Deaktiviert · kein Termin'), findsOneWidget);
    // Lea has her picture: loaded from the admins' route, with her date.
    expect(
      find.byKey(
        const ValueKey('admin-skin-placeholder-character.lea--freiheit'),
      ),
      findsNothing,
    );
    expect(pictures.where((p) => p.endsWith('lea-thumb.webp')), isNotEmpty);
    expect(
      find.text('Erscheint am So., 22.11.2026, 18:00 · Traum von Freiheit'),
      findsOneWidget,
    );
    // Emil's date has passed, his pack waits for pictures.
    expect(find.text('Wartet auf Bilder'), findsOneWidget);
    expect(find.text('Termin vorbei, wartet auf Bilder'), findsOneWidget);
    // Live skins without a release carry only their badge.
    expect(
      find.byKey(const ValueKey('admin-skin-release-character.elena--creep')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('admin-skins-status-waiting')));
    await tester.pump();
    expect(
      find.text('1 von 10 Skins · nur für Admins sichtbar'),
      findsOneWidget,
    );
    expect(find.text('Emil'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('admin-skins-status-scheduled')),
    );
    await tester.pump();
    // Jonas, and Lea: disabled, but her release is coming.
    expect(
      find.text('2 von 10 Skins · nur für Admins sichtbar'),
      findsOneWidget,
    );
    expect(find.text('Lea'), findsOneWidget);
    expect(find.text('Jonas'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('admin-skins-status-all')));
    await tester.enterText(
      find.byKey(const ValueKey('admin-skins-search')),
      'kein termin',
    );
    await tester.pump();
    expect(
      find.text('1 von 10 Skins · nur für Admins sichtbar'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the cards fit on phones of every width and text size', (
    tester,
  ) async {
    final (controller, _) = await _signedIn();
    // 381 to 398 wide (iPhone 12 to 16, Pixel 7 and 8) give three narrow
    // columns, where the two lines of a release once pushed the rarity out.
    for (final scale in [1.0, 1.3, 2.0]) {
      for (final width in <double>[
        320.0,
        360,
        375,
        381,
        385,
        390,
        393,
        398,
        412,
        430,
      ]) {
        await _pump(
          tester,
          MediaQuery(
            data: MediaQueryData(
              size: Size(width, 4000),
              textScaler: TextScaler.linear(scale),
            ),
            child: AdminSkinViewerScreen(controller: controller),
          ),
          size: Size(width, 4000),
        );
        expect(tester.takeException(), isNull, reason: '$width @ $scale');
        expect(
          find.text('Erscheint am So., 22.11.2026, 18:00 · Traum von Freiheit'),
          findsOneWidget,
          reason: '$width @ $scale',
        );
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets('sorted by date: coming releases first, then waiting packs', (
    tester,
  ) async {
    final (controller, _) = await _signedIn();
    await _pump(tester, AdminSkinViewerScreen(controller: controller));
    expect(find.text('Hölle 2027 · 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('admin-skins-sort-release')));
    await tester.pump();
    expect(find.text('Hölle 2027 · 1'), findsNothing);
    const groups = [
      'Erscheint am So., 08.11.2026, 18:00 · Eine höllische Herausforderung · 1',
      'Erscheint am So., 22.11.2026, 18:00 · Traum von Freiheit · 1',
      'Spätlese · Termin vorbei, wartet auf Bilder · 1',
      'Deaktiviert · kein Termin · 1',
      'Ohne Termin · 6',
    ];
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    for (final group in groups) {
      expect(find.text(group), findsOneWidget, reason: group);
    }
    for (var i = 1; i < groups.length; i++) {
      expect(top(groups[i - 1]), lessThan(top(groups[i])), reason: groups[i]);
    }
    // The filters still apply in this order.
    await tester.tap(find.byKey(const ValueKey('admin-skins-status-disabled')));
    await tester.pump();
    expect(find.text(groups[1]), findsOneWidget);
    expect(find.text(groups[3]), findsOneWidget);
    expect(find.text(groups[0]), findsNothing);
    // And back to the plays.
    await tester.tap(find.byKey(const ValueKey('admin-skins-sort-play')));
    await tester.pump();
    expect(find.text('Anno 1146 2025 · 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the page of a skin shows its release and what its pack lacks', (
    tester,
  ) async {
    final (controller, _) = await _signedIn();
    final data = AdminSkinCatalog.fromJson(_catalog);
    final atlas = await tester.runAsync(
      () => createTestImage(width: 1124, height: 577),
    );
    final backdrop = await tester.runAsync(
      () => createTestImage(width: 64, height: 32),
    );
    final art = RunnerArt.test(atlas!, backdrop!);
    AdminSkin skin(String id) => data.skins.firstWhere((s) => s.item.id == id);

    await _pump(
      tester,
      AdminSkinDetailPage(
        skin: skin('character.emil--spaet'),
        catalog: data.catalog,
        controller: controller,
        art: art,
      ),
    );
    expect(find.text('Termin'), findsOneWidget);
    expect(find.text('Termin vorbei, wartet auf Bilder'), findsOneWidget);
    expect(
      find.text(
        'Spätlese · So., 01.11.2026, 18:00 · gestartet · Set unvollständig',
      ),
      findsOneWidget,
    );
    expect(find.text('Es fehlen'), findsOneWidget);
    expect(
      find.text('Gerda (deaktiviert), Fritzi (ohne Bild)'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());

    await _pump(
      tester,
      AdminSkinDetailPage(
        skin: skin('character.nora--anno'),
        catalog: data.catalog,
        controller: controller,
        art: art,
      ),
    );
    expect(
      find.byKey(
        const ValueKey('admin-detail-placeholder-character.nora--anno'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('admin-showcase-character.nora--anno')),
      findsNothing,
    );
    expect(find.text('Deaktiviert · kein Termin'), findsOneWidget);
    expect(find.text('Deaktiviert'), findsWidgets);
    expect(find.text('Es fehlen'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await _pump(
      tester,
      AdminSkinDetailPage(
        skin: skin('character.lea--freiheit'),
        catalog: data.catalog,
        controller: controller,
        art: art,
      ),
    );
    expect(
      find.text('Erscheint am So., 22.11.2026, 18:00 · Traum von Freiheit'),
      findsOneWidget,
    );
    expect(find.text('Lea (deaktiviert)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
