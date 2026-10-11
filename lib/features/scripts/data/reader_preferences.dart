import '../../../core/json.dart';
import '../domain/reader_mode.dart';

/// The reader settings stored per production under `reader.<id>.<name>`.
/// The keys and value formats are persisted on existing installs and must
/// stay unchanged.
class ReaderPreferences {
  ReaderPreferences._({
    required this.role,
    required this.roles,
    required this.assignedRoles,
    required this.notes,
    required this.categories,
    required this.categoryContext,
    required this.mode,
    required this.fontScale,
    required this.contextLines,
    required this.showDirections,
    required this.showTechnical,
    required this.bookmarks,
    required this.lastCueId,
  });

  /// Reads the settings of [productionId] from the app [preferences].
  factory ReaderPreferences.read(JsonMap preferences, String productionId) {
    Object? value(String name) => preferences[key(productionId, name)];
    final role = value('role') as String? ?? '';
    final roles = jsonList(value('roles')).map((v) => v.toString()).toSet();
    if (roles.isEmpty && role.isNotEmpty) roles.add(role);
    return ReaderPreferences._(
      role: role,
      roles: roles,
      assignedRoles: preferences.containsKey(key(productionId, 'assignedRoles'))
          ? value('assignedRoles') == true
          : roles.isEmpty,
      notes: jsonMap(value('notes')),
      categories: preferences.containsKey(key(productionId, 'categories'))
          ? jsonList(value('categories')).map((v) => v.toString()).toSet()
          : {'direction'},
      categoryContext: jsonMap(
        value('categoryContext'),
      ).map((k, v) => MapEntry(k, intValue(v))),
      mode: ReaderMode.fromCode(
        value('mode') as String? ??
            (value('actorMode') == true ? 'actor' : 'read'),
      ),
      fontScale: ((value('fontScale') as num?)?.toDouble() ?? 1).clamp(
        0.85,
        1.6,
      ),
      contextLines: ((value('contextLines') as num?)?.toInt() ?? 2).clamp(0, 6),
      showDirections: value('showDirections') != false,
      showTechnical: value('showTechnical') == true,
      bookmarks: (value('bookmarks') as List? ?? [])
          .whereType<String>()
          .toSet(),
      lastCueId: value('lastCueId') as String?,
    );
  }

  /// The full preference key for [name] of [productionId].
  static String key(String productionId, String name) =>
      'reader.$productionId.$name';

  /// Set once the member dismissed the hint about cue actions (all scripts).
  static const hintCueActionsKey = 'reader.hintCueActions';

  final String role;
  final Set<String> roles;
  final bool assignedRoles;
  final JsonMap notes;
  final Set<String> categories;
  final Map<String, int> categoryContext;
  final ReaderMode mode;
  final double fontScale;
  final int contextLines;
  final bool showDirections, showTechnical;
  final Set<String> bookmarks;
  final String? lastCueId;
}
