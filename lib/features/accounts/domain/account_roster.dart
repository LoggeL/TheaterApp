import '../../../core/account_permissions.dart';
import '../../../core/models.dart';

/// One row of the access overview: a person with their linked account (or
/// none), or an account that belongs to no person yet.
class AccessEntry {
  const AccessEntry({this.member, this.account})
    : assert(member != null || account != null);
  final JsonMap? member, account;

  int? get personId => member == null ? null : intValue(member!['id']);
  String get uid => textValue(account?['uid']);

  /// Stable widget key part: the person id, else the account uid.
  String get key => member != null ? '${member!['id']}' : uid;
  String get name => member != null
      ? textValue(member!['name'])
      : textValue(account!['name'], textValue(account!['email'], 'Konto'));

  /// The person is switched off; independent of the account status.
  bool get inactive => member?['active'] == false;

  /// An account that belongs to no person, whatever its status.
  bool get unassigned => member == null;
}

/// What an entry may do in the app: the account's role and rights plus the
/// direction of current productions, which comes from the person.
class AccessRights {
  const AccessRights({
    this.admin = false,
    this.permissions = const [],
    this.directorOf = const [],
    this.hasAccess = false,
    this.resting = false,
  });
  final bool admin;
  final List<String> permissions;

  /// Titles of the not archived productions this person directs.
  final List<String> directorOf;

  /// The account is approved or suspended and linked to a person.
  final bool hasAccess;

  /// The account is suspended: role and rights come back when it is
  /// released again but do not apply now. A rejected account holds none,
  /// since it only returns as a new registration ("Erneut prüfen").
  final bool resting;

  /// A plain member account without any further right.
  bool get memberOnly =>
      hasAccess && !admin && permissions.isEmpty && directorOf.isEmpty;
}

/// The status keys of the access overview, see [accessStatusLabel].
const accessStatusKeys = [
  'approved',
  'waiting',
  'unverified',
  'suspended',
  'rejected',
  'noAccount',
];

/// The status of an account (none is `noAccount`): `approved`, `waiting`
/// (pending with a confirmed identity), `unverified`, `suspended` or
/// `rejected`. Whether the person is inactive or the account has no person
/// is shown separately ([AccessEntry.inactive], [AccessEntry.unassigned]).
String accountStatusKey(JsonMap? a) => switch (a?['status']) {
  null => 'noAccount',
  'approved' => 'approved',
  'pending' => a?['identityReady'] == true ? 'waiting' : 'unverified',
  'suspended' => 'suspended',
  'rejected' => 'rejected',
  _ => 'unverified',
};

String accessStatus(AccessEntry entry) => accountStatusKey(entry.account);

String accessStatusLabel(String key) => switch (key) {
  'approved' => 'Freigegeben',
  'waiting' => 'Wartet auf Freigabe',
  'unverified' => 'E-Mail unbestätigt',
  'suspended' => 'Gesperrt',
  'rejected' => 'Abgelehnt',
  'unassigned' => 'Konto ohne Person',
  'inactive' => 'Person inaktiv',
  _ => 'Kein Konto',
};

/// Registrations without a valid bot check proof, e.g. from older apps;
/// accounts from before the bot check have no value and are not marked.
bool withoutBotCheck(JsonMap a) =>
    const ['missing', 'invalid'].contains(a['botCheck']);

/// Registrations caught by the invisible bot trap of the sign-in forms.
bool caughtByBotTrap(JsonMap a) => a['botCheck'] == 'trap';

/// Joins person records, theatrical roles and actual login accounts by stable IDs.
/// Names and e-mail addresses are never used to grant or infer account access.
class AccountRoster {
  AccountRoster(JsonMap data)
    : members = jsonList(data['members']).map(jsonMap).toList(),
      accounts = jsonList(data['accounts']).map(jsonMap).toList(),
      productions = jsonList(data['productions']).map(jsonMap).toList() {
    members.sort(
      (a, b) => textValue(
        a['name'],
      ).toLowerCase().compareTo(textValue(b['name']).toLowerCase()),
    );
  }
  final List<JsonMap> members, accounts, productions;
  JsonMap? accountFor(int personId) {
    for (final a in accounts) {
      if (a['personId'] != null && intValue(a['personId']) == personId) {
        return a;
      }
    }
    return null;
  }

  JsonMap? memberFor(dynamic personId) {
    if (personId == null) return null;
    for (final m in members) {
      if (intValue(m['id']) == intValue(personId)) return m;
    }
    return null;
  }

  /// People by name with their account, then accounts without a person,
  /// newest first.
  late final List<AccessEntry> accessEntries = [
    for (final m in members)
      AccessEntry(member: m, account: accountFor(intValue(m['id']))),
    for (final a in _newestFirst(
      accounts.where((a) => memberFor(a['personId']) == null),
    ))
      AccessEntry(account: a),
  ];

  /// Sorts by `createdAt`, newest first; equal or missing dates keep the
  /// server order (which is newest first as well).
  static List<JsonMap> _newestFirst(Iterable<JsonMap> accounts) {
    final indexed = accounts.indexed.toList()
      ..sort((x, y) {
        final byDate = textValue(
          y.$2['createdAt'],
        ).compareTo(textValue(x.$2['createdAt']));
        return byDate != 0 ? byDate : x.$1.compareTo(y.$1);
      });
    return [for (final (_, a) in indexed) a];
  }

