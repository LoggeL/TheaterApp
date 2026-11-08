import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import 'wardrobe_api.dart';

/// Whether the admins' Skin-Viewer of the stage runner is offered: only to
/// admins, and only when the server announces it (`runnerAdminCatalog`).
/// The server checks the role again on every request (403 for members).
bool adminSkinsAvailable(AppController controller) =>
    controller.user?.isAdmin == true &&
    wardrobeAvailable(controller) &&
    controller.supports('runnerAdminCatalog');

/// An item that keeps the pack of a release back (`missing` on the server):
/// [reason] `disabled` (still disabled), `picture` (enabled without its
/// picture), `unknown` (no such entry) or `invalid` (a default, reward or
/// unique figure, which never belongs to a set).
class AdminSkinMissing {
  const AdminSkinMissing({
    required this.id,
    required this.name,
    required this.reason,
  });
  final String id, name, reason;

  /// "Gerda (deaktiviert)", "Fritzi (ohne Bild)" …
  String get text =>
      '$name (${switch (reason) {
        'disabled' => 'deaktiviert',
        'picture' => 'ohne Bild',
        'unknown' => 'nicht im Katalog',
        _ => 'gehört in kein Set',
      }})';

  static AdminSkinMissing? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = jsonMap(value);
    final id = textValue(json['id']);
    if (id.isEmpty) return null;
    return AdminSkinMissing(
      id: id,
      name: textValue(json['name'], id),
      reason: textValue(json['reason'], 'unknown'),
    );
  }
}

/// The scheduled release an item belongs to (`releases.json`): its [part]
/// is `items` (the release's set), `gated` (hidden until it starts) or
/// `free` (everybody's once it starts). [ready]: every item of its set is
/// enabled and has its pictures; else [missing] names those that are not
/// (filled in from the catalog's list of releases).
class AdminSkinRelease {
  const AdminSkinRelease({
    required this.id,
    required this.name,
    required this.startsAt,
    required this.active,
    this.part = 'items',
    this.ready = true,
    this.missing = const [],
  });
  final String id, name, part;
  final DateTime? startsAt;
  final bool active, ready;
  final List<AdminSkinMissing> missing;

  /// This release of an item with what [pack] (the entry of the catalog's
  /// list) knows of its set.
  AdminSkinRelease withPack(AdminSkinRelease? pack) => pack == null
      ? this
      : AdminSkinRelease(
          id: id,
          name: name,
          startsAt: startsAt ?? pack.startsAt,
          active: active,
          part: part,
          ready: pack.ready,
          missing: pack.missing,
        );

  static AdminSkinRelease? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = jsonMap(value);
    final id = textValue(json['id']);
    if (id.isEmpty) return null;
    return AdminSkinRelease(
      id: id,
      name: textValue(json['name'], id),
      startsAt: DateTime.tryParse(textValue(json['startsAt']))?.toLocal(),
      active: json['active'] == true,
      part: textValue(json['part'], 'items'),
      ready: json['ready'] != false,
      missing: [
        for (final m in jsonList(json['missing']))
          ?AdminSkinMissing.fromJson(m),
      ],
    );
  }
}

/// What a skin is right now, as the admins' view shows it.
enum AdminSkinStatus {
  /// In the catalog members get.
  active('Live'),

  /// `disabled` in the catalog: members never get it.
  disabled('Deaktiviert'),

  /// Its release has started, but its set is not complete yet.
  waiting('Wartet auf Bilder'),

  /// In a release that has not started.
  scheduled('Geplant'),

  /// A secret until unlocked: a unique figure or an ensemble reward.
  gated('Gated');

  const AdminSkinStatus(this.label);
  final String label;
}

/// One entry of the admins' view: the item as the game draws it and its
/// state on the server.
class AdminSkin {
  const AdminSkin({
    required this.item,
    this.disabled = false,
    this.live = true,
    this.waiting = false,
    this.release,
    this.secret,
    this.milestoneKm,
    this.unlock,
  });
  final WardrobeItem item;

  /// What unlocks a unique figure, e.g. "alle Rollen aus Creepshow 2026"
  /// or "alle Techniker"; null for other items.
  final String? unlock;

  /// `disabled` in the catalog; [live]: in the catalog members get now.
  final bool disabled, live;

  /// Its release has started, but the pack still holds it back.
  final bool waiting;
  final AdminSkinRelease? release;

  /// `unique` or `reward` while it is a secret until unlocked; null else.
  final String? secret;

  /// The ensemble milestone of a reward, in km.
  final num? milestoneKm;

