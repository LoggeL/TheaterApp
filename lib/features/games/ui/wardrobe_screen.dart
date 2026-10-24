import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../data/wardrobe_api.dart';
import '../domain/stage_runner.dart';
import 'crate_opening.dart';
import 'stage_runner_art.dart';
import 'stage_runner_fx.dart' show obstacleName;
import 'stage_runner_look.dart';
import 'stage_runner_sound.dart';
import 'wardrobe_cards.dart';

/// Opens the wardrobe; [onChanged] gets every new state of it.
Future<void> openWardrobe(
  BuildContext context,
  AppController controller, {
  Wardrobe? wardrobe,
  required RunnerSound sound,
  ValueChanged<Wardrobe>? onChanged,
}) => openPage<void>(
  context,
  WardrobeScreen(
    controller: controller,
    initial: wardrobe,
    sound: sound,
    onChanged: onChanged,
  ),
);

final _number = NumberFormat.decimalPattern('de');

/// "1.234 m".
String metersText(int meters) => '${_number.format(meters)} m';

/// "noch 1.234 m bis zur nächsten Kiste".
String nextCrateText(RunnerProgress p) => p.complete
    ? 'Fundus komplett – neue Kostüme kommen bald.'
    : 'noch ${metersText(p.remaining)} bis zur nächsten Kiste';

/// "Garderobe" of the stage runner: costume crates to open, the collection
/// by kind with what is worn, and the statistics of the own runs.
class WardrobeScreen extends StatefulWidget {
  const WardrobeScreen({
    super.key,
    required this.controller,
    required this.sound,
    this.initial,
    this.onChanged,
  });
  final AppController controller;
  final RunnerSound sound;
  final Wardrobe? initial;

  /// Told about every new state, e.g. so the game wears the new costume.
  final ValueChanged<Wardrobe>? onChanged;

