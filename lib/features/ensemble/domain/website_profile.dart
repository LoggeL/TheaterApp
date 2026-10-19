import '../../../core/models.dart';
import '../../casting/domain/casting.dart';

/// One role from the public website, e.g. "Drusilla" in "Creepshow" (2026).
class WebsiteCredit {
  const WebsiteCredit({
    required this.title,
    required this.role,
    this.year,
    this.location,
    this.productionId,
    this.galleryUrl,
  });
  final String title, role;
  final int? year;
  final String? location, productionId, galleryUrl;

  factory WebsiteCredit.fromJson(JsonMap json) => WebsiteCredit(
    title: textValue(json['title']),
    role: textValue(json['role']),
    year: json['year'] == null ? null : intValue(json['year']),
    location: _optional(json['location']),
    productionId: _optional(json['productionId']),
    galleryUrl: _optional(json['galleryUrl']),
  );
}

/// A crew job from the website, e.g. "Lichttechnik".
class WebsiteJob {
  const WebsiteJob({required this.job, this.description = ''});
  final String job, description;
  factory WebsiteJob.fromJson(JsonMap json) => WebsiteJob(
    job: textValue(json['job']),
    description: textValue(json['description']),
  );
}

/// The public profile of a person on kolpingtheater-ramsen.de/team, imported
/// by the server. [hidden] profiles (the person hid them) carry no content.
class WebsiteProfile {
  const WebsiteProfile({
    required this.slug,
    required this.name,
    this.personId,
    this.personLink,
    this.hidden = false,
    this.since,
    this.url,
    this.current,
    this.credits = const [],
    this.jobs = const [],
  });
  final String slug, name;
  final int? personId, since;
  final String? personLink, url;
  final bool hidden;
  final WebsiteCredit? current;

  /// Newest first.
  final List<WebsiteCredit> credits;
  final List<WebsiteJob> jobs;

  factory WebsiteProfile.fromJson(JsonMap json) => WebsiteProfile(
    slug: textValue(json['slug']),
    name: textValue(json['name']),
    personId: json['personId'] == null ? null : intValue(json['personId']),
    personLink: _optional(json['personLink']),
    hidden: json['hidden'] == true,
    since: json['since'] == null ? null : intValue(json['since']),
    url: _optional(json['url']),
    current: json['current'] == null
        ? null
        : WebsiteCredit.fromJson(jsonMap(json['current'])),
    credits: jsonList(
      json['credits'],
    ).map((e) => WebsiteCredit.fromJson(jsonMap(e))).toList(),
    jobs: jsonList(
      json['jobs'],
    ).map((e) => WebsiteJob.fromJson(jsonMap(e))).toList(),
  );
}

String? _optional(Object? value) {
  final text = textValue(value);
  return text.isEmpty ? null : text;
}

/// The website profile linked to [personId], unless the person hid it.
WebsiteProfile? websiteProfileOf(
  Iterable<WebsiteProfile> profiles,
  int personId,
) => profiles.where((p) => p.personId == personId && !p.hidden).firstOrNull;

/// One production on a person's profile: the website's role and what the
/// app knows (roles, Regie, team function) merged into one entry.
class ProfileCredit {
  const ProfileCredit({
    required this.title,
    required this.duties,
    this.year,
    this.location,
    this.productionId,
  });
  final String title;
  final List<String> duties;
  final int? year;
  final String? location;

  /// The app production, when the app knows it.
  final String? productionId;
}

/// Whether two role labels mean the same part ("FIONA" / "Fiona",
/// "GRAF" / "Graf Thaddäus", "BUTLER" / "Butler Wilson / Regie");
/// mirrors `sameRole` of the server's website import.
bool sameRoleLabel(String a, String b) {
  List<List<String>> parts(String value) => value
      .split('/')
      .map((part) => normalizeName(part).split(' ').where((t) => t.isNotEmpty))
      .map((tokens) => tokens.toList())
      .where((tokens) => tokens.isNotEmpty)
      .toList();
  bool word(String t, String u) =>
      t == u ||
      ((t.length < u.length ? t.length : u.length) >= 4 &&
          (t.startsWith(u) || u.startsWith(t)));
  bool within(List<String> x, List<String> y) =>
      x.every((t) => y.any((u) => word(t, u)));
  return parts(a).any((x) => parts(b).any((y) => within(x, y) || within(y, x)));
}

/// When a website play ran. The website only gives the year; its open-air
/// plays are the summer plays, the others the winter plays on the indoor
/// stage, matching `Production.seasonDate` ("Sommerstück" July, "Winterstück"
/// December).
DateTime? websiteSeasonDate(WebsiteCredit credit) {
  final year = credit.year;
  if (year == null) return null;
  final openAir = RegExp(
    r'open.?air',
    caseSensitive: false,
  ).hasMatch(credit.location ?? '');
  return DateTime.utc(year, openAir ? 7 : 12);
}

/// A person's productions, newest first, from the website and the app
/// without duplicates: a website role and the app production it belongs to
/// become one entry; the website's wording wins for the same role.
/// [productionRecords] are the server's production records with casting.
List<ProfileCredit> mergeProfileCredits({
  required int personId,
  required Iterable<JsonMap> productionRecords,
  WebsiteProfile? website,
}) {
  final productions = {
    for (final record in productionRecords)
      textValue(record['id']): Production.fromJson(record),
  };
  final app = {
    for (final credit in creditsOf(
      productionRecords.map(ProductionCast.fromRecord),
      personId,
    ))
      credit.production.id: credit.duties,
  };
  // Each entry with when it ran (null: unknown) and its position as tie-break.
  final entries = <(ProfileCredit, DateTime?, int)>[];
  final used = <String>{};
  for (final (i, credit) in (website?.credits ?? const []).indexed) {
    final id = credit.productionId;
    final known = id != null && productions.containsKey(id);
    final duties = <String>[credit.role];
    if (known && used.add(id)) {
      for (final duty in app[id] ?? const <String>[]) {
        if (!duties.any((d) => sameRoleLabel(d, duty))) duties.add(duty);
      }
    }
    // The app's premiere or season is more precise than the website's year.
    final season = known ? productions[id]!.seasonDate : null;
    entries.add((
      ProfileCredit(
        title: credit.title,
        duties: duties,
        year: credit.year,
        location: credit.location,
        productionId: known ? id : null,
      ),
      season != null && (credit.year == null || season.year == credit.year)
          ? season
          : websiteSeasonDate(credit),
      i,
    ));
  }
  final offset = entries.length;
  for (final (i, MapEntry(key: id, value: duties)) in app.entries.indexed) {
    if (used.contains(id)) continue;
    final production = productions[id]!;
    final year = production.sortDate.year;
    entries.add((
      ProfileCredit(
        title: production.title,
        duties: duties,
        year: year < 1990 ? null : year,
        productionId: id,
      ),
      production.seasonDate ?? production.createdAt?.toUtc(),
      offset + i,
    ));
  }
  // Newest first; entries without a date (new app productions) lead, ties
  // keep the website's order (newest first) before the app's.
  entries.sort((a, b) {
    final da = a.$2, db = b.$2;
    if (da != db) {
      if (da == null) return -1;
      if (db == null) return 1;
      final chronology = db.compareTo(da);
      if (chronology != 0) return chronology;
    }
    return a.$3.compareTo(b.$3);
  });
  return [for (final (credit, _, _) in entries) credit];
}
