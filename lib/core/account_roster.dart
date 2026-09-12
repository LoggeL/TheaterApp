import 'models.dart';

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
  int get linkedCount =>
      members.where((m) => accountFor(intValue(m['id'])) != null).length;
  int get pendingCount =>
      accounts.where((a) => a['status'] == 'pending').length;
  bool matches(String query, Iterable<dynamic> values) {
    final haystack = values.map((v) => textValue(v)).join(' ').toLowerCase();
    return query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .every(haystack.contains);
  }

  bool personMatches(JsonMap m, String query) => matches(query, [
    m['name'],
    m['group'],
    m['roleName'],
    accountFor(intValue(m['id']))?['email'],
    for (final r in rolesFor(intValue(m['id']))) ...[
      r['name'],
      r['productionTitle'],
    ],
  ]);
}

String accountStatus(JsonMap? a) => switch (a?['status']) {
  'approved' => 'Freigegeben',
  'pending' =>
    a?['identityReady'] == true ? 'Freigabe ausstehend' : 'E-Mail unbestätigt',
  'suspended' => 'Gesperrt',
  'rejected' => 'Abgelehnt',
  _ => 'Kein Konto verknüpft',
};
