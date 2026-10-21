import '../../../core/json.dart';

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.mustChangePassword = false,
    this.directorProductionIds = const [],
    this.status = 'approved',
    this.personId,
    this.emailVerified = true,
    this.identityReady = true,
    this.needsRegistrationName = false,
    this.avatarId,
    this.roleIds = const [],
    this.profileVersion = 0,
    this.permissions = const [],
  });
  final String id, name, email, role;
  final bool mustChangePassword;
  final List<String> directorProductionIds;
  final String status;
  final int? personId;
  final bool emailVerified, identityReady;
  final bool needsRegistrationName;
  final String? avatarId;
  final List<String> roleIds;
  final int profileVersion;

  /// Rights on top of the role, e.g. `events` ("Termine verwalten"); the
  /// server lists all of them for admins. See core/account_permissions.dart.
  final List<String> permissions;
  bool get isApproved => status == 'approved' && identityReady;
  bool get isAdmin => role == 'admin';

  /// Admins hold every right.
  bool can(String permission) => isAdmin || permissions.contains(permission);

  /// Planning and running all events, series and Terminfinder.
  bool get canManageEvents => can('events');
  String get firstName => name.trim().split(' ').first;
  String get initials => name
      .trim()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .take(2)
      .map((e) => e[0])
      .join()
      .toUpperCase();
  factory AppUser.fromJson(JsonMap json) => AppUser(
    id: textValue(json['userId'] ?? json['id']),
    name: textValue(json['displayName'] ?? json['name']),
    email: textValue(json['email']),
    role: textValue(json['role'], 'member'),
    status: textValue(json['status'], 'approved'),
    personId: json['personId'] == null ? null : intValue(json['personId']),
    emailVerified: json['emailVerified'] != false,
    identityReady: json['identityReady'] != false,
    needsRegistrationName: json['needsRegistrationName'] == true,
    avatarId: json['avatarId'] as String?,
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
    profileVersion: intValue(json['profileVersion']),
    permissions: jsonList(
      json['permissions'],
    ).map((e) => e.toString()).toList(),
    mustChangePassword: json['mustChangePassword'] == true,
    directorProductionIds: jsonList(
      json['directorProductionIds'],
    ).map((e) => e.toString()).toList(),
  );
  JsonMap toJson() => {
    'userId': id,
    'displayName': name,
    'email': email,
    'role': role,
    'status': status,
    'personId': personId,
    'emailVerified': emailVerified,
    'identityReady': identityReady,
    'needsRegistrationName': needsRegistrationName,
    'avatarId': avatarId,
    'roleIds': roleIds,
    'profileVersion': profileVersion,
    'permissions': permissions,
    'mustChangePassword': mustChangePassword,
    'directorProductionIds': directorProductionIds,
  };
}
