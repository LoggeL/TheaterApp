import '../../../core/json.dart';
import 'script_document.dart';

class ScriptRole {
  const ScriptRole({
    required this.id,
    required this.name,
    this.actor = '',
    this.personId,
  });
  final String id, name, actor;
  final int? personId;
  factory ScriptRole.fromJson(JsonMap json) => ScriptRole(
    id: textValue(json['id']),
    name: textValue(json['name']),
    actor: textValue(json['actor']),
    personId: json['personId'] == null ? null : intValue(json['personId']),
  );
  JsonMap toJson() => {
    'id': id,
    'name': name,
    'actor': actor,
    'personId': personId,
  };
}

class Production {
  const Production({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.revision = '',
    this.roles = const [],
    this.sceneCount = 0,
    this.premiereAt,
    this.createdAt,
    this.archived = false,
    this.version = 1,
    this.ensemble = const [],
  });
  final String id, title, subtitle, revision;
  final List<ScriptRole> roles;
  final int sceneCount;
  final DateTime? premiereAt, createdAt;
  final bool archived;
  final int version;

  /// Cast, directors and crew added by hand; computed by the server.
  final List<int> ensemble;

  /// When the production ran, as far as known: the premiere, else the
  /// season in the title or id ("Winterstück 2026" is December 2026).
  /// Null when neither says anything; mirrors `productionSeasonTime` on
  /// the server.
  DateTime? get seasonDate {
    if (premiereAt != null) return premiereAt!.toUtc();
    final label = '$title $id'.toLowerCase();
    final years = RegExp(
      r'(?:^|\D)((?:19|20)\d{2})(?=\D|$)',
    ).allMatches(label).map((match) => int.parse(match.group(1)!)).toList();
    if (years.isNotEmpty) {
      years.sort();
      final month = label.contains('winter')
          ? 12
          : label.contains('sommer')
          ? 7
          : 1;
      return DateTime.utc(years.last, month);
    }
    return null;
  }

  DateTime get sortDate =>
      seasonDate ??
      createdAt?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  static int compareNewestFirst(Production left, Production right) {
    final chronology = right.sortDate.compareTo(left.sortDate);
    if (chronology != 0) return chronology;
    final titleOrder = right.title.toLowerCase().compareTo(
      left.title.toLowerCase(),
    );
    return titleOrder != 0 ? titleOrder : left.id.compareTo(right.id);
  }

  factory Production.fromJson(JsonMap json) => Production(
    id: textValue(json['id']),
    title: textValue(json['title'] ?? json['name']),
    subtitle: textValue(json['subtitle']),
    revision: textValue(json['revision']),
    sceneCount: intValue(json['sceneCount']),
    premiereAt: dateValue(json['premiereAt']),
    createdAt: dateValue(json['createdAt']),
    archived: json['archived'] == true,
    version: intValue(json['version'] ?? 1),
    ensemble: jsonList(json['ensemble']).map(intValue).toList(),
    roles: jsonList(
      json['roles'],
    ).map((e) => ScriptRole.fromJson(jsonMap(e))).toList(),
  );
  Production withScript(ScriptDocument doc) => Production(
    id: id,
    title: title,
    subtitle: subtitle,
    revision: doc.revision,
    roles: doc.roles,
    sceneCount: doc.scenes.length,
    premiereAt: premiereAt,
    createdAt: createdAt,
    archived: archived,
    version: version,
    ensemble: ensemble,
  );
  JsonMap toJson() => {
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'revision': revision,
    'roles': roles.map((e) => e.toJson()).toList(),
    'sceneCount': sceneCount,
    'premiereAt': premiereAt?.toUtc().toIso8601String(),
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'archived': archived,
    'version': version,
    'ensemble': ensemble,
  };
}
