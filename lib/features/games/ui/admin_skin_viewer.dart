import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../data/admin_skins_api.dart';
import '../data/wardrobe_api.dart';
import 'figure_detail.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';
import 'wardrobe_cards.dart';

/// Opens the admins' Skin-Viewer; nothing for anybody else.
Future<void> openAdminSkinViewer(
  BuildContext context,
  AppController controller,
) async {
  if (!adminSkinsAvailable(controller)) return;
  await openPage<void>(context, AdminSkinViewerScreen(controller: controller));
}

/// The groups the viewer can be narrowed to.
enum _Category {
  all('Alle'),
  roles('Rollen'),
  tech('Technik'),
  legacy('Legacy'),
  unique('Unique'),
  standard('Standard'),
  backdrops('Kulissen'),
  obstacles('Hindernisse'),
  fx('Effekte'),
  rewards('Ensemble');

  const _Category(this.label);
  final String label;
}

/// A technician's figure: a function instead of a role in a play.
bool _isTech(WardrobeItem item) =>
    item.kind == WardrobeKind.character &&
    !item.isDefault &&
    !item.unique &&
    item.role?.isFunction == true;

Set<_Category> _categoriesOf(WardrobeCatalog catalog, WardrobeItem item) => {
  if (item.isDefault) _Category.standard,
  if (item.reward) _Category.rewards,
  if (item.unique) _Category.unique,
  if (_isTech(item)) _Category.tech,
  if (item.kind == WardrobeKind.character &&
      !item.isDefault &&
      !item.unique &&
      !_isTech(item))
    _Category.roles,
  if (catalog.raritiesOf(item).any((r) => r.antique)) _Category.legacy,
  if (item.kind == WardrobeKind.backdrop) _Category.backdrops,
  if (item.kind == WardrobeKind.obstacles) _Category.obstacles,
  if (item.kind == WardrobeKind.fx) _Category.fx,
};

/// The group a skin is listed under: its play ("Creepshow 2026") for role
/// and unique figures, else what it is. [order] sorts the groups: the plays
/// newest first, then the rest.
({String title, (int, int, String) order}) _groupOf(WardrobeItem item) {
  final role = item.role;
  if (item.isDefault) return (title: 'Standard', order: (6, 0, ''));
  if (item.kind == WardrobeKind.character && role?.play != null) {
    final title = role!.production!;
    return (title: title, order: (0, -(role.year ?? 0), title.toLowerCase()));
  }
  return switch (item.kind) {
    WardrobeKind.character when _isTech(item) => (
      title: 'Technik',
      order: (1, 0, ''),
    ),
    WardrobeKind.character when item.unique => (
      title: 'Unique ohne Stück',
      order: (2, 0, ''),
    ),
    WardrobeKind.character => (title: 'Weitere Figuren', order: (7, 0, '')),
    WardrobeKind.backdrop => (title: 'Kulissen', order: (3, 0, '')),
    WardrobeKind.obstacles => (title: 'Hindernis-Sets', order: (4, 0, '')),
    WardrobeKind.fx => (title: 'Effekte', order: (5, 0, '')),
  };
}

int _compareOrder((int, int, String) a, (int, int, String) b) {
  if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
  if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
  return a.$3.compareTo(b.$3);
}

final _date = DateFormat('dd.MM.yyyy, HH:mm');

/// A skin that should bring a picture of its own but has none (yet): the
/// game then draws the default art in its place.
bool _withoutPicture(WardrobeItem item) =>
    !item.isDefault &&
    !item.placeholder &&
    item.kind != WardrobeKind.fx &&
    !hasOwnPictures(item);

/// The badge colour of a status.
Color _statusColor(AdminSkinStatus status) => switch (status) {
  AdminSkinStatus.active => const Color(0xFF3FA66B),
  AdminSkinStatus.disabled => const Color(0xFF7A7F7C),
  AdminSkinStatus.scheduled => const Color(0xFFE0A23A),
  AdminSkinStatus.gated => const Color(0xFFA77BF0),
};

