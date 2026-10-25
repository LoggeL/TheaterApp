import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/missions_api.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/crate_animation.dart';
import 'package:theater_app/features/games/ui/crate_choice.dart';
import 'package:theater_app/features/games/ui/missions_card.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

// Crate points (`runnerCratePoints`) and crate targets (`runnerCrateTargets`):
// the own crates count points, and a crate of the own runs opens as the
// Zufallskiste or aimed at a play or the Technik-Kiste, each with its own
// opening animation.

class _Sound implements RunnerSound {
  final played = <RunnerSfx>[];
  final _enabled = ValueNotifier(true);
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  void prepare() {}
  @override
  void play(RunnerSfx sfx) => played.add(sfx);
  @override
  void startMusic() {}
  @override
  void stopMusic() {}
  @override
  void dispose() => _enabled.dispose();
}

JsonMap _item(
  String id,
  String kind,
  String name,
  String rarity, [
  JsonMap extra = const {},
]) => {
  'id': id,
  'kind': kind,
  'name': name,
  'rarity': rarity,
  'rarities': [rarity],
  ...extra,
};

JsonMap _target(
  String id,
  String kind,
  String name, {
  int owned = 0,
  int total = 4,
  int locked = 0,
  bool complete = false,
  bool available = true,
  String animation = 'generic',
  double shiny = .03,
  int? year,
}) => {
  'id': id,
  'kind': kind,
  'name': name,
  'play': ?(kind == 'play' ? name : null),
  'year': ?year,
  'animation': animation,
  'owned': owned,
  'total': total,
  'locked': locked,
  'complete': complete,
  'available': available,
  'shinyChance': shiny,
  'odds': available
      ? [
          {'rarity': 'hellblau', 'chance': .66},
          {'rarity': 'gold', 'chance': .34},
        ]
      : [],
};

/// A wardrobe with crate points and targets, as the server sends it.
JsonMap _wardrobeJson({int crates = 2, bool targets = true}) => {
  'progress': {
    'meters': 7400,
    'earned': 2,
    'opened': 2 - crates,
    'crates': crates,
    'previousAt': 6300,
    'nextAt': 9720,
    'poolSize': 3,
    'complete': false,
    'dupes': true,
    'runMeters': 3900,
    'bonusMeters': 400,
    'unit': 'points',
    'points': {
      'total': 7400,
      'base': 3158,
      'runs': 3342,
      'bonus': 450,
      'missions': 450,
    },
  },
  'catalog': {
    'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
    'rarities': [
      {'id': 'hellblau', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
      {
        'id': 'legacy',
        'name': 'Legacy',
        'color': '#A47A4B',
        'weight': 6,
        'hint': 'Sammle 10 hellblaue Figuren',
      },
      {'id': 'gold', 'name': 'Gold', 'color': '#E4AE39', 'weight': 1.5},
    ],
    'departments': [],
    'dupes': {
      'shinyChance': {'costume': .05, 'targeted': .03},
    },
    'items': [
      _item('c0', 'character', 'Engel Logge', 'hellblau', {'default': true}),
      _item('b0', 'backdrop', 'Bühnenwand', 'hellblau', {'default': true}),
      _item('o0', 'obstacles', 'Requisitenlager', 'hellblau', {
        'default': true,
      }),
      _item('f0', 'fx', 'Ohne Effekt', 'hellblau', {'default': true}),
      _item('lucy', 'character', 'Elena', 'gold', {
        'role': 'Lucy',
        'play': 'Creepshow',
        'year': 2026,
        'placeholder': true,
      }),
      _item('anton', 'character', 'Anton', 'legacy', {
        'role': 'Ritter',
        'play': 'Anno 1146',
        'year': 2025,
      }),
    ],
  },
  'lockedRarities': ['legacy'],
  'owned': ['c0', 'b0', 'o0', 'f0'],
  'selected': {
    'character': 'c0',
    'backdrop': 'b0',
    'obstacles': 'o0',
    'fx': 'f0',
  },
  'stats': {
    'rounds': 12,
    'best': 830,
    'meters': 3900,
    'creditedMeters': 300,
    'points': 3342,
    'bonusPoints': 450,
    'missionPoints': 450,
    'basePoints': 3158,
    'crateMeters': 2100,
  },
  if (targets)
    'crateTargets': [
      _target(
        'random',
        'random',
        'Zufallskiste',
        total: 6,
        animation: 'burst',
        shiny: .05,
      ),
      _target(
        'tech',
        'tech',
        'Technik-Kiste',
        owned: 2,
        total: 2,
        complete: true,
        animation: 'flightcase',
      ),
      _target(
        'play:creepshow',
        'play',
        'Creepshow',
        year: 2026,
        owned: 1,
        total: 3,
        animation: 'maw',
      ),
      _target(
        'play:anno-1146',
        'play',
        'Anno 1146',
        year: 2025,
        total: 1,
        locked: 1,
        available: false,
        animation: 'heavy',
      ),
    ],
};

JsonMap _openingJson(String target) => {
  'item': _item('lucy', 'character', 'Elena', 'gold', {
    'role': 'Lucy',
    'play': 'Creepshow',
    'year': 2026,
    'placeholder': true,
  }),
  'reel': List.filled(56, 'lucy'),
  'winnerIndex': 48,
  'outcome': {
    'type': 'new',
    'duplicate': false,
    'shiny': false,
    'rarity': 'gold',
    'crate': 'costume',
    'target': target,
  },
  'wardrobe': _wardrobeJson(crates: 1),
};

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerCratePoints',
  'runnerCrateTargets',
];

