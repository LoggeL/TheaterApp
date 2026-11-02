import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// Crates for gage (`runnerGageCrates`): bought in the wardrobe, opened at once.

class _Sound implements RunnerSound {
  final _enabled = ValueNotifier(true);
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  void prepare() {}
  @override
  void play(RunnerSfx sfx) {}
  @override
  void startMusic() {}
  @override
  void stopMusic() {}
  @override
  void dispose() => _enabled.dispose();
}

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerGageCrates',
];

JsonMap _item(String id, String kind, String name, {bool isDefault = false}) =>
    {
      'id': id,
      'kind': kind,
      'name': name,
      'rarity': 'hell',
      'rarities': ['hell'],
      if (isDefault) 'default': true,
    };

JsonMap _target(String id, String kind, String name) => {
  'id': id,
  'kind': kind,
  'name': name,
  'animation': 'generic',
  'owned': 1,
  'total': 3,
  'shinyChance': 0.05,
};

JsonMap _wardrobeJson({
  int gage = 130,
  int? price = 50,
  bool targets = false,
}) => {
  'progress': {
    'meters': 100,
    'earned': 0,
    'opened': 0,
    'crates': 0,
    'previousAt': 0,
    'nextAt': 2000,
    'poolSize': 2,
    'dupes': true,
  },
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hell', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
    ],
    'dupes': {'tradeDupes': 5, 'buyDupes': 10, 'crateGage': ?price},
    'items': [
      _item('c0', 'character', 'Engel Logge', isDefault: true),
      _item('b0', 'backdrop', 'Bühnenwand', isDefault: true),
      _item('o0', 'obstacles', 'Requisitenlager', isDefault: true),
      _item('f0', 'fx', 'Ohne Effekt', isDefault: true),
      _item('maren', 'character', 'Maren'),
    ],
  },
  'owned': ['c0', 'b0', 'o0', 'f0'],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'gage': {'balance': gage, 'earned': 400},
  if (targets)
    'crateTargets': [
      _target('random', 'random', 'Zufallskiste'),
      _target('tech', 'tech', 'Technik-Kiste'),
    ],
};

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<void> _open(
  WidgetTester tester,
  JsonMap wardrobe, {
  List<String> features = _features,
  List<JsonMap>? opened,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = (request) {
    final path = _path(request);
    if (path.endsWith('/games/runner/wardrobe')) {
      return Future.value(jsonResponse(wardrobe));
    }
    if (path.endsWith('/games/runner/crates')) {
      opened?.add(jsonMap(jsonDecode(request.body)));
      return Future.value(
        jsonResponse({
          'item': _item('maren', 'character', 'Maren'),
          'reel': List.filled(56, 'maren'),
          'winnerIndex': 48,
          'outcome': {'type': 'new', 'crate': 'gage', 'cost': 50},
          'wardrobe': {
            ...wardrobe,
            'gage': {'balance': 30, 'earned': 400},
          },
        }),
      );
    }
    return path.contains('/games/runner/')
        ? Future.value(jsonResponse({}))
        : null;
  };
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: WardrobeScreen(controller: controller, sound: _Sound()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  // Everything gage buys is in the crates' tab.
  await tester.tap(find.byKey(const ValueKey('wardrobe-tab-crates')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder get _buy => find.byKey(const ValueKey('wardrobe-buy-crate'));

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('the price comes from the catalog; older servers have none', () {
    expect(Wardrobe.fromJson(_wardrobeJson()).catalog.dupes.crateGage, 50);
    expect(
      Wardrobe.fromJson(_wardrobeJson(price: 250)).catalog.dupes.crateGage,
      250,
    );
    expect(
      Wardrobe.fromJson(_wardrobeJson(price: null)).catalog.dupes.crateGage,
      isNull,
    );
    expect(DupeRules.fromJson({'crateGage': 0}).crateGage, isNull);
  });

  test('a bought crate names what it cost', () {
    final outcome = CrateOutcome.fromJson({
      'type': 'new',
      'crate': 'gage',
      'cost': 50,
    });
    expect(outcome.cost, 50);
  });

  testWidgets('the offer shows the price from the server', (tester) async {
    await _open(tester, _wardrobeJson(price: 250, gage: 300));
    expect(
      find.descendant(of: _buy, matching: find.text('250 Gage')),
      findsOneWidget,
    );
    expect(find.text('Noch zu teuer'), findsNothing);
    expect(
      find.byKey(const ValueKey('wardrobe-buy-crate-missing')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('too little gage shows what is missing, no disabled button', (
    tester,
  ) async {
    final opened = <JsonMap>[];
    await _open(tester, _wardrobeJson(gage: 10), opened: opened);
    expect(_buy, findsNothing);
    final missing = find.byKey(const ValueKey('wardrobe-buy-crate-missing'));
    expect(
      find.descendant(of: missing, matching: find.text('noch 40 Gage')),
      findsOneWidget,
    );
    expect(find.text('Noch zu teuer'), findsOneWidget);
    await tester.tap(missing, warnIfMissed: false);
    await tester.pump();
    expect(find.text('Kiste kaufen?'), findsNothing);
    expect(opened, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without crate targets: confirm, then it opens', (tester) async {
    final opened = <JsonMap>[];
    await _open(tester, _wardrobeJson(), opened: opened);
    await tester.tap(_buy);
    await tester.pumpAndSettle();
    expect(find.text('Kiste kaufen?'), findsOneWidget);
    expect(
      find.text('Eine Kiste für 50 Gage. Danach bleiben 80 Gage.'),
      findsOneWidget,
    );
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const ValueKey('deal-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(opened.single, {'dupes': true, 'crate': 'gage'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling pays nothing', (tester) async {
    final opened = <JsonMap>[];
    await _open(tester, _wardrobeJson(), opened: opened);
    await tester.tap(_buy);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with crate targets the choice comes first and aims the crate', (
    tester,
  ) async {
    final opened = <JsonMap>[];
    await _open(
      tester,
      _wardrobeJson(targets: true),
      features: const [..._features, 'runnerCrateTargets'],
      opened: opened,
    );
    await tester.tap(_buy);
    await tester.pumpAndSettle();
    expect(find.text('Welche Kiste?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('crate-target-tech')));
    await tester.pumpAndSettle();
    expect(
      find.text('Technik-Kiste für 50 Gage. Danach bleiben 80 Gage.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('deal-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(opened.single, {'dupes': true, 'crate': 'gage', 'target': 'tech'});
    // Skip the unboxing and the reel: each crate is bought on its own.
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(const Offset(400, 200));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Nächste Kiste'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without the feature there is no offer', (tester) async {
    await _open(
      tester,
      _wardrobeJson(),
      features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes'],
    );
    expect(_buy, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an older server without a price has no offer either', (
    tester,
  ) async {
    await _open(tester, _wardrobeJson(price: null));
    expect(_buy, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
