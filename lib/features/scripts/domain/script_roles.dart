import '../../../core/json.dart';
import 'production.dart';

/// Display names for the selected role [ids], in the order of [roles]. Ids
/// match case-insensitively by id or name; unknown ids keep their spelling.
List<String> roleNames(Iterable<String> ids, List<ScriptRole> roles) {
  final wanted = {for (final id in ids) id.trim().toUpperCase()};
  final names = <String>[];
  for (final role in roles) {
    if (wanted.remove(role.id.toUpperCase()) |
        wanted.remove(role.name.toUpperCase())) {
      names.add(role.name.isEmpty ? role.id : role.name);
    }
  }
  for (final id in ids) {
    if (wanted.contains(id.trim().toUpperCase())) names.add(id.trim());
  }
  return names;
}

/// A short label for the selected roles: the name for one role, otherwise
/// the count ('2 Rollen'). Empty when nothing is selected.
String roleLabel(Iterable<String> ids, List<ScriptRole> roles) {
  final names = roleNames(ids, roles);
  return switch (names.length) {
    0 => '',
    1 => names.single,
    _ => '${names.length} Rollen',
  };
}

/// Ids of the roles the cast list assigns to [personId].
Set<String> assignedRoleIds(List<ScriptRole> roles, int? personId) => {
  if (personId != null)
    for (final role in roles)
      if (role.personId == personId) role.id,
};

/// The roles a production card shows: the reader selection when one is
/// stored, otherwise the roles the cast list assigns to [personId].
List<String> cardRoleNames(
  Production production,
  JsonMap preferences,
  int? personId,
) {
  final prefix = 'reader.${production.id}';
  final selected = {
    ...jsonList(preferences['$prefix.roles']).map((v) => v.toString()),
    if ((preferences['$prefix.role'] as String? ?? '').isNotEmpty)
      preferences['$prefix.role'] as String,
  };
  if (selected.isNotEmpty) return roleNames(selected, production.roles);
  if (preferences['$prefix.assignedRoles'] == false) return const [];
  return roleNames(
    assignedRoleIds(production.roles, personId),
    production.roles,
  );
}