/// The status in words: "Aktiv", "Disabled", "ab 08.11.2026, 18:00",
/// "Gated · Unique" …
String statusText(AdminSkin skin) {
  final release = skin.release;
  return switch (skin.status) {
    AdminSkinStatus.active => 'Aktiv',
    AdminSkinStatus.disabled => 'Disabled',
    AdminSkinStatus.scheduled =>
      release?.startsAt != null && release?.active != true
          ? 'ab ${_date.format(release!.startsAt!)}'
          : 'Release wartet auf alle Bilder',
    AdminSkinStatus.gated =>
      skin.secret == 'unique' ? 'Gated · Unique' : 'Gated · Ensemble',
  };
}

/// The admins' Skin-Viewer: every skin of the stage runner (figures of
/// every play, technicians, unique figures, the defaults, backdrops,
/// obstacle sets and effects), owned or not, disabled, unreleased or still
/// a secret, grouped by play, with search and filters. A tap opens the
/// skin with its animations.
class AdminSkinViewerScreen extends StatefulWidget {
  const AdminSkinViewerScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<AdminSkinViewerScreen> createState() => _AdminSkinViewerScreenState();
}

class _AdminSkinViewerScreenState extends State<AdminSkinViewerScreen> {
  Future<AdminSkinCatalog>? _catalog;
  RunnerArt? _art = RunnerArt.loaded;
  final _search = TextEditingController();
  _Category _category = _Category.all;
  AdminSkinStatus? _status;

  bool get _allowed => adminSkinsAvailable(widget.controller);

