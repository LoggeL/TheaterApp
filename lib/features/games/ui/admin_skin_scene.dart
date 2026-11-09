import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../data/admin_skins_api.dart';
import '../domain/stage_runner.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';
import 'stage_runner_screen.dart' show StageRunnerPainter, stagePainterFor;

/// A still from the actual stage, with the same course for each skin.
class AdminSkinScene extends StatelessWidget {
  const AdminSkinScene({
    super.key,
    required this.name,
    required this.art,
    required this.loading,
    required this.controller,
  });

  final String name;
  final RunnerArt? art;
  final bool loading;
  final AppController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => adminSkinsAvailable(controller)
        ? _panel(context)
        : const SizedBox.shrink(),
  );

  Widget _panel(BuildContext context) {
    final look = art;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Spielszene',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (look != null)
              IconButton(
                tooltip: 'Spielszene vergrößern',
                icon: const Icon(Icons.fullscreen),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => Dialog.fullscreen(
                    child: Scaffold(
                      appBar: AppBar(
                        title: Text(name),
                        leading: const CloseButton(),
                      ),
                      body: ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => adminSkinsAvailable(controller)
                            ? InteractiveViewer(
                                maxScale: 4,
                                child: Center(child: _Frame(art: look)),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (look != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Semantics(
              image: true,
              label: 'Spielszene mit $name',
              child: _Frame(art: look),
            ),
          )
        else if (loading)
          const LinearProgressIndicator()
        else
          const Text('Für diesen Skin ist keine Spielgrafik verfügbar.'),
      ],
    );
  }
}

class _Frame extends StatefulWidget {
  const _Frame({required this.art});
  final RunnerArt art;

  @override
  State<_Frame> createState() => _FrameState();
}

class _FrameState extends State<_Frame> {
  static const aspect = 2.45;
  late final game = _previewCourse();
  StageRunnerPainter? _painter;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_painter?.pixelRatio != MediaQuery.devicePixelRatioOf(context)) {
      _prepare();
    }
  }

  @override
  void didUpdateWidget(_Frame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.art != widget.art) _prepare();
  }

  void _prepare() {
    _painter?.dispose();
    final trail = RunnerTrail(random: Random(1));
    // Leave enough particles behind the flying figure for a still of an FX skin.
    if (widget.art.effect != null) {
      for (var i = 0; i < 24; i++) {
        trail.update(1 / 30, game, widget.art.effect);
      }
    }
    _painter = stagePainterFor(
      game,
      widget.art,
      trail: trail,
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
  }

  @override
  void dispose() {
    _painter?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: aspect,
    child: RepaintBoundary(
      child: CustomPaint(key: ObjectKey(_painter), painter: _painter),
    ),
  );
}

StageRunner _previewCourse() {
  final game = StageRunner(seed: 1)..y = .59;
  const floor = StageRunner.floor;
  Obstacle prop(
    ObstacleKind kind,
    double x,
    double width,
    double top,
    double bottom,
  ) => Obstacle()
    ..kind = kind
    ..left = x
    ..width = width
    ..top = top
    ..bottom = bottom;
  game.obstacles
    ..clear()
    ..addAll([
      prop(ObstacleKind.lamp, .18, .08, 0, .35),
      prop(ObstacleKind.crate, .61, .14, floor - .135, floor),
      prop(ObstacleKind.sandbag, .56, .09, 0, .29),
      prop(ObstacleKind.drop, 1.08, .16, 0, .45),
      prop(ObstacleKind.drum, 1.27, .12, floor - .12, floor),
      prop(ObstacleKind.border, 1.65, .13, 0, .29)
        ..gap = true
        ..anchor = .62,
      prop(ObstacleKind.flat, 1.65, .13, .62, floor)..gap = true,
      prop(ObstacleKind.pile, 2.04, .22, floor - .124, floor),
      prop(ObstacleKind.pile, 2.095, .11, floor - .248, floor - .124),
      prop(ObstacleKind.truss, 2.01, .30, 0, .34),
    ]);
  game.pickups
    ..clear()
    ..addAll([
      for (final kind in PickupKind.values)
        Pickup()
          ..kind = kind
          ..x = .56 + kind.index * .2
          ..y = .55 - kind.index * .051,
    ]);
  return game;
}
