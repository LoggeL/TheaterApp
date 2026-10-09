import 'dart:convert';

/// Transport-independent models shared by the native screens and offline cache.
typedef JsonMap = Map<String, dynamic>;

JsonMap jsonMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<dynamic> jsonList(Object? value) => value is List ? value : const [];
String textValue(Object? value, [String fallback = '']) =>
    value == null ? fallback : value.toString();
int intValue(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
DateTime? dateValue(Object? value) => DateTime.tryParse(textValue(value));

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.group = '',
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
  });
  final String id, name, email, role, group;
  final bool mustChangePassword;
  final List<String> directorProductionIds;
  final String status;
  final int? personId;
  final bool emailVerified, identityReady;
  final bool needsRegistrationName;
  final String? avatarId;
  final List<String> roleIds;
  final int profileVersion;
  bool get isApproved => status == 'approved' && identityReady;
  bool get isAdmin => role == 'admin';
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
    group: textValue(json['group']),
    status: textValue(json['status'], 'approved'),
    personId: json['personId'] == null ? null : intValue(json['personId']),
    emailVerified: json['emailVerified'] != false,
    identityReady: json['identityReady'] != false,
    needsRegistrationName: json['needsRegistrationName'] == true,
    avatarId: json['avatarId'] as String?,
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
    profileVersion: intValue(json['profileVersion']),
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
    'group': group,
    'status': status,
    'personId': personId,
    'emailVerified': emailVerified,
    'identityReady': identityReady,
    'needsRegistrationName': needsRegistrationName,
    'avatarId': avatarId,
    'roleIds': roleIds,
    'profileVersion': profileVersion,
    'mustChangePassword': mustChangePassword,
    'directorProductionIds': directorProductionIds,
  };
}

class TheaterEvent {
  const TheaterEvent({
    required this.id,
    required this.title,
    this.startsAt,
    this.endsAt,
    this.description = '',
    this.time = '',
    this.place = '',
    this.group = '',
    this.kind = 'other',
    this.tone = 'orange',
    this.locked = false,
    this.attendeeCount = 0,
    this.response = 'open',
    this.declineReason = '',
    this.productionId,
    this.sceneIds = const [],
    this.isCustom = false,
    this.expectedArrivalAt,
    this.version = 1,
    this.roleIds = const [],
    this.personIds = const [],
    this.slotPoolId,
  });
  final String id,
      title,
      description,
      time,
      place,
      group,
      kind,
      tone,
      response,
      declineReason;
  final DateTime? startsAt, endsAt;
  final bool locked, isCustom;
  final int attendeeCount;
  final String? productionId;
  final List<String> sceneIds;
  final DateTime? expectedArrivalAt;
  final int version;

  /// Person roles addressed by this event; empty means everyone.
  final List<String> roleIds;

  /// People invited by name in addition to [roleIds].
  final List<int> personIds;

  /// Set for events generated from a booked slot of a slot pool; their
  /// attendance follows the booking instead of a response.
  final String? slotPoolId;
  bool get fromSlotPool => slotPoolId != null;
  bool get needsResponse => response == 'open' && !locked && !fromSlotPool;
  bool acceptsResponsesAt(DateTime now) =>
      !locked &&
      !fromSlotPool &&
      !((endsAt ?? startsAt)?.isBefore(now) ?? false);