  @override
  void initState() {
    super.initState();
    if (_allowed) {
      _catalog = loadAdminSkins(widget.controller);
      if (_art == null) {
        RunnerArt.load().then((art) {
          if (mounted) setState(() => _art = art);
        });
      }
    }
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reload() =>
      setState(() => _catalog = loadAdminSkins(widget.controller));

  bool _matches(AdminSkinCatalog data, AdminSkin skin) {
    final item = skin.item;
    if (_category != _Category.all &&
        !_categoriesOf(data.catalog, item).contains(_category)) {
      return false;
    }
    if (_status != null && !skin.statuses.contains(_status)) return false;
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    final haystack = [
      item.id,
      item.name,
      item.role?.role,
      item.role?.play,
      item.role?.year?.toString(),
      data.catalog.labelOf(item),
      ...data.catalog.raritiesOf(item).map((r) => r.name),
      skin.release?.name,
      statusText(skin),
    ].whereType<String>().join(' ').toLowerCase();
    return query.split(RegExp(r'\s+')).every(haystack.contains);
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) {
      return Scaffold(
        appBar: AppBar(title: const Text('Skin-Viewer')),
        body: const Center(child: Text('Nur für Admins.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Skin-Viewer'),
        actions: [
          IconButton(
            tooltip: 'Neu laden',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<AdminSkinCatalog>(
        future: _catalog,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      userMessage(snapshot.error!),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _reload,
                      child: const Text('Erneut versuchen'),
                    ),
                  ],
                ),
              ),
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return _list(context, data);
        },
      ),
    );
  }

  Widget _list(BuildContext context, AdminSkinCatalog data) {
    final theme = Theme.of(context);
    final shown = data.skins.where((s) => _matches(data, s)).toList();
    final groups =
        <String, ({(int, int, String) order, List<AdminSkin> skins})>{};
    for (final skin in shown) {
      final g = _groupOf(skin.item);
      (groups[g.title] ??= (
        order: g.order,
        skins: <AdminSkin>[],
      )).skins.add(skin);
    }
    final sorted = groups.entries.toList()
      ..sort((a, b) => _compareOrder(a.value.order, b.value.order));
    int rank(AdminSkin s) => data.catalog.rarityOf(s.item).rank;
    for (final g in sorted) {
      g.value.skins.sort((a, b) {
        final r = rank(b).compareTo(rank(a));
        return r != 0 ? r : a.item.name.compareTo(b.item.name);
      });
    }
    final counts = {
      for (final status in AdminSkinStatus.values)
        status: data.skins.where((s) => s.statuses.contains(status)).length,
    };
    final width = MediaQuery.sizeOf(context).width;
    final side = max(12.0, (width - 1200) / 2);
    return CustomScrollView(
      key: const PageStorageKey('admin-skins'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 12, side, 4),
          sliver: SliverList.list(
            children: [
              TextField(
                key: const ValueKey('admin-skins-search'),
                controller: _search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Name, Rolle, Stück, Jahr, ID …',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Suche leeren',
                          onPressed: _search.clear,
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in _Category.values)
                    ChoiceChip(
                      key: ValueKey('admin-skins-category-${c.name}'),
                      label: Text(c.label),
                      selected: _category == c,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    key: const ValueKey('admin-skins-status-all'),
                    label: Text('Jeder Status (${data.skins.length})'),
                    selected: _status == null,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _status = null),
                  ),
                  for (final s in AdminSkinStatus.values)
                    ChoiceChip(
                      key: ValueKey('admin-skins-status-${s.name}'),
                      avatar: CircleAvatar(
                        radius: 5,
                        backgroundColor: _statusColor(s),
                      ),
                      label: Text('${s.label} (${counts[s]})'),
                      selected: _status == s,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _status = s),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${shown.length} von ${data.skins.length} Skins · nur für Admins sichtbar',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (shown.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('Keine Skins für diese Auswahl.')),
          ),
        for (final g in sorted) ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 18, side, 8),
            sliver: SliverToBoxAdapter(
              child: Text(
                '${g.key} · ${g.value.skins.length}',
                key: ValueKey('admin-skins-group-${g.key}'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: side),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 170,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio:
                    .6 /
                    (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
                      1.0,
                      1.6,
                    ),
              ),
              itemCount: g.value.skins.length,
              itemBuilder: (context, i) {
                final skin = g.value.skins[i];
                return _SkinCard(
                  key: ValueKey('admin-skin-${skin.item.id}'),
                  skin: skin,
                  catalog: data.catalog,
                  controller: widget.controller,
                  art: _art,
                  onTap: () => openPage<void>(
                    context,
                    AdminSkinDetailPage(
                      skin: skin,
                      catalog: data.catalog,
                      controller: widget.controller,
                      art: _art,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
      ],
    );
  }
}

/// A small badge with a skin's status.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.skin);
  final AdminSkin skin;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(skin.status);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          statusText(skin),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// A card of the viewer: portrait, name, role, rarity and status.
class _SkinCard extends StatelessWidget {
  const _SkinCard({
    super.key,
    required this.skin,
    required this.catalog,
    required this.controller,
    required this.art,
    required this.onTap,
  });
  final AdminSkin skin;
  final WardrobeCatalog catalog;
  final AppController controller;
  final RunnerArt? art;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = skin.item;
    final theme = Theme.of(context);
    final colors = rarityColors(catalog, item);
    final rarities = catalog.raritiesOf(item);
    final role = item.role;
    final line = item.kind != WardrobeKind.character
        ? item.kind.singular
        : role == null
        ? null
        : item.unique
        ? uniqueRoleLine(role)
        : role.isFunction
        ? role.role
        : 'als ${role.role}';
    final dim = skin.status == AdminSkinStatus.disabled;
    return Semantics(
      button: true,
      label:
          '${item.name}, ${line ?? item.kind.singular}, '
          '${rarities.map((r) => r.name).join(', ')}, ${statusText(skin)}',
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: item.unique ? holoInk : wardrobeInk,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Opacity(
                          opacity: dim ? .7 : 1,
                          child: WardrobeItemArt(
                            item: item,
                            controller: controller,
                            art: art,
                            antique: catalog.rarityOf(item).antique,
                            small: true,
                          ),
                        ),
                        if (item.unique)
                          const IgnorePointer(
                            child: HoloOverlay(animate: false, strength: .25),
                          ),
                        Positioned(
                          left: 4,
                          top: 4,
                          right: 4,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: _StatusBadge(skin),
                          ),
                        ),
                        if (_withoutPicture(item))
                          const Positioned(
                            right: 4,
                            bottom: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0xCC000000),
                                borderRadius: BorderRadius.all(
                                  Radius.circular(6),
                                ),
                              ),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                child: Text(
                                  'ohne Bild',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    gradient: item.unique
                        ? holoGradient
                        : rarityGradient(colors),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (line != null)
                          Text(
                            line,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        const Spacer(),
                        Text(
                          rarities.map((r) => r.name).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: StageTheme.legible(
                              colors.first,
                              theme.colorScheme.surface,
                              minimum: 3,
                            ),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the big stage of a figure shows: the game's showcase loop, or one
/// of its moves on its own.
enum _Move {
  stage('Bühne'),
  run('Laufzyklus'),
  fly('fly'),
  dangle('dangle'),
  cheer('cheer'),
  crash('crash');

  const _Move(this.label);
  final String label;
}

/// One skin in the viewer: a figure on the flying wire with its moves
/// (the run cycle runA → passA → runB → passB, fly, dangle, cheer, crash)
/// and every pose of its atlas; a backdrop with its obstacle set and
/// collectibles; an obstacle set's obstacles; and all it is on the server.
class AdminSkinDetailPage extends StatefulWidget {
  const AdminSkinDetailPage({
    super.key,
    required this.skin,
    required this.catalog,
    required this.controller,
    this.art,
  });
  final AdminSkin skin;
  final WardrobeCatalog catalog;
  final AppController controller;
  final RunnerArt? art;

  @override
  State<AdminSkinDetailPage> createState() => _AdminSkinDetailPageState();
}

class _AdminSkinDetailPageState extends State<AdminSkinDetailPage> {
  late RunnerArt? _base = widget.art;
  RunnerArt? _dressed;
  bool _dressing = true, _playing = true;
  _Move _move = _Move.stage;

  // The pictures of a backdrop or obstacle set, as far as they load.
  ui.Image? _backdrop, _obstacles, _collectibles;

  WardrobeItem get item => widget.skin.item;

  @override
  void initState() {
    super.initState();
    if (_base == null) {
      RunnerArt.load().then((art) {
        if (!mounted) return;
        setState(() => _base = art);
        _prepare();
      });
    } else {
      _prepare();
    }
  }

  Future<void> _prepare() async {
    final base = _base;
    if (base == null) {
      if (mounted) setState(() => _dressing = false);
      return;
    }
    switch (item.kind) {
      case WardrobeKind.character:
        final dressed = await dressFigure(base, item, widget.controller);
        if (mounted) {
          setState(() {
            _dressed = dressed;
            _dressing = false;
          });
        }
      case WardrobeKind.backdrop || WardrobeKind.obstacles:
        bool fits(ui.Image? image) =>
            image != null &&
            image.width == base.atlas.width &&
            image.height == base.atlas.height;
        final backdrop = item.kind == WardrobeKind.backdrop;
        final images = await Future.wait([
          WardrobePictures.load(
            widget.controller,
            backdrop ? item.image : null,
          ),
          WardrobePictures.load(
            widget.controller,
            backdrop ? item.obstacles : item.image,
          ),
          WardrobePictures.load(
            widget.controller,
            backdrop ? item.collectibles : null,
          ),
        ]);
        if (!mounted) return;
        setState(() {
          _backdrop = images[0];
          _obstacles = fits(images[1]) ? images[1] : null;
          _collectibles = fits(images[2]) ? images[2] : null;
          _dressing = false;
        });
      case WardrobeKind.fx:
        setState(() => _dressing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = widget.skin, catalog = widget.catalog;
    final theme = Theme.of(context);
    final colors = rarityColors(catalog, item);
    final rarities = catalog.raritiesOf(item);
    final role = item.role;
    final release = skin.release;
    final facts = <(String, String)>[
      ('Name', item.name),
      if (role != null) ...[
        (role.isFunction ? 'Aufgabe' : 'Rolle', role.role),
        if (role.play case final play?) ('Stück', play),
        if (role.year case final year?) ('Jahr', '$year'),
      ],
      ('Art', item.kind.singular),
      ('Seltenheit', rarities.map((r) => r.name).join(' · ')),
      if (catalog.labelOf(item) case final label?) ('Abteilung', label),
      ('Status', statusText(skin)),
      if (_withoutPicture(item))
        ('Bild', 'fehlt: das Spiel zeigt die Standard-Grafik'),
      if (item.placeholder) ('Bild', 'Platzhalter: Standard-Grafik getönt'),
      if (release != null)
        (
          'Release',
          [
            release.name,
            if (release.startsAt case final at?) _date.format(at),
            switch (release.part) {
              'gated' => 'gated bis zum Start',
              'free' => 'für alle frei',
              _ => release.active ? 'gestartet' : 'noch nicht gestartet',
            },
          ].join(' · '),
        ),
      if (skin.unlock case final unlock?) ('Freischaltung', unlock),
      if (skin.milestoneKm case final km?)
        ('Ensemble', 'Belohnung bei ${kmText((km * 1000).round())}'),
      if (item.importance case final importance?)
        ('Wichtigkeit', '$importance von 100'),
      if (item.personId case final person?) ('Person', '#$person'),
      ('ID', item.id),
    ];
    final details = <Widget>[
      Text(
        item.name,
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
        ),
      ),
      if (role != null)
        Text(
          item.unique ? uniqueRoleLine(role) : role.line,
          style: theme.textTheme.titleSmall,
        ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final status in skin.statuses)
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: CircleAvatar(
                radius: 5,
                backgroundColor: _statusColor(status),
              ),
              label: Text(status.label),
            ),
          if (item.placeholder)
            const Chip(
              visualDensity: VisualDensity.compact,
              label: Text('Platzhalter'),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            children: [
              for (final (name, value) in facts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: MergeSemantics(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 104,
                          child: Text(
                            name,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            value,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      if (item.rarityReason case final reason?) ...[
        const SizedBox(height: 12),
        Text(
          'Warum ${catalog.rarityOf(item).name}?',
          style: theme.textTheme.labelLarge,
        ),
        Text(reason, style: theme.textTheme.bodyMedium),
      ],
      ..._extras(context),
    ];
    final stage = _stage(context, colors.first);
    return Scaffold(
      appBar: AppBar(title: Text(item.name)),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 720 &&
                constraints.maxWidth > constraints.maxHeight;
            final side = max(16.0, (constraints.maxWidth - 1100) / 2);
            if (wide) {
              return Padding(
                padding: EdgeInsets.fromLTRB(side, 12, side, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          SizedBox(
                            height: min(420, constraints.maxHeight * .6),
                            child: stage,
                          ),
                          ..._moves(context),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      flex: 6,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: details,
                      ),
                    ),
                  ],
                ),
              );
            }
            final height = min(
              constraints.maxWidth * .82,
              max(220.0, constraints.maxHeight * .45),
            );
            return ListView(
              padding: EdgeInsets.fromLTRB(side, 12, side, 24),
              children: [
                SizedBox(height: height, child: stage),
                ..._moves(context),
                const SizedBox(height: 16),
                ...details,
              ],
            );
          },
        ),
      ),
    );
  }

  /// The big picture: a figure on the wire, else the skin's own picture.
  Widget _stage(BuildContext context, Color glow) {
    final dressed = _dressed;
    final holo = item.unique;
    final Widget content;
    if (dressed != null) {
      content = _move == _Move.stage
          ? FigureShowcase(
              key: ValueKey('admin-showcase-${item.id}'),
              art: dressed,
              glow: glow,
              playing: _playing,
            )
          : _MoveStage(
              key: ValueKey('admin-move-${item.id}-${_move.name}'),
              art: dressed,
              move: _move,
              glow: glow,
              playing: _playing,
            );
    } else if (item.kind == WardrobeKind.backdrop && _backdrop != null) {
      content = RawImage(image: _backdrop, fit: BoxFit.cover);
    } else if (item.kind == WardrobeKind.backdrop &&
        item.isDefault &&
        _base != null) {
      content = RawImage(image: _base!.backdrop, fit: BoxFit.cover);
    } else {
      content = Padding(
        padding: const EdgeInsets.all(24),
        child: WardrobeItemArt(
          item: item,
          controller: widget.controller,
          art: _base,
          antique: widget.catalog.rarityOf(item).antique,
        ),
      );
    }
    return Semantics(
      container: true,
      image: true,
      label: dressed != null
          ? '${item.name}: ${_move == _Move.stage ? 'läuft, fliegt und jubelt' : _move.label}'
          : item.name,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: holo ? holoInk : wardrobeInk,
            border: Border.all(
              color: holo
                  ? const Color(0xCCE6DAFF)
                  : glow.withValues(alpha: .5),
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeSemantics(child: content),
              if (holo)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: HoloOverlay(animate: true, strength: .3),
                  ),
                ),
              if (_dressing)
                const Positioned(
                  right: 12,
                  top: 12,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (dressed != null)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: IconButton.filledTonal(
                    key: const ValueKey('admin-skin-play'),
                    tooltip: _playing
                        ? 'Animation anhalten'
                        : 'Animation abspielen',
                    onPressed: () => setState(() => _playing = !_playing),
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The choice of moves and every pose of the atlas, for figures.
  List<Widget> _moves(BuildContext context) {
    final dressed = _dressed;
    final theme = Theme.of(context);
    if (item.kind != WardrobeKind.character) return const [];
    if (dressed == null) {
      return [
        if (!_dressing)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              item.image == null
                  ? 'Kein eigener Atlas: die Figur zeigt ihr Bild.'
                  : 'Atlas lädt nicht oder hat falsche Maße: nur das Bild.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ];
    }
    return [
      const SizedBox(height: 10),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final m in _Move.values)
            ChoiceChip(
              key: ValueKey('admin-move-${m.name}'),
              label: Text(m.label),
              selected: _move == m,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => setState(() => _move = m),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Text('Alle Posen', style: theme.textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final sprite in const [
            RunnerSprite.runA,
            RunnerSprite.passA,
            RunnerSprite.runB,
            RunnerSprite.passB,
            RunnerSprite.fly,
            RunnerSprite.dangle,
            RunnerSprite.cheer,
            RunnerSprite.crash,
          ])
            _FrameTile(
              key: ValueKey('admin-pose-${sprite.name}'),
              art: dressed,
              sprite: sprite,
            ),
        ],
      ),
    ];
  }

  /// Obstacles and collectibles of a backdrop or obstacle set.
  List<Widget> _extras(BuildContext context) {
    final base = _base;
    if (base == null) return const [];
    final theme = Theme.of(context);
    final filter = tintFilter(item.tint);
    Widget sprites(
      String title,
      ui.Image atlas,
      List<RunnerSprite> list, [
      Map<String, String> names = const {},
    ]) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final sprite in list)
              _FrameTile(
                art: base,
                sprite: sprite,
                image: atlas,
                filter: filter,
                label: names[sprite.name] ?? sprite.name,
              ),
          ],
        ),
      ],
    );
    const obstacles = [
      RunnerSprite.crate,
      RunnerSprite.lamp,
      RunnerSprite.sandbag,
      RunnerSprite.flat,
      RunnerSprite.drum,
      RunnerSprite.truss,
      RunnerSprite.drop,
    ];
    const pickups = [RunnerSprite.rose, RunnerSprite.mask, RunnerSprite.star];
    final missing = <String>[
      if (item.kind == WardrobeKind.backdrop &&
          item.image != null &&
          _backdrop == null &&
          !_dressing)
        'Hintergrundbild lädt nicht',
      if (item.kind == WardrobeKind.backdrop &&
          item.obstacles != null &&
          _obstacles == null &&
          !_dressing)
        'Hindernis-Sheet lädt nicht oder hat falsche Maße',
      if (item.kind == WardrobeKind.backdrop &&
          item.collectibles != null &&
          _collectibles == null &&
          !_dressing)
        'Sammel-Sheet lädt nicht oder hat falsche Maße',
      if (item.kind == WardrobeKind.obstacles &&
          item.image != null &&
          _obstacles == null &&
          !_dressing)
        'Hindernis-Sheet lädt nicht oder hat falsche Maße',
    ];
    return switch (item.kind) {
      WardrobeKind.backdrop => [
        sprites(
          _obstacles == null ? 'Hindernisse (Standard)' : 'Eigene Hindernisse',
          _obstacles ?? base.atlas,
          obstacles,
        ),
        sprites(
          _collectibles == null
              ? 'Sammelobjekte (Standard)'
              : 'Eigene Sammelobjekte',
          _collectibles ?? base.atlas,
          pickups,
          item.collectibleNames,
        ),
        for (final m in missing)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(m, style: theme.textTheme.bodySmall),
          ),
      ],
      WardrobeKind.obstacles => [
        sprites('Hindernisse', _obstacles ?? base.atlas, obstacles),
        for (final m in missing)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(m, style: theme.textTheme.bodySmall),
          ),
      ],
      _ => const [],
    };
  }
}

