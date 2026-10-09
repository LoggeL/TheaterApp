import 'models.dart';

/// Casting and team of one production, read from its server record.
///
/// Script roles are cast to one person each; directors and the team
/// (crew and helpers without a script role) are plain person lists. Team
/// members may carry a short free-text function such as "Licht".
class ProductionCast {
  ProductionCast.fromRecord(JsonMap record)
    : id = textValue(record['id']),
      title = textValue(record['title']),
      roles = jsonList(
        record['roles'],
      ).map((e) => ScriptRole.fromJson(jsonMap(e))).toList(),
      casting = {
        for (final entry in jsonMap(record['casting']).entries)
          if (entry.value != null) entry.key: intValue(entry.value),
      },
      directors = jsonList(
        record['directorMemberIds'],
      ).map(intValue).toSet().toList(),
      team = jsonList(record['memberIds']).map(intValue).toSet().toList(),
      functions = {
        for (final entry in jsonMap(record['memberFunctions']).entries)
          if (textValue(entry.value).isNotEmpty)
            int.tryParse(entry.key) ?? -1: textValue(entry.value),
      };

  final String id, title;
  final List<ScriptRole> roles;
  final Map<String, int> casting;
  final List<int> directors, team;
  final Map<int, String> functions;

  int? personFor(String roleId) => casting[roleId];
  bool isCast(String roleId) => casting.containsKey(roleId);
  int get castCount => roles.where((r) => isCast(r.id)).length;

  /// Cast, directors and team; mirrors the server's `productionEnsemble`.
  Set<int> get ensemble => {...casting.values, ...directors, ...team};

  /// The script roles a person plays here.
  List<ScriptRole> rolesOf(int personId) =>
      roles.where((r) => casting[r.id] == personId).toList();

  /// What a person does in this production, e.g. ["Lena", "Regie", "Licht"].
  List<String> dutiesOf(int personId) => [
    ...rolesOf(personId).map((r) => r.name),
    if (directors.contains(personId)) 'Regie',
    if (team.contains(personId)) functions[personId] ?? 'Team',
  ];
}

/// Applies `production.cast` changes to a production record like the server.
JsonMap applyCastChanges(JsonMap record, Iterable<JsonMap> changes) {
  final casting = {
    for (final entry in jsonMap(record['casting']).entries)
      if (entry.value != null) entry.key: intValue(entry.value),
  };
  final directors = jsonList(
    record['directorMemberIds'],
  ).map(intValue).toList();
  final team = jsonList(record['memberIds']).map(intValue).toList();
  final functions = {
    for (final entry in jsonMap(record['memberFunctions']).entries)
      entry.key: textValue(entry.value),
  };
  for (final change in changes) {
    final personId = change['personId'] == null
        ? null
        : intValue(change['personId']);
    final on = change['on'] != false;
    switch (change['kind']) {
      case 'role':
        final roleId = textValue(change['roleId']);
        if (personId == null) {
          casting.remove(roleId);
        } else {
          casting[roleId] = personId;
        }
      case 'director' when personId != null:
        directors.remove(personId);
        if (on) directors.add(personId);
      case 'member' when personId != null:
        if (!on) {
          team.remove(personId);
          functions.remove('$personId');
          break;
        }
        if (!team.contains(personId)) team.add(personId);
        if (change.containsKey('function')) {
          final label = textValue(change['function']).trim();
          if (label.isEmpty) {
            functions.remove('$personId');
          } else {
            functions['$personId'] = label.length > 60
                ? label.substring(0, 60)
                : label;
          }
        }
    }
  }
  functions.removeWhere(
    (key, value) => value.isEmpty || !team.contains(int.tryParse(key)),
  );
  return {
    ...record,
    'casting': casting,
    'directorMemberIds': directors,
    'memberIds': team,
    'memberFunctions': functions,
    'ensemble': {...casting.values, ...directors, ...team}.toList(),
    'version': intValue(record['version'] ?? 1) + 1,
  };
}

/// Lower-case name without accents or punctuation, for matching names.
String normalizeName(String value) {
  const replacements = {
    'ä': 'ae',
    'ö': 'oe',
    'ü': 'ue',
    'ß': 'ss',
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ç': 'c',
    'ñ': 'n',
  };
  final buffer = StringBuffer();
  for (final char in value.toLowerCase().split('')) {
    buffer.write(replacements[char] ?? char);
  }
  return buffer
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r' +'), ' ');
}

List<String> _tokens(String value) {
  final normalized = normalizeName(value);
  return normalized.isEmpty ? const [] : normalized.split(' ');
}

/// Edit distance where swapping two neighbouring letters counts once.
int _distance(String a, String b) {
  final d = List.generate(
    a.length + 1,
    (i) =>
        List<int>.generate(b.length + 1, (j) => i == 0 ? j : (j == 0 ? i : 0)),
  );
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var best = [
        d[i - 1][j] + 1,
        d[i][j - 1] + 1,
        d[i - 1][j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
        best = best < d[i - 2][j - 2] + 1 ? best : d[i - 2][j - 2] + 1;
      }
      d[i][j] = best;
    }
  }
  return d[a.length][b.length];
}