  /// Shortly before the start, members may still confirm or report a late
  /// arrival, but can no longer decline or withdraw. Mirrors the server.
  static const declineCutoff = Duration(hours: 1);
  bool acceptsDeclineAt(DateTime now) =>
      acceptsResponsesAt(now) &&
      (startsAt == null || startsAt!.subtract(declineCutoff).isAfter(now));
  factory TheaterEvent.fromJson(JsonMap json) => TheaterEvent(
    id: textValue(json['id']),
    title: textValue(json['title']),
    description: textValue(json['description']),
    startsAt: dateValue(json['startsAt'])?.toLocal(),
    endsAt: dateValue(json['endsAt'])?.toLocal(),
    time: textValue(json['time']),
    place: textValue(json['place']),
    group: textValue(json['group']),
    kind: textValue(json['type'] ?? json['kind'], 'other'),
    tone: textValue(json['tone'], 'orange'),
    locked: json['locked'] == true,
    isCustom: json['isCustom'] == true,
    attendeeCount: intValue(json['people'] ?? json['attendeeCount']),
    response: textValue(json['response'], 'open'),
    declineReason: textValue(json['declineReason']),
    expectedArrivalAt: dateValue(json['expectedArrivalAt'])?.toLocal(),
    version: intValue(json['version'], 1),
    productionId: json['productionId'] as String?,
    sceneIds: jsonList(json['sceneIds']).map((e) => e.toString()).toList(),
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
    personIds: jsonList(json['personIds']).map(intValue).toList(),
    slotPoolId: json['slotPoolId'] == null
        ? null
        : textValue(json['slotPoolId']),
  );
  TheaterEvent copyWith({
    String? response,
    String? declineReason,
    DateTime? expectedArrivalAt,
    bool clearExpectedArrival = false,
  }) => TheaterEvent(
    id: id,
    title: title,
    description: description,
    startsAt: startsAt,
    endsAt: endsAt,
    time: time,
    place: place,
    group: group,
    kind: kind,
    tone: tone,
    locked: locked,
    attendeeCount: attendeeCount,
    response: response ?? this.response,
    declineReason: declineReason ?? this.declineReason,
    productionId: productionId,
    sceneIds: sceneIds,
    isCustom: isCustom,
    expectedArrivalAt: clearExpectedArrival
        ? null
        : expectedArrivalAt ?? this.expectedArrivalAt,
    version: version,
    roleIds: roleIds,
    personIds: personIds,
    slotPoolId: slotPoolId,
  );
  JsonMap toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'startsAt': startsAt?.toIso8601String(),
    'endsAt': endsAt?.toIso8601String(),
    'time': time,
    'place': place,
    'group': group,
    'type': kind,
    'tone': tone,
    'locked': locked,
    'isCustom': isCustom,
    'people': attendeeCount,
    'response': response,
    'declineReason': declineReason,
    'expectedArrivalAt': expectedArrivalAt?.toUtc().toIso8601String(),
    'version': version,
    'roleIds': roleIds,
    'personIds': personIds,
    'productionId': productionId,
    'sceneIds': sceneIds,
    if (slotPoolId != null) 'slotPoolId': slotPoolId,
  };
}

class Absence {
  const Absence({
    required this.id,
    required this.from,
    required this.to,
    this.reason = '',
  });
  final String id, reason;
  final DateTime from, to;
  factory Absence.fromJson(JsonMap json) => Absence(
    id: textValue(json['id']),
    from: DateTime.parse(textValue(json['from'])),
    to: DateTime.parse(textValue(json['to'])),
    reason: textValue(json['reason']),
  );
  JsonMap toJson() => {
    'id': id,
    'from': dateOnly(from),
    'to': dateOnly(to),
    'reason': reason,
  };
}

