import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/features/games/data/runner_menu_preferences.dart';
import 'package:theater_app/features/games/domain/runner_ghost.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_ghosts.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart'
    show WardrobePictures;
import 'package:theater_app/features/games/ui/stage_runner_screen.dart'
    show stagePainterFor;

import 'app_controller_test.dart' show TestServer;

/// The runner's height standing on the floor.
const _standing = StageRunner.floor - StageRunner.runnerHeight / 2;

/// A ghost of [rank] standing on the floor for [seconds], then crashed.
RunnerGhost _ghost(
  int rank, {
  bool me = false,
  double seconds = 30,
  double y = _standing,
  GhostFigure? figure,
}) {
  final n = (seconds * ghostHz).floor() + 1;
  return RunnerGhost(
    personId: 100 + rank,
    name: 'P$rank',
    rank: rank,
    score: 1000 - rank,
    meters: 900 - rank,
    samples: Uint8List(n)..fillRange(0, n, ghostByte(y)),
    me: me,
    figure: figure,
  );
}

List<int> _ranks(Iterable<RunnerGhost> ghosts) => [
  for (final g in ghosts) g.rank,
];

/// What the stage draws, in order: images (with their paint's opacity) and
/// the silhouettes' paths.
class _Drawn implements Canvas {
  final calls = <(String, ui.Image?, Rect?, double)>[];

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) =>
      calls.add(('image', image, src, paint.color.a));

  @override
  void drawPath(Path path, Paint paint) =>
      calls.add(('path', null, null, paint.color.a));

  @override
  void saveLayer(Rect? bounds, Paint paint) =>
      calls.add(('layer', null, bounds, paint.color.a));

  @override
  int getSaveCount() => 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

