/// Rights an admin can give single member accounts on top of their role
/// (server: `accountPermissions` in theater.mjs). Admins hold all of them.
const eventsPermission = 'events';

/// Label and description of each right, for granting and display.
const accountPermissionLabels = <String, (String, String)>{
  eventsPermission: (
    'Termine verwalten',
    'Termine und Serien anlegen, ändern und löschen, Rückmeldungen und Anwesenheit, Terminfinder',
  ),
};

/// The message shown where a right is missing.
String missingPermissionText(String permission) =>
    'Dafür ist das Recht „${accountPermissionLabels[permission]?.$1 ?? permission}“ nötig.';
