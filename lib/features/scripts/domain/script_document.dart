import '../../../core/json.dart';
import 'production.dart';

class ScriptScene {
  const ScriptScene({
    required this.id,
    required this.title,
    required this.ordinal,
    this.roles = const [],
  });
  final String id, title;
  final int ordinal;
  final List<String> roles;
  factory ScriptScene.fromJson(JsonMap json) => ScriptScene(
    id: textValue(json['id']),
    title: textValue(json['title']),
    ordinal: intValue(json['ordinal']),
    roles: jsonList(json['roles']).map((e) => e.toString()).toList(),
  );
  JsonMap toJson() => {
    'id': id,
    'title': title,
    'ordinal': ordinal,
    'roles': roles,
  };
}

class ScriptCue {
  const ScriptCue({
    required this.id,
    required this.sceneId,
    required this.ordinal,
    required this.kind,
    required this.text,
    this.role = '',
    this._roles,
    this.microphone = '',
    this.isAutoMic = false,
    this.micCueType = '',
  });
  final String id, sceneId, kind, text, microphone, micCueType;

  /// The speaker label, e.g. 'ROMEO' or 'ROMEO & JULIA' for a shared cue.
  final String role;

  /// Every role speaking this cue; several for lines spoken together. Older
  /// servers only send [role], which then is the single speaker.
  List<String> get roles => _roles ?? (role.isEmpty ? const [] : [role]);
  final List<String>? _roles;
  final int ordinal;
  final bool isAutoMic;
  String get category => kind;

  /// Whether one of [roleIds] speaks this cue (case-insensitive).
  bool spokenByAny(Iterable<String> roleIds) {
    if (roleIds.isEmpty) return false;
    final wanted = {for (final id in roleIds) id.trim().toUpperCase()};
    return spokenByNormalized(wanted);
  }

  /// Faster variant of [spokenByAny] when [upperRoleIds] are already trimmed
  /// and upper-cased.
  bool spokenByNormalized(Set<String> upperRoleIds) {
    if (upperRoleIds.isEmpty) return false;
    final list = _roles;
    if (list == null) {
      return role.isNotEmpty && upperRoleIds.contains(role.trim().toUpperCase());
    }
    for (final r in list) {
      if (upperRoleIds.contains(r.trim().toUpperCase())) return true;
    }
    return false;
  }

  bool get isTechnical => const {
    'technical',
    'lighting',
    'audio',
    'props',
    'microphone',
  }.contains(kind);
  factory ScriptCue.fromJson(JsonMap json) => ScriptCue(
    id: textValue(json['id'] ?? json['cueId']),
    sceneId: textValue(json['sceneId']),
    ordinal: intValue(json['ordinal'] ?? json['cueOrdinal']),
    kind: textValue(json['category'] ?? json['kind'], 'unknown'),
    text: textValue(json['text']),
    role: textValue(json['role']),
    roles: _speakers(json['roles']),
    microphone: textValue(json['microphone']),
    isAutoMic: json['isAutoMic'] == true,
    micCueType: textValue(json['micCueType']),
  );
  static List<String>? _speakers(Object? value) {
    final roles = [
      for (final role in jsonList(value))
        if (role.toString().trim().isNotEmpty) role.toString().trim(),
    ];
    return roles.isEmpty ? null : roles;
  }

  JsonMap toJson() => {
    'id': id,
    'sceneId': sceneId,
    'ordinal': ordinal,
    'category': kind,
    'role': role,
    'roles': roles,
    'text': text,
    'microphone': microphone,
    'isAutoMic': isAutoMic,
    'micCueType': micCueType,
  };
}

class ScriptDocument {
  const ScriptDocument({
    required this.productionId,
    required this.revision,
    required this.scenes,
    required this.roles,
    required this.cues,
    this.fetchedAt,
    this.stale = false,
  });
  final String productionId, revision;
  final List<ScriptScene> scenes;
  final List<ScriptRole> roles;
  final List<ScriptCue> cues;
  final DateTime? fetchedAt;
  final bool stale;
  factory ScriptDocument.fromJson(JsonMap json) {
    final cues = [
      for (final e in jsonList(json['cues'])) ScriptCue.fromJson(readJsonMap(e)),
    ]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    // Collect dialogue speakers per scene in one pass for scenes whose JSON
    // does not list roles explicitly.
    Map<String, Set<String>>? sceneSpeakers;
    List<String> inferredRoles(String sceneId) {
      if (sceneSpeakers == null) {
        sceneSpeakers = <String, Set<String>>{};
        for (final c in cues) {
          if (c.kind != 'dialogue' || c.roles.isEmpty) continue;
          (sceneSpeakers![c.sceneId] ??= <String>{}).addAll(c.roles);
        }
      }
      final set = sceneSpeakers![sceneId];
      return set == null ? const [] : set.toList();
    }

    final scenes = [
      for (final e in jsonList(json['scenes']))
        () {
          final scene = ScriptScene.fromJson(readJsonMap(e));
          return scene.roles.isNotEmpty
              ? scene
              : ScriptScene(
                  id: scene.id,
                  title: scene.title,
                  ordinal: scene.ordinal,
                  roles: inferredRoles(scene.id),
                );
        }(),
    ]..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final cache = readJsonMap(json['cache']);
    return ScriptDocument(
      productionId: textValue(json['productionId']),
      revision: textValue(json['revision']),
      cues: cues,
      scenes: scenes,
      roles: [
        for (final e in jsonList(json['roles']))
          ScriptRole.fromJson(readJsonMap(e)),
      ],
      fetchedAt: dateValue(cache['fetchedAt']),
      stale: cache['stale'] == true,
    );
  }
  List<ScriptCue> cuesForScene(String sceneId) =>
      cues.where((e) => e.sceneId == sceneId).toList();
  JsonMap toJson() => {
    'productionId': productionId,
    'revision': revision,
    'scenes': scenes.map((e) => e.toJson()).toList(),
    'roles': roles.map((e) => e.toJson()).toList(),
    'cues': cues.map((e) => e.toJson()).toList(),
    'cache': {'fetchedAt': fetchedAt?.toIso8601String(), 'stale': stale},
  };
}