  /// The entry of [personId] or, without one, of the account [uid].
  AccessEntry? entryFor({int? personId, String? uid}) {
    for (final e in accessEntries) {
      if (personId != null && e.personId == personId) return e;
      if (personId == null && uid != null && e.uid == uid) return e;
    }
    return null;
  }

  AccessRights rights(AccessEntry entry) {
    final a = entry.account, id = entry.personId;
    final status = a?['status'];
    // Only approved or suspended linked accounts hold a role and rights.
    final holds =
        const {'approved', 'suspended'}.contains(status) &&
        a?['personId'] != null;
    return AccessRights(
      hasAccess: holds,
      admin: holds && a?['role'] == 'admin',
      permissions: !holds || a?['role'] == 'admin'
          ? const []
          : [
              for (final p in jsonList(a?['permissions']))
                if (accountPermissionLabels.containsKey(p)) p.toString(),
            ],
      directorOf: id == null
          ? const []
          : [
              for (final p in productions)
                if (p['archived'] != true &&
                    jsonList(
                      p['directorMemberIds'],
                    ).any((d) => intValue(d) == id))
                  textValue(p['title']),
            ],
      resting: holds && status == 'suspended',
    );
  }

  /// Whether [entry] passes the status filter [status] (`all`, a key of
  /// [accessStatusKeys], `unassigned` or `inactive`).
  bool hasStatus(AccessEntry entry, String status) => switch (status) {
    'all' => true,
    'inactive' => entry.inactive,
    'unassigned' => entry.unassigned,
    _ => accessStatus(entry) == status,
  };

  /// Whether [entry] passes the rights filter [right] (`all`, `admin`, a
  /// permission, `director` or `member`).
  bool hasRight(AccessEntry entry, String right) {
    final r = rights(entry);
    return switch (right) {
      'all' => true,
      'admin' => r.admin,
      'director' => r.directorOf.isNotEmpty,
      'member' => r.memberOnly,
      _ => r.permissions.contains(right),
    };
  }

  int statusCount(String status) =>
      accessEntries.where((e) => hasStatus(e, status)).length;
  int rightCount(String right) =>
      accessEntries.where((e) => hasRight(e, right)).length;

  /// Waiting registrations, counted like the hub and Today do.
  int get waitingCount => statusCount('waiting');
  int get unverifiedCount => statusCount('unverified');

  /// Holders of a right that applies now: neither suspended (resting) nor
  /// an inactive person, whom the server denies any access. The filters
  /// still find the resting holders, marked "ruht".
  int get adminCount => _activeCount('admin');
  int permissionCount(String permission) => _activeCount(permission);
  int _activeCount(String right) => accessEntries
      .where((e) => !e.inactive && !rights(e).resting && hasRight(e, right))
      .length;

  /// People whose approved account is linked to them.
  int get linkedCount => members
      .where((m) => accountFor(intValue(m['id']))?['status'] == 'approved')
      .length;
  int get withoutAccountCount =>
      members.where((m) => accountFor(intValue(m['id'])) == null).length;
  int get pendingCount =>
      accounts.where((a) => a['status'] == 'pending').length;

  /// Filters [entry] by the search [query] (names, e-mail, person roles,
  /// script roles and productions) and the given filters. [roleNames] are
  /// the names of the person roles, which the roster does not know.
  bool entryMatches(
    AccessEntry entry,
    String query, {
    String status = 'all',
    String right = 'all',
    String? roleId,
    String roleNames = '',
  }) {
    if (!hasStatus(entry, status) || !hasRight(entry, right)) return false;
    if (roleId != null &&
        !jsonList(
          entry.member?['roleIds'],
        ).any((r) => r.toString() == roleId)) {
      return false;
    }
    final m = entry.member;
    return m != null
        ? personMatches(m, query, roleNames: roleNames)
        : matches(query, [entry.account!['name'], entry.account!['email']]);
  }

  List<JsonMap> get roles => [
    for (final p in productions)
      for (final value in jsonList(p['roles']))
        {
          ...jsonMap(value),
          'productionId': p['id'],
          'productionTitle': p['title'],
          'personId': jsonMap(p['casting'])[textValue(jsonMap(value)['id'])],
        },
  ];
  List<JsonMap> rolesFor(int personId) => roles
      .where(
        (r) => r['personId'] != null && intValue(r['personId']) == personId,
      )
      .toList();
  bool matches(String query, Iterable<dynamic> values) {
    final haystack = values.map((v) => textValue(v)).join(' ').toLowerCase();
    return query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .every(haystack.contains);
  }

  bool personMatches(JsonMap m, String query, {String roleNames = ''}) =>
      matches(query, [
        m['name'],
        m['roleName'],
        roleNames,
        accountFor(intValue(m['id']))?['email'],
        for (final r in rolesFor(intValue(m['id']))) ...[
          r['name'],
          r['productionTitle'],
        ],
      ]);
}

/// The label of an account's status; kept for older call sites.
String accountStatus(JsonMap? a) => accessStatusLabel(accountStatusKey(a));
