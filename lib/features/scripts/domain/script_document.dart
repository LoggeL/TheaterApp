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
    final wanted = {for (final id in roleIds) id.trim().toUpperCase()};
    return roles.any((r) => wanted.contains(r.trim().toUpperCase()));
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
    final cues =
        jsonList(
            json['cues'],
          ).map((e) => ScriptCue.fromJson(jsonMap(e))).toList()
          ..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final scenes = jsonList(json['scenes']).map((e) {
      final scene = ScriptScene.fromJson(jsonMap(e));
      return ScriptScene(
        id: scene.id,
        title: scene.title,
        ordinal: scene.ordinal,
        roles: scene.roles.isNotEmpty
            ? scene.roles
            : cues
                  .where(
                    (c) =>
                        c.sceneId == scene.id &&
                        c.kind == 'dialogue' &&
                        c.roles.isNotEmpty,
                  )
                  .expand((c) => c.roles)
                  .toSet()
                  .toList(),
      );
    }).toList()..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    return ScriptDocument(
      productionId: textValue(json['productionId']),
      revision: textValue(json['revision']),
      cues: cues,
      scenes: scenes,
      roles: jsonList(
        json['roles'],
      ).map((e) => ScriptRole.fromJson(jsonMap(e))).toList(),
      fetchedAt: dateValue(jsonMap(json['cache'])['fetchedAt']),
      stale: jsonMap(json['cache'])['stale'] == true,
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
