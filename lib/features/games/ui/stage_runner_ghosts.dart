import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../core/app_controller.dart';
import '../domain/runner_ghost.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';

/// The figures the ghosts of a run were run in (`runnerGhostFigures`),
/// through the wardrobe's own picture cache ([WardrobePictures]): a figure
/// someone wears or another ghost brought is there at once. A ghost is
/// drawn as a silhouette until its figure has loaded, and for good when it
/// does not load, does not have the size of the game's atlas or is beyond
/// [budget].
///
/// The figures are whole atlases (about 2.5 MB decoded each), so an app
/// session loads at most [budget] distinct ones for ghosts; those already
/// decoded for something else do not count.
class GhostSkins {
  GhostSkins(this.controller, {this.onLoaded});
  final AppController controller;

  /// Called when a figure has loaded, to repaint a paused stage.
  final VoidCallback? onLoaded;

  /// Distinct figures ghosts may load in an app session.
  @visibleForTesting
  static int budget = kIsWeb ? 6 : 10;

  /// The pictures loaded for ghosts in this app session.
  static final _asked = <String>{};

  @visibleForTesting
  static int get asked => _asked.length;

  @visibleForTesting
  static void reset() => _asked.clear();

  final _images = <String, ui.Image>{};
  final _pending = <String>{};
  bool _disposed = false;

  /// The ghosts asked for before there was art, for [artReady].
  List<RunnerGhost>? _waiting;

  /// Starts loading the figures of [ghosts], in this order, for the art
  /// [base]. Without art yet (the stage draws plain shapes) they wait for
  /// [artReady].
  void want(Iterable<RunnerGhost> ghosts, RunnerArt? base) {
    if (_disposed) return;
    if (base == null) {
      (_waiting ??= []).addAll(ghosts);
      return;
    }
    bool fits(ui.Image image) =>
        image.width == base.atlas.width && image.height == base.atlas.height;
    for (final ghost in ghosts) {
      final path = ghost.figure?.image;
      if (path == null ||
          _images.containsKey(path) ||
          _pending.contains(path)) {
        continue;
      }
      final kept = WardrobePictures.cached(path);
      if (kept != null) {
        if (fits(kept)) _images[path] = kept;
        continue;
      }
      if (!_asked.contains(path)) {
        if (_asked.length >= budget) continue;
        _asked.add(path);
      }
      _pending.add(path);
      WardrobePictures.load(controller, path).then((image) {
        _pending.remove(path);
        if (_disposed || image == null || !fits(image)) return;
        _images[path] = image;
        onLoaded?.call();
      });
    }
  }

  /// The game's art arrived (or changed): loads what was asked for without
  /// art. Nothing if nothing waits.
  void artReady(RunnerArt? base) {
    final waiting = _waiting;
    if (base == null || waiting == null) return;
    _waiting = null;
    want(waiting, base);
  }

  /// [image] as the loaded figure at [path], for tests.
  @visibleForTesting
  void keepForTest(String path, ui.Image image) => _images[path] = image;

  /// The atlas to draw [ghost] from: the game's own ([base]) for the
  /// default figure, its figure's once loaded, else null (a silhouette).
  ui.Image? of(RunnerGhost ghost, RunnerArt base) {
    final figure = ghost.figure;
    if (figure == null) return null;
    if (figure.isDefault) return base.atlas;
    final path = figure.image;
    return path == null ? null : _images[path];
  }

  void dispose() {
    _disposed = true;
    _waiting = null;
    _images.clear();
  }
}
