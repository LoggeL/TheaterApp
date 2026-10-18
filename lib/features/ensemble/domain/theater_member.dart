import '../../../core/json.dart';

class TheaterMember {
  const TheaterMember({
    required this.id,
    required this.name,
    this.initials = '',
    this.avatar,
    this.avatarId,
    this.roleIds = const [],
    this.active = true,
    this.about = '',
    this.websiteHidden = false,
  });
  final int id;
  final String name, initials;
  final String? avatar, avatarId;
  final List<String> roleIds;
  final bool active;

  /// Self-written "Über mich" text, visible to the ensemble.
  final String about;

  /// The person hid the imported website data (photo, roles) in the app.
  final bool websiteHidden;

  /// Whether this member belongs to an audience of roles, invited people or
  /// production ensembles (one list per production); nothing chosen = everyone.
  bool inAudience(
    List<String> audience, [
    List<int> people = const [],
    List<List<int>> ensembles = const [],
  ]) =>
      (audience.isEmpty && people.isEmpty && ensembles.isEmpty) ||
      audience.any(roleIds.contains) ||
      people.contains(id) ||
      ensembles.any((ensemble) => ensemble.contains(id));
  factory TheaterMember.fromJson(JsonMap json) => TheaterMember(
    id: intValue(json['id']),
    name: textValue(json['name']),
    initials: textValue(json['initials']),
    avatar: json['avatar'] as String?,
    avatarId: json['avatarId'] as String?,
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
    active: json['active'] != false,
    about: textValue(json['about']),
    websiteHidden: json['websiteHidden'] == true,
  );
  JsonMap toJson() => {
    'id': id,
    'name': name,
    'initials': initials,
    'avatar': avatar,
    'avatarId': avatarId,
    'roleIds': roleIds,
    'active': active,
    'about': about,
    'websiteHidden': websiteHidden,
  };
}