Future<AppController> _signedIn(
  Future<http.Response>? Function(http.Request) handle, {
  List<String> features = _features,
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = handle;
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return controller;
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: home),
  );
  await tester.pump();
  await tester.pump();
}

/// The crates' real pictures as the server has them (skins by file name).
Future<http.Response>? _crateSkins(http.Request request) {
  final path = _path(request);
  if (!path.contains('/games/runner/skins/')) return null;
  final file = File('server/src/wardrobe/images/${path.split('/').last}');
  return Future.value(
    file.existsSync()
        ? http.Response.bytes(
            file.readAsBytesSync(),
            200,
            headers: {'content-type': 'image/webp'},
          )
        : http.Response('', 404),
  );
}

/// [id]'s pictures on the server: `crate-<x>.webp`, `-open` and `-fx`.
CrateTarget _pictured(String id, String animation, Rect box) {
  final file = id.replaceFirst(':', '-');
  String skin(String part) =>
      '/games/runner/skins/crate-$file$part.webp?v=test';
  return CrateTarget(
    id: id,
    kind: id == 'random'
        ? CrateTargetKind.random
        : id == 'tech'
        ? CrateTargetKind.tech
        : CrateTargetKind.play,
    name: id,
    animation: animation,
    image: skin(''),
    imageBox: box,
    openImage: skin('-open'),
    fxImage: skin('-fx'),
    total: 4,
  );
}

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

