import 'package:flutter/foundation.dart';

import '../../../core/app_controller.dart';
import '../data/wardrobe_api.dart';

/// The music of the backdrops from the server, loaded once per session. Only
/// the worn backdrop's is loaded; a failure (offline, an older server) leaves
/// the game's own tune in its place and is tried again next time.
abstract final class RunnerTunes {
  static final _tunes = <String, Uint8List>{};
  static final _loading = <String, Future<Uint8List?>>{};

  /// The API path of the worn backdrop's music in [wardrobe]; null for the
  /// game's own tune (no wardrobe, a backdrop without music, older servers).
  static String? of(Wardrobe? wardrobe) =>
      wardrobe?.worn(WardrobeKind.backdrop)?.music;

  /// Already loaded, without waiting.
  static Uint8List? cached(String? path) => path == null ? null : _tunes[path];

  static Future<Uint8List?> load(AppController controller, String? path) {
    if (path == null) return Future.value();
    final done = _tunes[path];
    if (done != null) return Future.value(done);
    // A block body, as with the pictures: an arrow would hand whenComplete
    // the removed future, which is this very one.
    return _loading[path] ??= _fetch(controller, path).whenComplete(() {
      _loading.remove(path);
    });
  }

  static Future<Uint8List?> _fetch(
    AppController controller,
    String path,
  ) async {
    try {
      final media = await controller.mediaBytes(path, cache: false);
      // About a megabyte each: a few are kept for switching back and forth.
      if (_tunes.length >= 3) _tunes.remove(_tunes.keys.first);
      return _tunes[path] = media.bytes;
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Musik $path fehlt: $e');
      return null;
    }
  }

  @visibleForTesting
  static void clear() {
    _tunes.clear();
    _loading.clear();
  }
}
