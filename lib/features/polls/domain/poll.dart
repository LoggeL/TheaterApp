import '../../../core/json.dart';

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
    this.personIds = const [],
    this.productionIds = const [],
    this.addressedToMe,
    this.eligibleCount,
    this.eligibleVotes,
    this.lastRemindedAt,
    this.remindCount = 0,
  });
  final String id, title, description;
  final List<PollOption> options;

  /// Person roles that may see and vote; empty means everyone.
  final List<String> roleIds;
  final List<int> personIds;
  final List<String> productionIds;
  final String? selectedOptionId, confirmedOptionId;
  final bool closed, anonymous;
  String get privacyLabel => anonymous ? 'Anonym' : 'Namentlich';
  final DateTime? closesAt;
  final int version;

  /// Whether the signed-in person may vote; null from older servers, where
  /// the audience has to be checked on the device.
  final bool? addressedToMe;

  /// Active members who may vote (admins on servers with `pollRemind`).
  final int? eligibleCount;

  /// Votes from people in the audience; admins outside it may vote too.
  final int? eligibleVotes;

  /// When an admin last reminded the open voters, and how often (servers
  /// with `nudges`).
  final DateTime? lastRemindedAt;
  final int remindCount;
  int get totalVotes => options.fold(0, (n, o) => n + o.votes);
  String get voteCountLabel =>
      totalVotes == 1 ? '1 Stimme' : '$totalVotes Stimmen';
  bool get isClosed => isClosedAt(DateTime.now());

  /// Whether voting has ended at [now], e.g. `controller.now`.
  bool isClosedAt(DateTime now) =>
      closed ||
      confirmedOptionId != null ||
      (closesAt != null && !closesAt!.isAfter(now));

  /// Whether an audience was chosen; none means everyone may vote.
  bool get hasAudience =>
      roleIds.isNotEmpty || personIds.isNotEmpty || productionIds.isNotEmpty;
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
    personIds: jsonList(json['personIds']).map(intValue).toList(),
    productionIds: jsonList(
      json['productionIds'],
    ).map((e) => e.toString()).toList(),
    addressedToMe: json['addressedToMe'] is bool
        ? json['addressedToMe'] as bool
        : null,
    eligibleCount: json['eligibleCount'] is num
        ? (json['eligibleCount'] as num).toInt()
        : null,
    eligibleVotes: json['eligibleVotes'] is num
        ? (json['eligibleVotes'] as num).toInt()
        : null,
    lastRemindedAt: dateValue(json['lastRemindedAt']),
    remindCount: intValue(json['remindCount']),
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
    personIds: personIds,
    productionIds: productionIds,
    addressedToMe: addressedToMe,
    eligibleCount: eligibleCount,
    eligibleVotes: eligibleVotes,
    lastRemindedAt: lastRemindedAt,
    remindCount: remindCount,
  );

  // Every field read in [Poll.fromJson] must survive [toJson]: queued votes
  // are projected through this round trip.
  JsonMap toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'roleIds': roleIds,
    'personIds': personIds,
    'productionIds': productionIds,
    'options': options.map((e) => e.toJson(anonymous: anonymous)).toList(),
    'choice': selectedOptionId,
    'confirmedOptionId': confirmedOptionId,
    'closed': closed,
    'anonymous': anonymous,
    'closesAt': closesAt?.toUtc().toIso8601String(),
    'version': version,
    if (addressedToMe != null) 'addressedToMe': addressedToMe,
    if (eligibleCount != null) 'eligibleCount': eligibleCount,
    if (eligibleVotes != null) 'eligibleVotes': eligibleVotes,
    if (lastRemindedAt != null)
      'lastRemindedAt': lastRemindedAt!.toUtc().toIso8601String(),
    if (remindCount != 0) 'remindCount': remindCount,
  };
}