  @override
  State<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends State<WardrobeScreen> {
  late Wardrobe? _wardrobe = widget.initial;
  RunnerArt? _base = RunnerArt.loaded, _dressed;
  String? _error;
  bool _loading = false, _busy = false;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
    if (_base == null) {
      RunnerArt.load().then((art) {
        if (!mounted || art == null) return;
        setState(() => _base = art);
        _dress();
      });
    } else {
      _dress();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final w = await loadWardrobe(controller);
      if (!mounted) return;
      _update(w);
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The art in the worn costume, for the obstacles in the statistics.
  Future<void> _dress() async {
    final base = _base, w = _wardrobe;
    if (base == null || w == null) return;
    final dressed = await dressArt(base, w, controller);
    if (mounted && identical(w, _wardrobe)) setState(() => _dressed = dressed);
  }

  void _update(Wardrobe w) {
    setState(() => _wardrobe = w);
    widget.onChanged?.call(w);
    _dress();
  }

  Future<void> _open() async {
    final w = _wardrobe;
    if (w == null) return;
    final next = await showCrateOpening(
      context,
      controller: controller,
      wardrobe: w,
      sound: widget.sound,
      art: _base,
    );
    if (next != null && mounted) _update(next);
  }

  Future<void> _wear(WardrobeItem item) async {
    setState(() => _busy = true);
    try {
      final w = await wearItem(controller, item);
      if (mounted) _update(w);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _details(WardrobeItem item) {
    final w = _wardrobe!;
    final catalog = w.catalog;
    final owned = w.owns(item);
    final worn = w.worn(item.kind)?.id == item.id;
    final hint = w.lockHint(item);
    final rarities = catalog.raritiesOf(item);
    final label = catalog.labelOf(item);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 96,
                    height: 120,
                    child: WardrobeCard(
                      item: item,
                      wardrobe: w,
                      controller: controller,
                      art: _base,
                      worn: worn,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          owned ? item.name : 'Noch nicht gefunden',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            item.kind.singular,
                            ...rarities.map((r) => r.name),
                          ].join(' · '),
                          style: TextStyle(
                            color: StageTheme.legible(
                              rarities.first.color,
                              Theme.of(context).colorScheme.surface,
                              minimum: 3,
                            ),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (owned && label != null) Text(label),
                        if (owned && item.rarityReason != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              item.rarityReason!,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        if (owned && item.placeholder)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Platzhalter: die eigene Grafik kommt noch.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        if (hint != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(hint),
                          )
                        else if (!owned)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text(
                              'Kommt vielleicht aus der nächsten Kostümkiste.',
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (owned && !worn) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          Navigator.pop(context);
                          _wear(item);
                        },
                  icon: const Icon(Icons.checkroom),
                  label: const Text('Anlegen'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Garderobe'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Kostüme'),
            Tab(text: 'Statistik'),
          ],
        ),
      ),
      body: _wardrobe == null
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error ??
                              'Die Garderobe konnte nicht geladen werden.',
                        ),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Erneut laden'),
                        ),
                      ],
                    ),
            )
          : TabBarView(children: [_costumes(context), _statistics(context)]),
    ),
  );

  Widget _costumes(BuildContext context) {
    final w = _wardrobe!;
    final padding = pagePadding(context, maxWidth: 960, top: 16);
    return CustomScrollView(
      key: const PageStorageKey('wardrobe-costumes'),
      slivers: [
        SliverPadding(
          padding: padding.copyWith(bottom: 0),
          sliver: SliverToBoxAdapter(child: _crates(context, w)),
        ),
        // A kind with nothing to collect yet (only its default) stays hidden.
        for (final kind in WardrobeKind.values)
          if (w.catalog.items.any((i) => i.kind == kind && !i.isDefault))
            ..._kind(context, w, kind, padding),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _crates(BuildContext context, Wardrobe w) {
    final theme = Theme.of(context);
    final p = w.progress;
    final ready = p.crates > 0 && !p.complete;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Badge(
                  isLabelVisible: p.crates > 0,
                  label: Text('${p.crates}'),
                  child: const Icon(
                    Icons.inventory_2_outlined,
                    color: StageTheme.orange,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.crates == 0
                            ? 'Keine Kostümkiste bereit'
                            : p.crates == 1
                            ? '1 Kostümkiste bereit'
                            : '${p.crates} Kostümkisten bereit',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        '${w.collected}/${w.collectible} gesammelt',
                        key: const ValueKey('wardrobe-count'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: p.complete ? 1 : p.fraction,
                minHeight: 10,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${metersText(p.meters)} gelaufen · ${nextCrateText(p)}',
              style: theme.textTheme.bodyMedium,
            ),
            if (p.complete && p.crates > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Deine Kisten bleiben zu, bis es Neues im Fundus gibt.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('wardrobe-open'),
              onPressed: ready ? _open : null,
              icon: const Icon(Icons.inventory_2),
              label: const Text('Kiste öffnen'),
            ),
            const SizedBox(height: 16),
            _odds(context, w),
          ],
        ),
      ),
    );
  }

  /// The chance of each rarity, open like the odds of a loot box should be.
  Widget _odds(BuildContext context, Wardrobe w) {
    final theme = Theme.of(context);
    final catalog = w.catalog;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final r in catalog.rarities.reversed)
          if (catalog.collectible.any((i) => i.rarities.contains(r.id)))
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: CircleAvatar(backgroundColor: r.color, radius: 6),
              label: Text(
                w.lockedRarities.contains(r.id)
                    ? '${r.name}: gesperrt'
                    : '${r.name}: ${_percent(catalog.chance(r, w.lockedRarities))}',
                style: theme.textTheme.bodySmall,
              ),
            ),
      ],
    );
  }

  static String _percent(double share) {
    final p = share * 100;
    return '${NumberFormat(p < 10 ? '0.0' : '0', 'de').format(p)} %';
  }

  List<Widget> _kind(
    BuildContext context,
    Wardrobe w,
    WardrobeKind kind,
    EdgeInsets padding,
  ) {
    final items = w.catalog.items.where((i) => i.kind == kind).toList()
      // Defaults first, then from rare to common; owned before missing.
      ..sort((a, b) {
        if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
        final rank = w.catalog.rarityOf(b).rank - w.catalog.rarityOf(a).rank;
        if (rank != 0) return rank;
        return a.name.compareTo(b.name);
      });
    final collectible = items.where((i) => !i.isDefault);
    final owned = collectible.where(w.owns).length;
    final worn = w.worn(kind)?.id;
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(padding.left, 24, padding.right, 8),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Icon(kindIcon(kind), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  kind.plural,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text('$owned/${collectible.length}'),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: padding.left),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 132,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: .78,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) => WardrobeCard(
            key: ValueKey('wardrobe-${items[i].id}'),
            item: items[i],
            wardrobe: w,
            controller: controller,
            art: _base,
            worn: items[i].id == worn,
            onTap: () => _details(items[i]),
          ),
        ),
      ),
    ];
  }

  Widget _statistics(BuildContext context) {
    final theme = Theme.of(context);
    final s = _wardrobe!.stats;
    final most = s.deaths.isEmpty ? 1 : s.deaths.first.$2;
    Widget figure(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(value, style: theme.textTheme.headlineSmall),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
    return ListView(
      key: const PageStorageKey('wardrobe-stats'),
      padding: pagePadding(context, maxWidth: 640, top: 16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            child: Row(
              children: [
                figure(
                  s.rounds == 1 ? 'Versuch' : 'Versuche',
                  _number.format(s.rounds),
                ),
                figure('Gesamtstrecke', metersText(s.meters)),
                figure('Bestwert', _number.format(s.best)),
              ],
            ),
          ),
        ),
        if (s.creditedMeters > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              'Davon ${metersText(s.creditedMeters)} als Gutschrift für frühere Läufe (150 m je Lauf).',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Gestorben an', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                if (s.deaths.isEmpty && s.unknown == 0)
                  const Text(
                    'Noch nichts – oder alles vor der Aufschlüsselung.',
                  ),
                for (final (kind, count) in s.deaths)
                  _deathRow(context, kind, count, most),
                if (s.unknown > 0)
                  _plainRow(context, 'Unbekannt (ältere App)', s.unknown),
                if (s.untracked > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      s.untracked == 1
                          ? '1 früherer Lauf ohne Aufschlüsselung'
                          : '${_number.format(s.untracked)} frühere Läufe ohne Aufschlüsselung',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _deathRow(
    BuildContext context,
    ObstacleKind kind,
    int count,
    int most,
  ) => Padding(
    key: ValueKey('death-${kind.name}'),
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: ObstacleIcon(kind, art: _dressed ?? _base),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(obstacleName(kind))),
                  Text('$count×'),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: count / most,
                  minHeight: 6,
                  color: StageTheme.orange,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _plainRow(BuildContext context, String label, int count) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        const SizedBox(width: 40, height: 40, child: Icon(Icons.help_outline)),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
        Text('$count×'),
      ],
    ),
  );
}

/// Whether [w] has a crate waiting that can be opened.
bool crateWaiting(Wardrobe? w) =>
    w != null && w.progress.crates > 0 && !w.progress.complete;

/// A small "Garderobe" button with the number of waiting crates.
class WardrobeButton extends StatelessWidget {
  const WardrobeButton({
    super.key,
    required this.crates,
    required this.onPressed,
  });
  final int crates;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const ValueKey('runner-wardrobe'),
    onPressed: onPressed,
    icon: Badge(
      isLabelVisible: crates > 0,
      label: Text('$crates'),
      child: const Icon(Icons.checkroom),
    ),
    label: const Text('Garderobe'),
  );
}
