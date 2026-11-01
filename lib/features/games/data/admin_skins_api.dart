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

/// The scheduled release an item belongs to (`releases.json`): its [part]
/// is `items` (the release's set), `gated` (hidden until it starts) or
/// `free` (everybody's once it starts).
class AdminSkinRelease {
  const AdminSkinRelease({
    required this.id,
    required this.name,
    required this.startsAt,
    required this.active,
    this.part = 'items',
  });
  final String id, name, part;
  final DateTime? startsAt;
  final bool active;

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
    );
  }
}

/// What a skin is right now, as the admins' view shows it.
enum AdminSkinStatus {
  /// In the catalog members get.
  active('Aktiv'),

  /// `disabled` in the catalog: members never get it.
  disabled('Disabled'),

  /// In a release that has not started (or whose set is not complete).
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
  final AdminSkinRelease? release;

  /// `unique` or `reward` while it is a secret until unlocked; null else.
  final String? secret;

  /// The ensemble milestone of a reward, in km.
  final num? milestoneKm;

  /// The status the viewer shows first: disabled before a pending release,
  /// before a secret.
  AdminSkinStatus get status {
    if (disabled) return AdminSkinStatus.disabled;
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
    if (secret != null || release?.part == 'gated') AdminSkinStatus.gated,
  };

  static AdminSkin? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = jsonMap(value);
    final item = WardrobeItem.fromJson(json);
    if (item == null || item.id.isEmpty) return null;
    final admin = jsonMap(json['admin']);
    final secret = textValue(admin['secret']);
    return AdminSkin(
      item: item,
      disabled: admin['disabled'] == true,
      live: admin['live'] != false && admin['disabled'] != true,
      release: AdminSkinRelease.fromJson(admin['release']),
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
    final skins = [
      for (final i in jsonList(json['items'])) ?AdminSkin.fromJson(i),
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
      releases: [
        for (final r in jsonList(json['releases']))
          ?AdminSkinRelease.fromJson(r),
      ],
    );
  }
}

Future<AdminSkinCatalog> loadAdminSkins(AppController controller) async =>
    AdminSkinCatalog.fromJson(await controller.remote('/admin/runner/catalog'));