/// One pose of an atlas, framed, with its wire point; [image] and
/// [filter] draw another layer than the figure's (obstacles, pickups).
class _FrameTile extends StatelessWidget {
  const _FrameTile({
    super.key,
    required this.art,
    required this.sprite,
    this.image,
    this.filter,
    this.label,
  });
  final RunnerArt art;
  final RunnerSprite sprite;
  final ui.Image? image;
  final ColorFilter? filter;
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label ?? sprite.name,
    image: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: wardrobeInk,
            borderRadius: BorderRadius.circular(8),
          ),
          child: CustomPaint(
            painter: _FramePainter(art, sprite, image, filter),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label ?? sprite.name,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    ),
  );
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.art, this.sprite, this.image, this.filter);
  final RunnerArt art;
  final RunnerSprite sprite;
  final ui.Image? image;
  final ColorFilter? filter;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(6);
    final scale = min(r.width / sprite.width, r.height / sprite.height);
    final dst = Rect.fromCenter(
      center: r.center,
      width: sprite.width * scale,
      height: sprite.height * scale,
    );
    final paint = image == null
        ? art.paintOf(sprite)
        : (Paint()
            ..filterQuality = FilterQuality.medium
            ..colorFilter = filter);
    canvas.drawImageRect(image ?? art.imageOf(sprite), sprite.rect, dst, paint);
    if (image == null && sprite.layer == RunnerLayer.runner) {
      // The wire point of this pose.
      final at = dst.topLeft + art.harnessOf(sprite) * scale;
      canvas.drawCircle(at, 2.5, Paint()..color = const Color(0xFFE0A23A));
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.art != art ||
      old.sprite != sprite ||
      old.image != image ||
      old.filter != filter;
}