ui.Image _picture(int width, int height) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF808080),
  );
  return recorder.endRecording().toImageSync(width, height);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(WardrobePictures.clear);

  group('which ghosts', () {
    final all = [for (var rank = 1; rank <= 8; rank++) _ghost(rank)];

    test('"Alle" shows everyone, best first', () {
      expect(_ranks(pickGhosts(all, GhostMode.all)), [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('"Wenige": the first, the own best and the one just ahead', () {
      final mine = [for (final g in all) g.rank == 6 ? _ghost(6, me: true) : g];
      expect(_ranks(pickGhosts(mine, GhostMode.few)), [1, 5, 6]);
      expect(pickGhosts(mine, GhostMode.few).where((g) => g.me), hasLength(1));
      // The own place from the ranking when the own best has no ghost.
      final noOwnGhost = [
        for (final g in all)
          if (g.rank != 4) g,
      ];
      expect(_ranks(pickGhosts(noOwnGhost, GhostMode.few, ownRank: 4)), [1, 3]);
    });

    test('"Wenige" counts everyone once', () {
      List<int> few(int own) => _ranks(
        pickGhosts([
          for (final g in all) g.rank == own ? _ghost(own, me: true) : g,
        ], GhostMode.few),
      );
      // First of the week: only the own run.
      expect(few(1), [1]);
      // Second: the first is also the one ahead.
      expect(few(2), [1, 2]);
      expect(few(3), [1, 2, 3]);
    });

    test('"Wenige" without an own place yet: the first two', () {
      expect(_ranks(pickGhosts(all, GhostMode.few)), [1, 2]);
      expect(_ranks(pickGhosts(all.take(1).toList(), GhostMode.few)), [1]);
      expect(pickGhosts(const [], GhostMode.few), isEmpty);
    });

    test('a run switches between them; the names stay with the few', () {
      final ghosts = RunnerGhosts([
        all[4],
        all[0],
        _ghost(7, me: true),
        all[2],
        all[5],
      ], ownRank: 7);
      expect(ghosts.mode, GhostMode.few);
      expect(_ranks(ghosts.ghosts), [1, 3, 5, 6, 7]);
      expect(_ranks(ghosts.shown), [1, 6, 7]);
      ghosts.mode = GhostMode.all;
      expect(_ranks(ghosts.shown), [1, 3, 5, 6, 7]);
      expect(_ranks(ghosts.named.toList()..sort((a, b) => a.rank - b.rank)), [
        1,
        6,
        7,
      ]);
      ghosts.mode = GhostMode.few;
      expect(_ranks(ghosts.shown), [1, 6, 7]);
      expect(ghosts.leader!.rank, 1);
    });

    test('the server names the figure of each ghost', () {
      final y = base64Encode(Uint8List(21)..fillRange(0, 21, 200));
      final ghost = RunnerGhost.fromJson({
        'personId': 4,
        'rank': 2,
        'y': y,
        'character': {
          'id': 'character.lena',
          'image': '/games/runner/skins/character-lena.webp?v=1',
        },
      })!;
      expect(ghost.figure!.id, 'character.lena');
      expect(
        ghost.figure!.image,
        '/games/runner/skins/character-lena.webp?v=1',
      );
      expect(ghost.figure!.isDefault, isFalse);
      final plain = RunnerGhost.fromJson({
        'y': y,
        'character': {
          'id': 'character.engel-logge',
          'image': null,
          'default': true,
        },
      })!;
      expect((plain.figure!.image, plain.figure!.isDefault), (null, true));
      // Older servers and a figure gone from the catalog: a silhouette.
      expect(RunnerGhost.fromJson({'y': y})!.figure, isNull);
      expect(RunnerGhost.fromJson({'y': y, 'character': null})!.figure, isNull);
      expect(RunnerGhost.fromJson({'y': y, 'character': 'x'})!.figure, isNull);
    });
  });

  group('how clear', () {
    test('a quarter at most, nearly invisible on the own figure', () {
      expect(ghostAlpha(.3, .7), ghostOpacity);
      expect(ghostOpacity, .25);
      expect(
        ghostAlpha(_standing - StageRunner.runnerHeight, _standing),
        closeTo(ghostOpacity, 1e-9),
      );
      expect(ghostAlpha(_standing, _standing), ghostOpacity * ghostNearShare);
      expect(ghostAlpha(_standing, _standing), lessThan(.03));
      expect(
        ghostAlpha(_standing - StageRunner.runnerHeight * .4, _standing),
        ghostOpacity * ghostNearShare,
      );
      // In between it fades steadily, alike above and below.
      var last = 0.0;
      for (var i = 0; i <= 20; i++) {
        final apart = StageRunner.runnerHeight * i / 20;
        final alpha = ghostAlpha(.5 - apart, .5);
        expect(alpha, greaterThanOrEqualTo(last));
        expect(ghostAlpha(.5 + apart, .5), closeTo(alpha, 1e-12));
        last = alpha;
      }
    });

    test('names for the first two seconds, then they fade out', () {
      expect(ghostTagAlpha(0), 1);
      expect(ghostTagAlpha(1.99), 1);
      expect(ghostTagAlpha(2), 1);
      expect(ghostTagAlpha(2.25), closeTo(.5, 1e-9));
      expect(ghostTagAlpha(2.5), 0);
      expect(ghostTagAlpha(60), 0);
    });

    test('a ghost runs, flies and sinks as it was recorded', () {
      final n = 3 * ghostHz;
      final samples = Uint8List(n);
      for (var i = 0; i < n; i++) {
        // On the floor for a second, up for one, down for one.
        final t = i / ghostHz;
        final y = t < 1
            ? _standing
            : t < 2
            ? _standing - (t - 1) * .3
            : _standing - .3 + (t - 2) * .2;
        samples[i] = ghostByte(y);
      }
      final ghost = RunnerGhost(
        personId: 1,
        name: 'A',
        rank: 1,
        score: 1,
        meters: 1,
        samples: samples,
      );
      expect(ghost.onFloorAt(.5), isTrue);
      expect(ghost.onFloorAt(1.5), isFalse);
      // Within a 255th of the stage per sample.
      expect(ghost.vyAt(1.5), closeTo(-.3, .07));
      expect(ghost.vyAt(2.5), closeTo(.2, .07));
    });
  });

  group('the choice', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('"Wenige" by default, kept on this device', () async {
      final preferences = RunnerMenuPreferences();
      await preferences.loaded;
      expect(preferences.ghostMode, GhostMode.few);
      preferences.setGhostMode(GhostMode.all);
      expect(preferences.ghostMode, GhostMode.all);
      await pumpEventQueue();
      expect(
        (await SharedPreferences.getInstance()).getString(
          RunnerMenuPreferences.ghostModeKey,
        ),
        'all',
      );
      preferences.dispose();
      final again = RunnerMenuPreferences();
      await again.loaded;
      expect(again.ghostMode, GhostMode.all);
      again.dispose();
    });

    test('the old training switch and unknown values leave "Wenige"', () async {
      SharedPreferences.setMockInitialValues({
        'stageRunner.trainingGhosts': false,
        RunnerMenuPreferences.ghostModeKey: 'none',
      });
      final preferences = RunnerMenuPreferences();
      await preferences.loaded;
      expect(preferences.ghostMode, GhostMode.few);
      preferences.dispose();
    });

    test('without storage the choice still holds for now', () async {
      final preferences = RunnerMenuPreferences(
        loadPreferences: () => Future.error(StateError('no storage')),
      );
      await preferences.loaded;
      preferences.setGhostMode(GhostMode.all);
      await pumpEventQueue();
      expect(preferences.ghostMode, GhostMode.all);
      preferences.dispose();
    });
  });

  group('figures', () {
    setUp(GhostSkins.reset);
    tearDown(() => GhostSkins.budget = 10);

    test('a session loads only so many figures for ghosts', () async {
      // Signed out: every load fails at once, which is all this needs.
      final controller = TestServer().controller();
      addTearDown(controller.dispose);
      GhostSkins.budget = 2;
      final art = RunnerArt.test(_picture(4, 4), _picture(4, 4));
      GhostFigure figure(int i) =>
          GhostFigure(id: 'c$i', image: '/games/runner/skins/c$i.webp?v=1');
      final ghosts = [
        for (var i = 1; i <= 4; i++) _ghost(i, figure: figure(i)),
        _ghost(5, figure: figure(1)),
        _ghost(6, figure: const GhostFigure(id: 'plain')),
      ];
      final skins = GhostSkins(controller)..want(ghosts, art);
      expect(GhostSkins.asked, 2);
      // Another run asks for the same ones again, but for no others.
      final next = GhostSkins(controller)..want(ghosts.reversed, art);
      expect(GhostSkins.asked, 2);
      // Not loaded (or beyond the budget): a silhouette; the game's own
      // figure from its own atlas.
      expect(skins.of(ghosts[2], art), isNull);
      expect(skins.of(ghosts[5], art), isNull);
      expect(
        skins.of(
          _ghost(7, figure: const GhostFigure(id: 'e', isDefault: true)),
          art,
        ),
        art.atlas,
      );
      // Plain shapes without the game's pictures: no figures at all.
      GhostSkins.reset();
      GhostSkins(controller).want(ghosts, null);
      expect(GhostSkins.asked, 0);
      await pumpEventQueue();
      skins.dispose();
      next.dispose();
    });

    test(
      'a run started before the art loads its figures once it is there',
      () async {
        final controller = TestServer().controller();
        addTearDown(controller.dispose);
        final art = RunnerArt.test(_picture(4, 4), _picture(4, 4));
        final ghosts = [
          for (var i = 1; i <= 3; i++)
            _ghost(
              i,
              figure: GhostFigure(
                id: 'c$i',
                image: '/games/runner/skins/c$i.webp?v=1',
              ),
            ),
        ];
        final skins = GhostSkins(controller)..want(ghosts, null);
        expect(GhostSkins.asked, 0, reason: 'no art yet: nothing loads');
        skins.artReady(null);
        expect(GhostSkins.asked, 0);
        skins.artReady(art);
        expect(GhostSkins.asked, 3, reason: 'the art came during the run');
        // Dressed anew later: nothing waits any more.
        skins.artReady(art);
        expect(GhostSkins.asked, 3);
        await pumpEventQueue();
        skins.dispose();
      },
    );

    test('ghosts are drawn faint and behind the course', () {
      final atlas = _picture(1124, 580), skin = _picture(1124, 580);
      final art = RunnerArt.test(atlas, _picture(8, 8));
      final game = StageRunner(seed: 7)
        ..obstacles.clear()
        ..pickups.clear()
        ..obstacles.add(
          Obstacle()
            ..left = .6
            ..width = .12
            ..top = StageRunner.floor - .2
            ..bottom = StageRunner.floor,
        );
      const figure = GhostFigure(id: 'c', image: 'skin');
      final far = _ghost(1, y: .3, figure: figure);
      final near = _ghost(2, figure: figure);
      final plain = _ghost(3, y: .4);
      final ghosts = RunnerGhosts([far, near, plain], mode: GhostMode.all);
      final skins = GhostSkins(TestServer().controller())
        ..keepForTest('skin', skin);
      List<(String, ui.Image?, Rect?, double)> draw() {
        final canvas = _Drawn();
        stagePainterFor(
          game,
          art,
          ghosts: ghosts,
          ghostSkins: skins,
        ).paint(canvas, const Size(800, 500));
        return canvas.calls;
      }

      var calls = draw();
      final ghostImages = [
        for (final c in calls)
          if (c.$2 == skin) c.$4,
      ];
      // The far one at a quarter, the one on the own figure nearly gone.
      expect(ghostImages, hasLength(2));
      expect(ghostImages.reduce((a, b) => a > b ? a : b), closeTo(.25, .01));
      expect(ghostImages.reduce((a, b) => a < b ? a : b), lessThan(.04));
      // Without its figure: the silhouette, as faint.
      final silhouettes = [
        for (final c in calls)
          if (c.$1 == 'path' && c.$4 > 0 && c.$4 <= .26) c,
      ];
      expect(silhouettes, isNotEmpty);
      // Behind the obstacles.
      final lastGhost = calls.lastIndexWhere((c) => c.$2 == skin);
      final firstCrate = calls.indexWhere(
        (c) => c.$2 == atlas && c.$3 == RunnerSprite.crate.rect,
      );
      expect(firstCrate, greaterThan(lastGhost));
      // The names show at the start without a layer; fading, in one.
      expect(calls.where((c) => c.$1 == 'layer'), isEmpty);
      while (game.time < 2.25) {
        game
          ..invincible = true
          ..update(1 / 60);
      }
      calls = draw();
      expect(calls.where((c) => c.$1 == 'layer'), hasLength(1));
      while (game.time < 3) {
        game.update(1 / 60);
      }
      expect(draw().where((c) => c.$1 == 'layer'), isEmpty);
      // After its crash a ghost is gone: only the far one's mark would stay.
      while (game.time < 31) {
        game.update(1 / 20);
      }
      expect(draw().where((c) => c.$2 == skin), isEmpty);
    });
  });
}