String dateOnly(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class PollVoter {
  const PollVoter({required this.personId, required this.name});
  final int personId;
  final String name;
  factory PollVoter.fromJson(JsonMap json) => PollVoter(
    personId: intValue(json['personId']),
    name: textValue(json['name']),
  );
  JsonMap toJson() => {'personId': personId, 'name': name};
}

class PollOption {
  const PollOption({
    required this.id,
    required this.label,
    this.time = '',
    this.votes = 0,
    this.voters = const [],
  });
  final String id, label, time;
  final int votes;
  final List<PollVoter> voters;
  factory PollOption.fromJson(JsonMap json, {bool anonymous = true}) =>
      PollOption(
        id: textValue(json['id']),
        label: textValue(json['day'] ?? json['label']),
        time: textValue(json['time']),
        votes: intValue(json['votes']),
        voters: anonymous
            ? const []
            : jsonList(
                json['voters'],
              ).map((e) => PollVoter.fromJson(jsonMap(e))).toList(),
      );
  JsonMap toJson({bool anonymous = true}) => {
    'id': id,
    'label': label,
    'time': time,
    'votes': votes,
    if (!anonymous) 'voters': voters.map((v) => v.toJson()).toList(),
  };
}

class Poll {
  const Poll({
    required this.id,
    required this.title,
    this.description = '',
    this.options = const [],
    this.selectedOptionId,
    this.confirmedOptionId,
    this.closed = false,
    this.anonymous = true,
    this.closesAt,
    this.version = 1,
    this.roleIds = const [],
  });
  final String id, title, description;
  final List<PollOption> options;

  /// Person roles that may see and vote; empty means everyone.
  final List<String> roleIds;
  final String? selectedOptionId, confirmedOptionId;
  final bool closed, anonymous;
  String get privacyLabel => anonymous ? 'Anonym' : 'Namentlich';
  final DateTime? closesAt;
  final int version;
  int get totalVotes => options.fold(0, (n, o) => n + o.votes);
  String get voteCountLabel =>
      totalVotes == 1 ? '1 Stimme' : '$totalVotes Stimmen';
  bool get isClosed =>
      closed ||
      confirmedOptionId != null ||
      (closesAt != null && !closesAt!.isAfter(DateTime.now()));
  factory Poll.fromJson(JsonMap json) => Poll(
    id: textValue(json['id']),
    title: textValue(json['title']),
    description: textValue(json['description']),
    options: jsonList(json['options'])
        .map(
          (e) => PollOption.fromJson(
            jsonMap(e),
            anonymous: json['anonymous'] != false,
          ),
        )
        .toList(),
    selectedOptionId: (json['choice'] ?? json['selectedOptionId']) as String?,
    confirmedOptionId: json['confirmedOptionId'] as String?,
    closed: json['closed'] == true,
    anonymous: json['anonymous'] != false,
    closesAt: dateValue(json['closesAt']),
    version: intValue(json['version'], 1),
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
  );
  Poll withChoice(String optionId, {PollVoter? voter}) => Poll(
    id: id,
    title: title,
    description: description,
    options: options
        .map(
          (e) => PollOption(
            id: e.id,
            label: e.label,
            time: e.time,
            votes:
                e.votes +
                (e.id == optionId ? 1 : 0) -
                (e.id == selectedOptionId ? 1 : 0),
            voters: anonymous
                ? const []
                : [
                    ...e.voters.where(
                      (existing) =>
                          voter == null || existing.personId != voter.personId,
                    ),
                    if (voter != null && e.id == optionId) voter,
                  ],
          ),
        )
        .toList(),
    selectedOptionId: optionId,
    confirmedOptionId: confirmedOptionId,
    closed: closed,
    anonymous: anonymous,
    closesAt: closesAt,
    version: version,
    roleIds: roleIds,
  );
  JsonMap toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'roleIds': roleIds,
    'options': options.map((e) => e.toJson(anonymous: anonymous)).toList(),
    'choice': selectedOptionId,
    'confirmedOptionId': confirmedOptionId,
    'closed': closed,
    'anonymous': anonymous,
    'closesAt': closesAt?.toUtc().toIso8601String(),
    'version': version,
  };
}

class TheaterMember {
  const TheaterMember({
    required this.id,
    required this.name,
    this.group = '',
    this.initials = '',
    this.avatar,
    this.avatarId,
    this.roleIds = const [],
    this.active = true,
  });
  final int id;
  final String name, group, initials;
  final String? avatar, avatarId;
  final List<String> roleIds;
  final bool active;