/// One move of a figure on its own, looped on a small stage: the run cycle
/// at the game's pace, flying, dangling, cheering or the crash.
class _MoveStage extends StatefulWidget {
  const _MoveStage({
    super.key,
    required this.art,
    required this.move,
    required this.glow,
    required this.playing,
  });
  final RunnerArt art;
  final _Move move;
  final Color glow;
  final bool playing;

  @override
  State<_MoveStage> createState() => _MoveStageState();
}

class _MoveStageState extends State<_MoveStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _run();
  }

  @override
  void didUpdateWidget(_MoveStage old) {
    super.didUpdateWidget(old);
    _run();
  }

  void _run() {
    if (!widget.playing || MediaQuery.disableAnimationsOf(context)) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.infinite,
      painter: _MovePainter(widget.art, widget.move, _loop, widget.glow),
    ),
  );
}

class _MovePainter extends CustomPainter {
  _MovePainter(this.art, this.move, this.loop, this.glow)
    : super(repaint: loop);
  final RunnerArt art;
  final _Move move;
  final Animation<double> loop;
  final Color glow;

  static final _rope = Paint()
    ..color = const Color(0xFFBDB29C)
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final time = loop.value * 4;
    final floor = size.height * .86;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF151A17), Color(0xFF1D2420)],
        ).createShader(rect),
    );
    final cx = size.width / 2;
    canvas.drawCircle(
      Offset(cx, floor - size.height * .3),
      size.height * .5,
      Paint()
        ..shader =
            RadialGradient(
              colors: [glow.withValues(alpha: .28), glow.withValues(alpha: 0)],
            ).createShader(
              Rect.fromCircle(
                center: Offset(cx, floor - size.height * .3),
                radius: size.height * .5,
              ),
            ),
    );
    canvas.drawRect(
      Rect.fromLTRB(0, floor, size.width, size.height),
      Paint()..color = const Color(0xFF3B2A1E),
    );
    if (move == _Move.run) {
      // The planks pass by as on the moving stage.
      final spacing = size.height * .22;
      final shift = (time * size.height * .55) % spacing;
      final plank = Paint()
        ..color = const Color(0xFF2C1F16)
        ..strokeWidth = 2;
      for (var x = -shift; x < size.width; x += spacing) {
        canvas.drawLine(Offset(x, floor), Offset(x, size.height), plank);
      }
    }
    canvas.drawRect(
      Rect.fromLTWH(0, floor - 1, size.width, 3),
      Paint()..color = const Color(0xFF6B4A30),
    );
    final (sprite, lift, angle, wire) = switch (move) {
      _Move.run => (RunnerSprite.stride(time * .6), 0.0, 0.0, false),
      _Move.fly => (
        RunnerSprite.fly,
        .55 + .08 * sin(time * pi),
        -.06 + .04 * sin(time * pi),
        true,
      ),
      _Move.dangle => (RunnerSprite.dangle, .5, .12 * sin(time * pi), true),
      _Move.cheer => (
        RunnerSprite.cheer,
        .06 * sin(time * 2 * pi).abs(),
        0.0,
        false,
      ),
      _Move.crash || _Move.stage => (RunnerSprite.crash, 0.0, 0.0, false),
    };
    // The cheer, the tallest pose, takes half the stage's height.
    final scale = size.height * .5 / RunnerSprite.cheer.height;
    final width = sprite.width * scale, height = sprite.height * scale;
    final range = size.height * .3;
    final Rect dst;
    if (sprite == RunnerSprite.fly) {
      final middle =
          floor - lift * range - RunnerSprite.runA.height * scale / 2;
      dst = Rect.fromCenter(
        center: Offset(cx, middle),
        width: width,
        height: height,
      );
    } else {
      final bottom = floor - lift * range + size.height * .01;
      dst = Rect.fromLTWH(cx - width / 2, bottom - height, width, height);
    }
    if (wire) {
      final harness = dst.topLeft + art.harnessOf(sprite) * scale;
      canvas.drawLine(Offset(harness.dx, 0), harness, _rope);
    }
    canvas.save();
    if (angle != 0) {
      final pivot = dst.center;
      canvas
        ..translate(pivot.dx, pivot.dy)
        ..rotate(angle)
        ..translate(-pivot.dx, -pivot.dy);
    }
    canvas.drawImageRect(
      art.imageOf(sprite),
      sprite.rect,
      dst,
      art.paintOf(sprite),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MovePainter old) =>
      old.art != art ||
      old.move != move ||
      old.loop != loop ||
      old.glow != glow;
}
