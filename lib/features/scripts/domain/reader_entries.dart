import 'script_document.dart';

/// One row of the reader list: either a scene heading or a cue.
class ReaderEntry {
  const ReaderEntry.scene(this.scene) : cue = null;
  const ReaderEntry.cue(this.cue) : scene = null;
  final ScriptScene? scene;
  final ScriptCue? cue;
}

/// Cues that carry readable content (no scene and role markers).
bool isReadableCue(ScriptCue cue) => cue.kind != 'scene' && cue.kind != 'role';

/// The scene with [sceneId], or a placeholder named after the id.
ScriptScene sceneOf(ScriptDocument document, String sceneId) =>
    document.scenes.where((scene) => scene.id == sceneId).firstOrNull ??
    ScriptScene(id: sceneId, title: 'Szene $sceneId', ordinal: 0);

/// The scene title for [sceneId], never a bare id when the scene is known.
String sceneTitle(ScriptDocument document, String sceneId) =>
    sceneOf(document, sceneId).title;

/// Interleaves scene headings with [cues], which keep their order.
List<ReaderEntry> readerEntries(
  ScriptDocument document,
  Iterable<ScriptCue> cues,
) {
  final entries = <ReaderEntry>[];
  String? previousScene;
  for (final cue in cues) {
    if (cue.sceneId != previousScene) {
      entries.add(ReaderEntry.scene(sceneOf(document, cue.sceneId)));
      previousScene = cue.sceneId;
    }
    entries.add(ReaderEntry.cue(cue));
  }
  return entries;
}

/// A group of cue ids under one scene, in script order.
class SceneGroup {
  const SceneGroup(this.title, this.cues);
  final String title;
  final List<ScriptCue> cues;
}

/// Sorts [cueIds] by their position in the script and groups them by scene.
/// Ids that are missing from this version come back in `orphans`, in their
/// given order.
({List<SceneGroup> groups, List<String> orphans}) groupByScene(
  ScriptDocument? document,
  Iterable<String> cueIds,
) {
  final byId = {for (final cue in document?.cues ?? <ScriptCue>[]) cue.id: cue};
  final found = <ScriptCue>[];
  final orphans = <String>[];
  for (final id in cueIds) {
    final cue = byId[id];
    if (cue == null) {
      orphans.add(id);
    } else {
      found.add(cue);
    }
  }
  found.sort((a, b) => a.ordinal.compareTo(b.ordinal));
  final groups = <SceneGroup>[];
  for (final cue in found) {
    if (groups.isEmpty || groups.last.cues.first.sceneId != cue.sceneId) {
      groups.add(SceneGroup(sceneTitle(document!, cue.sceneId), [cue]));
    } else {
      groups.last.cues.add(cue);
    }
  }
  return (groups: groups, orphans: orphans);
}