  /// Whether this member belongs to an audience of roles or invited people
  /// (both empty = everyone).
  bool inAudience(List<String> audience, [List<int> people = const []]) =>
      (audience.isEmpty && people.isEmpty) ||
      audience.any(roleIds.contains) ||
      people.contains(id);
  factory TheaterMember.fromJson(JsonMap json) => TheaterMember(
    id: intValue(json['id']),
    name: textValue(json['name']),
    group: textValue(json['group']),
    initials: textValue(json['initials']),
    avatar: json['avatar'] as String?,
    avatarId: json['avatarId'] as String?,
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
    active: json['active'] != false,
  );
  JsonMap toJson() => {
    'id': id,
    'name': name,
    'group': group,
    'initials': initials,
    'avatar': avatar,
    'avatarId': avatarId,
    'roleIds': roleIds,
    'active': active,
  };
}

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
  });
  final String id, title, subtitle, revision;
  final List<ScriptRole> roles;
  final int sceneCount;
  final DateTime? premiereAt, createdAt;
  final bool archived;
  final int version;

  DateTime get sortDate {
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
    return createdAt?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

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
  };
}

class ScriptScene {
  const ScriptScene({
    required this.id,
    required this.title,
    required this.ordinal,
    this.roles = const [],
  });
  final String id, title;
  final int ordinal;
  final List<String> roles;
  factory ScriptScene.fromJson(JsonMap json) => ScriptScene(
    id: textValue(json['id']),
    title: textValue(json['title']),
    ordinal: intValue(json['ordinal']),
    roles: jsonList(json['roles']).map((e) => e.toString()).toList(),
  );
  JsonMap toJson() => {
    'id': id,
    'title': title,
    'ordinal': ordinal,
    'roles': roles,
  };
}

class ScriptCue {
  const ScriptCue({
    required this.id,
    required this.sceneId,
    required this.ordinal,
    required this.kind,
    required this.text,
    this.role = '',
    this.microphone = '',
    this.isAutoMic = false,
    this.micCueType = '',
  });
  final String id, sceneId, kind, role, text, microphone, micCueType;
  final int ordinal;
  final bool isAutoMic;
  String get category => kind;
  bool get isTechnical => const {
    'technical',
    'lighting',
    'audio',
    'props',
    'microphone',
  }.contains(kind);
  factory ScriptCue.fromJson(JsonMap json) => ScriptCue(
    id: textValue(json['id'] ?? json['cueId']),
    sceneId: textValue(json['sceneId']),
    ordinal: intValue(json['ordinal'] ?? json['cueOrdinal']),
    kind: textValue(json['category'] ?? json['kind'], 'unknown'),
    text: textValue(json['text']),
    role: textValue(json['role']),
    microphone: textValue(json['microphone']),
    isAutoMic: json['isAutoMic'] == true,
    micCueType: textValue(json['micCueType']),
  );
  JsonMap toJson() => {
    'id': id,
    'sceneId': sceneId,
    'ordinal': ordinal,
    'category': kind,
    'role': role,
    'text': text,
    'microphone': microphone,
    'isAutoMic': isAutoMic,
    'micCueType': micCueType,
  };
}