  /// The status the viewer shows first: disabled before a waiting pack,
  /// before a pending release, before a secret.
  AdminSkinStatus get status {
    if (disabled) return AdminSkinStatus.disabled;
    if (waiting) return AdminSkinStatus.waiting;
    if (!live) return AdminSkinStatus.scheduled;
    if (secret != null) return AdminSkinStatus.gated;
    return AdminSkinStatus.active;
  }

  /// Every status that applies (a gated unique of a coming release is both).
  Set<AdminSkinStatus> get statuses => {
    status,
    // A free item of a coming release is live already; only the gift waits.
    if (release != null && !release!.active && release!.part != 'free')
      AdminSkinStatus.scheduled,
    if (waiting) AdminSkinStatus.waiting,
    if (secret != null || release?.part == 'gated') AdminSkinStatus.gated,
  };

  static AdminSkin? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = jsonMap(value);
    final item = WardrobeItem.fromJson(json);
    if (item == null || item.id.isEmpty) return null;
    final admin = jsonMap(json['admin']);
    final secret = textValue(admin['secret']);
    final disabled = admin['disabled'] == true;
    final live = admin['live'] != false && !disabled;
    final release = AdminSkinRelease.fromJson(admin['release']);
    return AdminSkin(
      item: item,
      disabled: disabled,
      live: live,
      // A server before `waiting`: a started release that is not live yet.
      waiting: admin['waiting'] is bool
          ? admin['waiting'] == true
          : !disabled &&
                !live &&
                release != null &&
                release.active &&
                release.part != 'free',
      release: release,
      secret: secret.isEmpty ? null : secret,
      milestoneKm: admin['milestoneKm'] is num
          ? admin['milestoneKm'] as num
          : null,
      unlock: item.unique ? _unlockText(json['unlock']) : null,
    );
  }
}

/// "alle Rollen aus Creepshow 2026", "alle Rollen aus Creepshow und Nexus
/// 2024", "alle Techniker"; null without an unlock.
String? _unlockText(Object? value) {
  if (value is! Map) return null;
  final json = jsonMap(value);
  if (json['allTechnicians'] == true) return 'alle Techniker';
  String play(Object? p) => p is Map
      ? [
          textValue(jsonMap(p)['play']),
          ?jsonMap(p)['year']?.toString(),
        ].where((s) => s.isNotEmpty).join(' ')
      : textValue(p);
  final plays = [
    if (json['plays'] is List)
      for (final p in jsonList(json['plays'])) play(p)
    else
      play(json),
  ].where((p) => p.isNotEmpty).toList();
  if (plays.isEmpty) return null;
  final names = plays.length < 2
      ? plays.single
      : '${plays.sublist(0, plays.length - 1).join(', ')} und ${plays.last}';
  return 'alle Rollen aus $names';
}

/// The admins' full catalog (`GET /admin/runner/catalog`): every skin with
/// its state, and the rarities and departments to show them with.
class AdminSkinCatalog {
  const AdminSkinCatalog({
    required this.catalog,
    required this.skins,
    this.releases = const [],
  });

  /// All items as a [WardrobeCatalog], for rarities, labels and colours.
  final WardrobeCatalog catalog;
  final List<AdminSkin> skins;
  final List<AdminSkinRelease> releases;

  factory AdminSkinCatalog.fromJson(JsonMap json) {
    final releases = [
      for (final r in jsonList(json['releases'])) ?AdminSkinRelease.fromJson(r),
    ];
    final packs = {for (final r in releases) r.id: r};
    final skins = [
      for (final i in jsonList(json['items']))
        if (AdminSkin.fromJson(i) case final skin?)
          skin.release == null
              ? skin
              : AdminSkin(
                  item: skin.item,
                  disabled: skin.disabled,
                  live: skin.live,
                  waiting: skin.waiting,
                  release: skin.release!.withPack(packs[skin.release!.id]),
                  secret: skin.secret,
                  milestoneKm: skin.milestoneKm,
                  unlock: skin.unlock,
                ),
    ];
    return AdminSkinCatalog(
      // The items come apart (with their state); the catalog only lends
      // rarities, departments and colours.
      catalog: WardrobeCatalog.fromJson({
        ...json,
        'items': [for (final i in jsonList(json['items'])) i],
        'rewards': const [],
        'uniques': const [],
      }),
      skins: skins,
      releases: releases,
    );
  }
}

Future<AdminSkinCatalog> loadAdminSkins(AppController controller) async =>
    AdminSkinCatalog.fromJson(await controller.remote('/admin/runner/catalog'));
