import '../../../core/json.dart';
import '../domain/line_learning.dart';
import '../domain/production.dart';
import '../domain/script_roles.dart';
import 'reader_preferences.dart';

/// The line-learning settings and progress stored per production under
/// `learn.<id>.<name>` in the local app preferences; they never leave the
/// device.
class LearnPreferences {
  LearnPreferences._({
    required this.roles,
    required this.scenes,
    required this.order,
    required this.skipMastered,
    required this.groups,
    required this.directions,
    required this.progress,
  });

  /// Reads the settings of [productionId]. Without a stored choice the roles
  /// are the ones the cast list assigns to [personId], else the roles chosen
  /// in the reader.
  factory LearnPreferences.read(
    JsonMap preferences,
    String productionId, {
    List<ScriptRole> roles = const [],
    int? personId,
  }) {
    Object? value(String name) => preferences[key(productionId, name)];
    final stored = jsonList(value('roles')).map((v) => v.toString()).toSet();
    final assigned = assignedRoleIds(roles, personId);
    return LearnPreferences._(
      roles: stored.isNotEmpty
          ? stored
          : assigned.isNotEmpty
          ? assigned
          : ReaderPreferences.read(preferences, productionId).roles,
      scenes: preferences.containsKey(key(productionId, 'scenes'))
          ? jsonList(value('scenes')).map((v) => v.toString()).toSet()
          : null,
      order: LearnOrder.fromCode(value('order')),
      skipMastered: value('skipMastered') == true,
      groups: value('groups') != false,
      directions: value('directions') != false,
      progress: LearnProgress.fromJson(value('progress')),
    );
  }

  /// The full preference key for [name] of [productionId].
  static String key(String productionId, String name) =>
      'learn.$productionId.$name';

  final Set<String> roles;

  /// The chosen scene ids; null for all scenes.
  final Set<String>? scenes;
  final LearnOrder order;
  final bool skipMastered, groups, directions;
  final LearnProgress progress;
}