/// A server for the wardrobe and crate openings; [opened] gets each body.
Future<http.Response>? Function(http.Request) _server(
  List<JsonMap> opened, {
  bool targets = true,
}) => (request) {
  final path = _path(request);
  if (path.endsWith('/wardrobe')) {
    return Future.value(jsonResponse(_wardrobeJson(targets: targets)));
  }
  if (path.endsWith('/crates')) {
    final body = jsonMap(jsonDecode(request.body));
    opened.add(body);
    return Future.value(
      jsonResponse(_openingJson('${body['target'] ?? 'random'}')),
    );
  }
  return null;
};

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(WardrobePictures.clear);

  group('crate points', () {
    final progress = RunnerProgress.fromJson({
      ..._wardrobeJson()['progress'] as JsonMap,
      'gained': 812,
      'bonus': 812,
      'missionBonus': 450,
      'gainedPoints': {'run': 1240, 'bonus': 1240, 'missions': 450},
    });

    test('the progress tells its unit and where the points come from', () {
      expect(progress.inPoints, isTrue);
      expect(progress.points!.base, 3158);
      expect(progress.remaining, 2320);
      expect(progress.fraction, closeTo(1100 / 3420, 1e-9));
      // An older server sends metres and no points.
      expect(
        RunnerProgress.fromJson({'meters': 2900, 'nextAt': 4100}).inPoints,
        isFalse,
      );
    });

    test('texts say points: after a run, on the crate card, for a mission', () {
      expect(
        runProgressText(progress, showBonus: true),
        '+1.240 Punkte · Tagesbonus +1.240 · Missionen +450 · noch 2.320 Punkte bis zur nächsten Kiste',
      );
      expect(
        crateDistanceText(progress, showBonus: true),
        '6.500 Punkte erspielt + 450 Tagesbonus + 450 Missionen · noch 2.320 Punkte bis zur nächsten Kiste',
      );
      // Without the Tagesbonus shown it is part of what was played; the parts add up.
      expect(
        crateDistanceText(progress),
        '6.950 Punkte erspielt + 450 Missionen · noch 2.320 Punkte bis zur nächsten Kiste',
      );
      expect(pointsText(1), '1 Punkt');
      final mission = DailyMission.fromJson({
        'slot': 'easy',
        'type': 'distance',
        'text': 'Lauf',
        'target': 100,
        'reward': 450,
        'rewardUnit': 'points',
      });
      expect(missionRewardText(mission), '+450 Punkte für die Kisten');
      final older = DailyMission.fromJson({
        'slot': 'easy',
        'type': 'distance',
        'text': 'Lauf',
        'target': 100,
        'reward': 300,
      });
      expect(missionRewardText(older), '+300 m für die Kisten');
    });

    test('older servers keep their metres', () {
      final old = RunnerProgress.fromJson({
        'meters': 2900,
        'earned': 1,
        'previousAt': 2000,
        'nextAt': 4100,
        'gained': 400,
      });
      expect(
        runProgressText(old),
        '+400 m · noch 1.200 m bis zur nächsten Kiste',
      );
      expect(
        crateDistanceText(old),
        '2.900 m gelaufen · noch 1.200 m bis zur nächsten Kiste',
      );
    });

    testWidgets(
      'the statistics show the points and the base from the metres before',
      (tester) async {
        final controller = await _signedIn(_server([]));
        await _pump(
          tester,
          WardrobeScreen(controller: controller, sound: _Sound()),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('Statistik'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Kistenpunkte gesamt: 7.400 Punkte · aus Läufen 3.342 · Tagesbonus 450 · Missionen 450',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Davon 3.158 Punkte aus deiner früheren Kistenstrecke (2.100 m): gleich viele Kisten, gleicher Stand bis zur nächsten.',
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('wardrobe-bonus-total')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('crate targets', () {
    test('the wardrobe reads the targets with their progress and odds', () {
      final w = Wardrobe.fromJson(_wardrobeJson());
      expect(w.crateTargets.map((t) => t.id), [
        'random',
        'tech',
        'play:creepshow',
        'play:anno-1146',
      ]);
      final creepshow = w.crateTarget('play:creepshow')!;
      expect(
        [
          creepshow.kind,
          creepshow.title,
          creepshow.animation,
          creepshow.owned,
          creepshow.total,
        ],
        [CrateTargetKind.play, 'Creepshow 2026', 'maw', 1, 3],
      );
      expect(creepshow.odds.first, ('hellblau', .66));
      expect(crateTargetProgress(w.crateTarget('tech')!), '2/2 · komplett');
      expect(
        crateTargetProgress(w.crateTarget('play:anno-1146')!),
        '0/1 · 1 gesperrt',
      );
      expect(w.crateTarget('play:anno-1146')!.available, isFalse);
      expect(
        Wardrobe.fromJson(_wardrobeJson(targets: false)).crateTargets,
        isEmpty,
      );
    });

    testWidgets(
      'opening a crate first asks which one; the choice goes to the server and opens its way',
      (tester) async {
        final opened = <JsonMap>[];
        final controller = await _signedIn(_server(opened));
        final sound = _Sound();
        await _pump(
          tester,
          WardrobeScreen(controller: controller, sound: sound),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byKey(const ValueKey('wardrobe-tab-crates')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(
          find.byKey(const PageStorageKey('wardrobe-crate-details')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(const ValueKey('wardrobe-targets-hint')),
          findsOneWidget,
        );
        expect(
          find.text(
            '6.950 Punkte erspielt + 450 Missionen · noch 2.320 Punkte bis zur nächsten Kiste',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('wardrobe-open')));
        await tester.pumpAndSettle();
        expect(find.text('Welche Kiste?'), findsOneWidget);
        // The Zufallskiste shines more; a complete set says so; a locked one tells why.
        expect(find.text('mehr Glanz'), findsOneWidget);
        expect(find.text('0/6 · Glanz 5 %'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('crate-target-complete-tech')),
          findsOneWidget,
        );
        expect(find.text('2/2 · komplett · Glanz 3 %'), findsOneWidget);
        expect(find.text('Bringt jetzt Glanz oder Gage.'), findsOneWidget);
        expect(
          tester
              .widget<Text>(
                find.byKey(
                  const ValueKey('crate-target-progress-play:anno-1146'),
                ),
              )
              .data,
          'Sammle 10 hellblaue Figuren',
        );
        // A locked crate cannot be chosen.
        await tester.tap(
          find.byKey(const ValueKey('crate-target-play:anno-1146')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(find.text('Welche Kiste?'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('crate-target-play:creepshow')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(opened.single['target'], 'play:creepshow');
        expect(opened.single['dupes'], isTrue);
        // Its own animation first, then the reel.
        expect(
          find.byKey(const ValueKey('crate-unboxing-play:creepshow')),
          findsOneWidget,
        );
        expect(find.text('Die Kiste „Creepshow“ geht auf …'), findsOneWidget);
        expect(sound.played, contains(RunnerSfx.whoosh));
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const ValueKey('crate-reel')), findsOneWidget);
        expect(find.text('Creepshow 2026'), findsOneWidget);
        for (var i = 0; i < 80; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Nächste Kiste (1)'), findsOneWidget);
        // The next crate is chosen again.
        await tester.tap(find.text('Nächste Kiste (1)'));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Welche Kiste?'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('crate-target-random')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(opened.last['target'], 'random');
        expect(
          find.byKey(const ValueKey('crate-unboxing-random')),
          findsOneWidget,
        );
        // A tap skips the animation to the reel.
        await tester.tapAt(const Offset(400, 300));
        await tester.pump();
        expect(find.byKey(const ValueKey('crate-reel')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'without crate targets the crate opens at once, without a target',
      (tester) async {
        final opened = <JsonMap>[];
        final controller = await _signedIn(
          _server(opened, targets: false),
          features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes'],
        );
        await _pump(
          tester,
          WardrobeScreen(controller: controller, sound: _Sound()),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byKey(const ValueKey('wardrobe-tab-crates')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(
          find.byKey(const PageStorageKey('wardrobe-crate-details')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(const ValueKey('wardrobe-targets-hint')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('wardrobe-open')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Welche Kiste?'), findsNothing);
        expect(opened.single.containsKey('target'), isFalse);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('crate-reel')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('crate pictures', () {
    test('a target brings where its crate stands on the picture', () {
      final t = CrateTarget.fromJson({
        'id': 'random',
        'kind': 'random',
        'name': 'Zufallskiste',
        'image': '/games/runner/skins/crate-random.webp?v=1',
        'imageBox': [46, 180, 463, 492],
      });
      expect(t.imageBox, const Rect.fromLTRB(46, 180, 463, 492));
      // A number in the play's name stands alone, without the year.
      expect(
        CrateTarget.fromJson({
          'id': 'play:anno-1146',
          'kind': 'play',
          'name': 'Anno 1146',
          'year': 2025,
        }).title,
        'Anno 1146',
      );
      for (final bad in [
        null,
        [1, 2, 3],
        [5, 5, 5, 9],
        'oben',
      ]) {
        expect(
          CrateTarget.fromJson({'id': 'x', 'imageBox': bad}).imageBox,
          isNull,
        );
      }
    });

    testWidgets('the cards show each crate cut to where it stands', (
      tester,
    ) async {
      final controller = await _signedIn(_crateSkins);
      final wardrobe = Wardrobe.fromJson(_wardrobeJson());
      final targets = [
        _pictured('random', 'burst', const Rect.fromLTRB(46, 180, 463, 492)),
        _pictured(
          'play:nexus',
          'glitch',
          const Rect.fromLTRB(51, 212, 461, 492),
        ),
      ];
      final cards = [
        for (final t in targets)
          SizedBox(
            width: 190,
            child: CrateTargetCard(
              target: t,
              wardrobe: wardrobe,
              controller: controller,
            ),
          ),
      ];
      // Loaded outside the test's fake time: decoding needs real time.
      await tester.runAsync(() async {
        for (final t in targets) {
          await WardrobePictures.loadPortrait(controller, t.image);
        }
      });
      await _pump(tester, Scaffold(body: Column(children: cards)));
      expect(find.byType(CrateFallback), findsNothing);
      for (final t in targets) {
        expect(
          find.byKey(ValueKey('crate-picture-crop-${t.id}')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });

    for (final (id, animation) in [
      ('random', 'burst'),
      ('play:anno-1146', 'heavy'),
    ]) {
      testWidgets('the $animation crate opens with its own pictures', (
        tester,
      ) async {
        final controller = await _signedIn(_crateSkins);
        final target = _pictured(
          id,
          animation,
          const Rect.fromLTRB(46, 180, 463, 492),
        );
        var done = 0;
        Widget crate(bool opening) => MaterialApp(
          home: Scaffold(
            body: Center(
              child: CrateUnboxing(
                target: target,
                controller: controller,
                opening: opening,
                onOpened: () => done++,
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          for (final path in [target.image, target.openImage, target.fxImage]) {
            expect(
              await WardrobePictures.loadPortrait(controller, path),
              isNotNull,
              reason: path,
            );
          }
        });
        await tester.pumpWidget(crate(false));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(CrateFallback), findsNothing);
        // Closed while the server draws, then the open picture takes over.
        expect(find.byType(RawImage), findsOneWidget);
        await tester.pumpWidget(crate(true));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(done, 1);
        expect(find.byType(RawImage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('crate animations', () {
    test('every crate has a variant; a future one plays the generic one', () {
      for (final name in [
        'generic',
        'burst',
        'flightcase',
        'maw',
        'glitch',
        'heavy',
        'threads',
      ]) {
        expect(CrateMotion.variants.containsKey(name), isTrue, reason: name);
      }
      expect(
        CrateMotion.of('feuerwerk'),
        same(CrateMotion.variants['generic']),
      );
      // Light enough for weak devices: a few dozen particles at most.
      expect(
        CrateMotion.variants.values.every(
          (m) => m.count <= 48 && m.millis <= 1800,
        ),
        isTrue,
      );
    });

    for (final name in [...CrateMotion.variants.keys, 'unbekannt']) {
      testWidgets(
        'the $name animation wobbles, opens and tells when it is done',
        (tester) async {
          final controller = await _signedIn((_) => null);
          final target = CrateTarget(
            id: 'x-$name',
            kind: CrateTargetKind.play,
            name: 'Stück',
            animation: name,
          );
          var done = 0;
          Widget crate(bool opening) => MaterialApp(
            home: Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: CrateUnboxing(
                  target: target,
                  controller: controller,
                  opening: opening,
                  onOpened: () => done++,
                ),
              ),
            ),
          );
          await tester.pumpWidget(crate(false));
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(done, 0, reason: 'waits while the server draws');
          await tester.pumpWidget(crate(true));
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(done, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  });
}