/// Whether a name from the script plausibly means this person: initials
/// ("Alex B."), a single first or last name, or a small typo.
bool _similarName(String scriptName, String personName) {
  final script = _tokens(scriptName), person = _tokens(personName);
  if (script.isEmpty || person.isEmpty) return false;
  final a = script.join(' '), b = person.join(' ');
  if (a == b) return true;
  if (script.length == 1) return person.contains(script.single);
  if (script.length <= person.length &&
      script.every(
        (token) => person.any(
          (part) => part == token || (token.length == 1 && part[0] == token),
        ),
      ) &&
      person.contains(script.first)) {
    return true;
  }
  final allowed = a.length >= 12 ? 2 : (a.length >= 6 ? 1 : 0);
  return allowed > 0 && _distance(a, b) <= allowed;
}

/// Spoken lines per script role, counted from the dialogue cues.
Map<String, int> roleLineCounts(ScriptDocument? script) {
  final counts = <String, int>{};
  if (script == null) return counts;
  for (final cue in script.cues) {
    if (cue.kind != 'dialogue' || cue.role.isEmpty) continue;
    final key = normalizeName(cue.role);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

int linesOf(ScriptRole role, Map<String, int> counts) {
  final byId = counts[normalizeName(role.id)] ?? 0;
  final byName = counts[normalizeName(role.name)] ?? 0;
  return byId > byName ? byId : byName;
}

/// Most lines first when the script is known, otherwise alphabetical.
List<ScriptRole> rolesByImportance(
  List<ScriptRole> roles,
  Map<String, int> counts,
) => [...roles]
  ..sort((left, right) {
    final lines = linesOf(right, counts).compareTo(linesOf(left, counts));
    if (lines != 0) return lines;
    final name = normalizeName(left.name).compareTo(normalizeName(right.name));
    return name != 0 ? name : left.id.compareTo(right.id);
  });

/// A proposed person for an open role, with a reason people can check.
class CastingSuggestion {
  const CastingSuggestion({
    required this.role,
    required this.personId,
    required this.reason,
  });
  final ScriptRole role;
  final int personId;
  final String reason;
}

/// Deterministic proposals for the open roles of [cast], in role order:
///
/// 1. the script names the person as actor,
/// 2. the role carries the person's full name,
/// 3. the person played a role of the same name in another production
///    (newest first, as [others] is ordered),
/// 4. the script's actor name is similar to exactly one person,
/// 5. the role name is the first name of exactly one person.
///
/// Only active people are proposed; ambiguous matches propose nobody.
List<CastingSuggestion> castingSuggestions(
  ProductionCast cast,
  List<TheaterMember> members,
  List<ProductionCast> others, {
  List<ScriptRole>? order,
}) {
  final active = members.where((m) => m.active).toList();
  TheaterMember? unique(bool Function(TheaterMember) test) {
    final matches = active.where(test).toList();
    return matches.length == 1 ? matches.single : null;
  }

  final suggestions = <CastingSuggestion>[];
  for (final role in order ?? cast.roles) {
    if (cast.isCast(role.id)) continue;
    final actor = normalizeName(role.actor), name = normalizeName(role.name);
    CastingSuggestion? suggest(TheaterMember? person, String reason) =>
        person == null
        ? null
        : CastingSuggestion(role: role, personId: person.id, reason: reason);
    CastingSuggestion? previous() {
      if (name.isEmpty) return null;
      for (final other in others) {
        if (other.id == cast.id) continue;
        for (final earlier in other.roles) {
          if (normalizeName(earlier.name) != name) continue;
          final personId = other.personFor(earlier.id);
          final person = active.where((m) => m.id == personId).firstOrNull;
          if (person != null) {
            return suggest(person, 'spielte die Rolle in „${other.title}“');
          }
        }
      }
      return null;
    }

    final suggestion =
        (actor.isEmpty
            ? null
            : suggest(
                unique((m) => normalizeName(m.name) == actor),
                'im Drehbuch als Darsteller:in genannt',
              )) ??
        (name.isEmpty
            ? null
            : suggest(
                unique((m) => normalizeName(m.name) == name),
                'gleicher Name wie die Rolle',
              )) ??
        previous() ??
        (actor.isEmpty
            ? null
            : suggest(
                unique((m) => _similarName(role.actor, m.name)),
                'ähnlicher Name im Drehbuch: „${role.actor}“',
              )) ??
        (name.isEmpty || name.contains(' ')
            ? null
            : suggest(
                unique((m) => _tokens(m.name).firstOrNull == name),
                'Rollenname wie der Vorname',
              ));
    if (suggestion != null) suggestions.add(suggestion);
  }
  return suggestions;
}

/// Where a person is involved, e.g. for the person editor.
class ProductionCredit {
  const ProductionCredit({required this.production, required this.duties});
  final ProductionCast production;
  final List<String> duties;
}

List<ProductionCredit> creditsOf(
  Iterable<ProductionCast> productions,
  int personId,
) => [
  for (final production in productions)
    if (production.ensemble.contains(personId))
      ProductionCredit(
        production: production,
        duties: production.dutiesOf(personId),
      ),
];
