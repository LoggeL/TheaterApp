import '../../../core/models.dart';
import 'cue_category.dart';

/// Pure view derivation: context stays in its scene and canonical order is kept.
/// The original document is never altered by display preferences.
List<ScriptCue> visibleScriptCues(
  ScriptDocument document, {
  String role = '',
  Set<String> roles = const {},
  String mode = 'read',
  int contextLines = 2,
  bool showDirections = true,
  bool showTechnical = true,
  bool technicalFullText = false,
  Set<String>? categories,
  Map<String, int> categoryContext = const {},
}) {
  final all = document.cues;
  final selected = {
    ...roles,
    if (role.isNotEmpty) role,
  }.map((r) => r.trim().toUpperCase()).toSet();
  final included = <int>{};
  final actor = mode == 'actor' && selected.isNotEmpty;
  final technicalOnly = mode == 'technical' && !technicalFullText;
  void includeContext(int index, int count) {
    final start = (index - count).clamp(0, all.length),
        end = (index + count + 1).clamp(0, all.length);
    for (var neighbor = start; neighbor < end; neighbor++) {
      if (all[neighbor].sceneId == all[index].sceneId) included.add(neighbor);
    }
  }

  for (var index = 0; index < all.length; index++) {
    final cue = all[index], key = cueCategory(all[index]);
    if (actor &&
        cue.kind == 'dialogue' &&
        selected.contains(cue.role.trim().toUpperCase())) {
      includeContext(index, contextLines);
    }
    if (technicalOnly &&
        (isTechnicalCue(cue) || cue.kind == 'direction') &&
        (categories == null || categories.contains(key))) {
      includeContext(index, categoryContext[key] ?? 0);
    }
  }
  return [
    for (var index = 0; index < all.length; index++)
      if ((!actor && !technicalOnly || included.contains(index)) &&
          (showDirections || all[index].kind != 'direction') &&
          (showTechnical || !isTechnicalCue(all[index])) &&
          (categories == null ||
              all[index].kind == 'dialogue' ||
              categories.contains(cueCategory(all[index]))) &&
          all[index].kind != 'scene' &&
          all[index].kind != 'role')
        all[index],
  ];
}

/// Technical cues: technique, light, sound, props and microphones.
bool isTechnicalCue(ScriptCue cue) => cue.isTechnical;