class ScriptDocument {
  const ScriptDocument({
    required this.productionId,
    required this.revision,
    required this.scenes,
    required this.roles,
    required this.cues,
    this.fetchedAt,
    this.stale = false,
  });
  final String productionId, revision;
  final List<ScriptScene> scenes;
  final List<ScriptRole> roles;
  final List<ScriptCue> cues;
  final DateTime? fetchedAt;
  final bool stale;
  factory ScriptDocument.fromJson(JsonMap json) {
    final cues =
        jsonList(
            json['cues'],
          ).map((e) => ScriptCue.fromJson(jsonMap(e))).toList()
          ..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final scenes = jsonList(json['scenes']).map((e) {
      final scene = ScriptScene.fromJson(jsonMap(e));
      return ScriptScene(
        id: scene.id,
        title: scene.title,
        ordinal: scene.ordinal,
        roles: scene.roles.isNotEmpty
            ? scene.roles
            : cues
                  .where(
                    (c) =>
                        c.sceneId == scene.id &&
                        c.kind == 'dialogue' &&
                        c.role.isNotEmpty,
                  )
                  .map((c) => c.role)
                  .toSet()
                  .toList(),
      );
    }).toList()..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    return ScriptDocument(
      productionId: textValue(json['productionId']),
      revision: textValue(json['revision']),
      cues: cues,
      scenes: scenes,
      roles: jsonList(
        json['roles'],
      ).map((e) => ScriptRole.fromJson(jsonMap(e))).toList(),
      fetchedAt: dateValue(jsonMap(json['cache'])['fetchedAt']),
      stale: jsonMap(json['cache'])['stale'] == true,
    );
  }
  List<ScriptCue> cuesForScene(String sceneId) =>
      cues.where((e) => e.sceneId == sceneId).toList();
  JsonMap toJson() => {
    'productionId': productionId,
    'revision': revision,
    'scenes': scenes.map((e) => e.toJson()).toList(),
    'roles': roles.map((e) => e.toJson()).toList(),
    'cues': cues.map((e) => e.toJson()).toList(),
    'cache': {'fetchedAt': fetchedAt?.toIso8601String(), 'stale': stale},
  };
}

class FocusState {
  const FocusState({
    required this.productionId,
    this.revision = '',
    this.cueId,
    this.sequence = 0,
    this.updatedBy,
    this.updatedAt,
    this.canDirect = false,
    this.source = 'app',
    this.connected = true,
  });
  final String source;
  final bool connected;
  final String productionId, revision;
  final String? cueId, updatedBy;
  final DateTime? updatedAt;
  final int sequence;
  final bool canDirect;
  factory FocusState.fromJson(JsonMap json) => FocusState(
    productionId: textValue(json['productionId']),
    revision: textValue(json['revision']),
    cueId: json['cueId'] as String?,
    sequence: intValue(json['sequence']),
    updatedBy: json['updatedBy'] as String?,
    updatedAt: dateValue(json['updatedAt']),
    canDirect: json['canDirect'] == true,
    source: textValue(json['source'], 'app'),
    connected: json['connected'] != false,
  );
}

class PendingAction {
  const PendingAction({
    required this.id,
    required this.payload,
    required this.createdAt,
    this.status = 'pending',
    this.lastError,
  });
  final String id, status;
  final JsonMap payload;
  final DateTime createdAt;
  final String? lastError;
  bool get failed => status == 'failed';
  String get label => switch (payload['action']) {
    'attendance' => 'Terminrückmeldung',
    'poll.vote' => 'Abstimmung',
    'absence.create' => 'Abwesenheit',
    'absence.delete' => 'Abwesenheit entfernen',
    'settings.reminders' => 'Erinnerungseinstellungen',
    'checkin.save' => 'Anwesenheits-Check-in',
    'event.script' => 'Drehbuchzuordnung',
    _ => 'Änderung',
  };
  PendingAction withStatus(String next, [String? error]) => PendingAction(
    id: id,
    payload: payload,
    createdAt: createdAt,
    status: next,
    lastError: error,
  );
  factory PendingAction.fromJson(JsonMap json) => PendingAction(
    id: textValue(json['id']),
    payload: jsonMap(json['payload']),
    createdAt: DateTime.parse(textValue(json['createdAt'])),
    status: textValue(json['status'], 'pending'),
    lastError: json['lastError'] as String?,
  );
  JsonMap toJson() => {
    'id': id,
    'payload': payload,
    'createdAt': createdAt.toIso8601String(),
    'status': status,
    'lastError': lastError,
  };
}

/// Clone JSON snapshots so optimistic changes never alter the server baseline.
JsonMap cloneJson(JsonMap value) => jsonMap(jsonDecode(jsonEncode(value)));
