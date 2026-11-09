import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/data/admin_skins_api.dart';
import 'package:theater_app/features/games/domain/stage_runner.dart';
import 'package:theater_app/features/games/ui/admin_skin_scene.dart';
import 'package:theater_app/features/games/ui/admin_skin_viewer.dart';
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/stage_runner_screen.dart';

import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  testWidgets('the admin scene uses each selected skin, on the same course', (
    tester,
  ) async {
    final server = TestServer();
    server.data['capabilities'] = {
      'features': ['stageRunner', 'runnerUnlocks', 'runnerAdminCatalog'],
    };
    final controller = server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    WardrobePictures.clear();
    addTearDown(WardrobePictures.clear);
    const prefix = '/admin/runner/skins/';
    const runner = 'character-theresa.webp',
        background = 'backdrop-sagenhaft.webp',
        obstacles = 'obstacles-sagenhaft.webp',
        pickups = 'collectibles-sagenhaft.webp';
    final catalog = AdminSkinCatalog.fromJson({
      'rarities': [
        {'id': 'blau', 'name': 'Blau', 'color': '#5E98D9', 'weight': 1},
      ],
      'items': [
        {
          'id': 'stage',
          'kind': 'backdrop',
          'name': 'Sagenhaft',
          'image': '$prefix$background',
          'obstacles': '$prefix$obstacles',
          'collectibles': '$prefix$pickups',
          'borderColor': '#16482F',
        },
        {
          'id': 'figure',
          'kind': 'character',
          'name': 'Figur',
          'role': 'Rolle',
          'play': 'Sagenhaft',
          'image': '$prefix$runner',
        },
        {
          'id': 'props',
          'kind': 'obstacles',
          'name': 'Hindernisse',
          'image': '$prefix$obstacles',
        },
        {
          'id': 'fx',
          'kind': 'fx',
          'name': 'Sterne',
          'effect': {
            'trail': 'stars',
            'colors': ['#FFE082'],
          },
        },
        {
          'id': 'missing',
          'kind': 'character',
          'name': 'Noch ohne Bild',
          'admin': {'disabled': true},
        },
      ],
    });
    final base = (await tester.runAsync(() async {
      for (final file in [runner, background, obstacles, pickups]) {
        final path = '$prefix$file';
        WardrobePictures.keepFileForTest(
          path,
          File('server/src/wardrobe/images/$file').readAsBytesSync(),
        );
        expect(await WardrobePictures.load(controller, path), isNotNull);
      }
      return RunnerArt.test(
        await createTestImage(width: 1124, height: 577),
        await createTestImage(width: 64, height: 32),
      );
    }))!;
    for (final skin in catalog.skins) {
      await tester.pumpWidget(
        MaterialApp(
          home: AdminSkinDetailPage(
            key: ValueKey(skin.item.id),
            skin: skin,
            catalog: catalog.catalog,
            controller: controller,
            art: base,
          ),
        ),
      );
      final section = find.byType(AdminSkinScene);
      AdminSkinScene scene() => tester.widget<AdminSkinScene>(section);
      for (var i = 0; i < 50 && scene().loading; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(scene().loading, isFalse);
      if (skin.item.id == 'missing') {
        expect(scene().art, isNull);
        expect(
          find.text('Für diesen Skin ist keine Spielgrafik verfügbar.'),
          findsOneWidget,
        );
        continue;
      }
      final picture = find.descendant(
        of: section,
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is StageRunnerPainter,
        ),
      );
      final painter =
          tester.widget<CustomPaint>(picture).painter! as StageRunnerPainter;
      final game = painter.game();
      expect(
        game.obstacles.map((o) => o.kind).toSet(),
        ObstacleKind.values.toSet(),
      );
      expect(game.pickups.map((o) => o.kind), PickupKind.values);
      final art = scene().art!;
      final stage = skin.item.id == 'stage' || skin.item.id == 'figure';
      expect(
        art.backdrop,
        stage ? WardrobePictures.cached('$prefix$background') : base.backdrop,
      );
      expect(
        art.runnerAtlas,
        skin.item.id == 'figure'
            ? WardrobePictures.cached('$prefix$runner')
            : base.atlas,
      );
      expect(art.ownTruss, stage || skin.item.id == 'props');
      expect(
        art.pickupAtlas,
        stage ? WardrobePictures.cached('$prefix$pickups') : base.atlas,
      );
      if (skin.item.id == 'fx') {
        expect(art.effect?.trail, 'stars');
        expect(painter.trail().life.any((v) => v > 0), isTrue);
        await tester.tap(find.byTooltip('Spielszene vergrößern'));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
        await tester.tap(find.byType(CloseButton));
        await tester.pumpAndSettle();
      }
    }
  });
}
