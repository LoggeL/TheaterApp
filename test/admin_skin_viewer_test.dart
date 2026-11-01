import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/core/telemetry/perf_stats.dart';
import 'package:theater_app/features/games/data/admin_skins_api.dart';
import 'package:theater_app/features/games/ui/admin_skin_viewer.dart';
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
    _item('backdrop.forest', 'Wald', kind: 'backdrop'),
    _item('obstacles.tech', 'Technik-Kram', kind: 'obstacles'),
  ],
  'releases': [
    {
      'id': 'hell-2026',
      'name': 'Eine höllische Herausforderung',
      'startsAt': '2026-11-08T17:00:00.000Z',
      'active': false,
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

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 2400);
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
    expect(data.skins, hasLength(8));
    expect(byId['character.elena--creep']!.status, AdminSkinStatus.active);
    expect(byId['character.nora--anno']!.status, AdminSkinStatus.disabled);
    final jonas = byId['character.jonas--hell']!;
    expect(jonas.status, AdminSkinStatus.scheduled);
    expect(jonas.release?.name, 'Eine höllische Herausforderung');
    expect(statusText(jonas), startsWith('ab 08.11.2026'));
    final beatrice = byId['character.unique-beatrice']!;
    expect(beatrice.status, AdminSkinStatus.gated);
    expect(beatrice.unlock, 'alle Rollen aus Creepshow');
    expect(data.catalog.rarityOf(beatrice.item).name, 'Unique');
    expect(data.releases.single.id, 'hell-2026');
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
      find.text('8 von 8 Skins · nur für Admins sichtbar'),
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
    expect(find.text('Disabled'), findsWidgets);
    expect(find.textContaining('ab 08.11.2026'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('admin-skins-status-disabled')));
    await tester.pump();
    expect(
      find.text('1 von 8 Skins · nur für Admins sichtbar'),
      findsOneWidget,
    );
    expect(find.text('Nora'), findsOneWidget);
    expect(find.text('Elena'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('admin-skins-status-all')));
    await tester.tap(find.byKey(const ValueKey('admin-skins-category-legacy')));
    await tester.pump();
    expect(find.text('Nora'), findsOneWidget);
    expect(
      find.text('1 von 8 Skins · nur für Admins sichtbar'),
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
    expect(find.text('Aktiv'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
