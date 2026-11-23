import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../data/missions_api.dart';
import '../data/wardrobe_api.dart';
import '../domain/stage_runner.dart';
import 'crate_choice.dart';
import 'crate_opening.dart';
import 'event_crates_card.dart';
import 'ensemble_card.dart';
import 'figure_detail.dart';
import 'gage_card.dart';
import 'gala.dart';
import 'missions_card.dart';
import 'next_drop.dart';
import 'pack_goals_card.dart';
import 'stage_runner_art.dart';
import 'stage_runner_fx.dart' show obstacleName;
import 'stage_runner_look.dart';
import 'stage_runner_sound.dart';
import 'unique_figures.dart';
import 'wardrobe_cards.dart';
import 'wardrobe_overview.dart';

/// Opens the wardrobe; [onChanged] gets every new state of it.
/// [initialTab]: 0 Sammlung, 1 Kisten, 2 Statistik.
Future<void> openWardrobe(
  BuildContext context,
  AppController controller, {
  Wardrobe? wardrobe,
  RunnerArt? dressed,
  required RunnerSound sound,
  ValueChanged<Wardrobe>? onChanged,
  int initialTab = 0,
}) => openPage<void>(
  context,
  WardrobeScreen(
    controller: controller,
    initial: wardrobe,
    dressed: dressed,
    sound: sound,
    onChanged: onChanged,
    initialTab: initialTab,
  ),
);

final _number = NumberFormat.decimalPattern('de');

/// "1.234 m".
String metersText(int meters) => '${_number.format(meters)} m';

/// "1.234 Punkte", "1 Punkt".
String pointsText(int points) =>
    '${_number.format(points)} ${points == 1 ? 'Punkt' : 'Punkte'}';

/// [value] in the unit the crates of [p] count: points
/// (`runnerCratePoints`), else metres (older servers).
String crateUnitText(RunnerProgress p, int value) =>
    p.inPoints ? pointsText(value) : metersText(value);

/// "noch 1.234 Punkte bis zur nächsten Kiste". With duplicates a complete
/// collection still gets crates.
String nextCrateText(RunnerProgress p) => p.complete && !p.dupes
    ? 'Fundus komplett – neue Kostüme kommen bald.'
    : 'noch ${crateUnitText(p, p.remaining)} bis zur nächsten Kiste';

/// Before a run while today's Tagesbonus is open (`runnerDailyBonus`).
const dailyBonusHint =
    'Tagesbonus: Dein erster Lauf heute zählt doppelt für die nächste Kiste.';

/// "+1.240 Punkte · Tagesbonus +1.240 · noch 376 Punkte bis zur nächsten
/// Kiste", after a run; the bonus only with [showBonus] (`runnerDailyBonus`).
/// Older servers count metres: "+812 m · Tagesbonus +812 m · …".
String runProgressText(RunnerProgress p, {bool showBonus = false}) {
  final g = p.gainedPoints;
  if (p.inPoints && g != null) {
    return [
      '+${pointsText(g.run)}',
      if (showBonus && g.bonus > 0) 'Tagesbonus +${_number.format(g.bonus)}',
      if (g.missions > 0) 'Missionen +${_number.format(g.missions)}',
      nextCrateText(p),
    ].join(' · ');
  }
  return [
    '+${metersText(p.gained)}',
    if (showBonus && p.bonus > 0) 'Tagesbonus +${metersText(p.bonus)}',
    // Only servers with `runnerMissions` send it.
    if (p.missionBonus > 0) 'Missionen +${metersText(p.missionBonus)}',
    nextCrateText(p),
  ].join(' · ');
}

/// "12.400 Punkte erspielt + 1.240 Tagesbonus + 2.850 Missionen · noch …":
/// the crate points of [p] and where they come from, the Tagesbonus part
/// when [showBonus] and there is one. Older servers: the Kistenstrecke,
/// "2.888 m gelaufen + 812 m Tagesbonus · noch …".
String crateDistanceText(RunnerProgress p, {bool showBonus = false}) {
  if (p.points case final points?) {
    final bonus = showBonus ? points.bonus : 0;
    // What is not listed apart counts as played: the parts add up to the total.
    final played = points.total - bonus - points.missions;
    final parts = [
      '${pointsText(played)} erspielt',
      if (bonus > 0) '${_number.format(bonus)} Tagesbonus',
      if (points.missions > 0) '${_number.format(points.missions)} Missionen',
    ];
    return '${parts.join(' + ')} · ${nextCrateText(p)}';
  }
  final extra = [
    if (showBonus && p.bonusMeters > 0)
      '${metersText(p.bonusMeters)} Tagesbonus',
    if (p.missionMeters > 0) '${metersText(p.missionMeters)} Missionen',
  ];
  return extra.isEmpty
      ? '${metersText(p.meters)} gelaufen · ${nextCrateText(p)}'
      : '${[metersText(p.runMeters), ...extra].join(' + ').replaceFirst(' + ', ' gelaufen + ')} · ${nextCrateText(p)}';
}

/// "+1,2 km fürs Ensemble · noch 18 km bis zur nächsten Überraschung", after
/// a run; a milestone with only the crate by its name.
String ensembleRunText(EnsembleRun e) =>
    '+${kmText(e.gained)} fürs Ensemble · noch ${kmText(e.remaining)} bis ${e.next.hidden ? 'zur nächsten Überraschung' : e.next.name}';

/// "Ensemble-Ziel erreicht – freigeschaltet: Bühnenbild „Anno 1146“!": the
/// moment a reward stops being a surprise.
String ensembleReachedText(EnsembleMilestone m) {
  final what = m.rewardId == null
      ? m.name
      : m.rewardKind == null
      ? '„${m.name}“'
      : '${m.rewardKind!.singular} „${m.name}“';
  return m.rewardId == null
      ? 'Ensemble-Ziel erreicht: $what! Eine Ensemble-Kiste wartet in der Garderobe.'
      : 'Ensemble-Ziel erreicht – freigeschaltet: $what! Eine Ensemble-Kiste wartet in der Garderobe.';
}

/// "Gage" with a figure, "1 Gage".
String gageText(int gage) => '${_number.format(gage)} Gage';

/// Calls [onEntered] once, the frame after the page's route has come in. A
/// widget of its own: reading the route ties this to every change of it (a
/// page pushed on top), and this widget alone rebuilds then, not the page.
class _AfterEntrance extends StatefulWidget {
  const _AfterEntrance({required this.onEntered, required this.child});
  final VoidCallback onEntered;
  final Widget child;

  @override
  State<_AfterEntrance> createState() => _AfterEntranceState();
}

class _AfterEntranceState extends State<_AfterEntrance> {
  Animation<double>? _entrance;

  @override
  void initState() {
    super.initState();
    // After the first frame: a pushed route's first frame is built offstage
    // for its heroes, and until then its animation reads as complete.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final entrance = ModalRoute.of(context)?.animation;
      if (entrance == null || entrance.isCompleted) {
        widget.onEntered();
      } else {
        _entrance = entrance..addStatusListener(_changed);
      }
    });
  }

  void _changed(AnimationStatus status) {
    if (!status.isCompleted) return;
    _entrance?.removeStatusListener(_changed);
    _entrance = null;
    WidgetsBinding.instance.endOfFrame.then((_) {
      if (mounted) widget.onEntered();
    });
  }

  @override
  void dispose() {
    _entrance?.removeStatusListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

enum _OwnershipFilter { all, owned, missing, buyable }

enum _ShineFilter { all, shiny, plain }

enum _WardrobeSort {
  rarity('Seltenheit'),
  ownedFirst('Besessen zuerst'),
  playYear('Stück & Jahr'),
  alpha('Name A–Z');

  const _WardrobeSort(this.label);
  final String label;
}

/// "Garderobe" of the stage runner: costume crates to open, the collection
/// by kind with what is worn, and the statistics of the own runs.
class WardrobeScreen extends StatefulWidget {
  const WardrobeScreen({
    super.key,
    required this.controller,
    required this.sound,
    this.initial,
    this.dressed,
    this.onChanged,
    this.initialTab = 0,
  });
  final AppController controller;
  final RunnerSound sound;

  /// What is known already (the game's wardrobe): on the default tab the page
  /// is there at once and the refresh waits until it has come in.
  final Wardrobe? initial;

  /// The art in the costume of [initial], if the game has it.
  final RunnerArt? dressed;

  /// Told about every new state, e.g. so the game wears the new costume.
  final ValueChanged<Wardrobe>? onChanged;

  /// The tab shown first: 0 Sammlung, 1 Kisten, 2 Statistik.
  final int initialTab;

  @override
  State<WardrobeScreen> createState() => _WardrobeScreenState();
}

class _WardrobeScreenState extends State<WardrobeScreen> {
  late Wardrobe? _wardrobe = widget.initial;
  RunnerArt? _base = RunnerArt.loaded;
  late RunnerArt? _dressed = widget.dressed;

  /// The costume of [_dressed], as [outfitOf] says; null for none yet.
  late String? _outfit = widget.dressed == null || widget.initial == null
      ? null
      : outfitOf(widget.initial!);
  String? _error;
  bool _loading = false,
      _busy = false,
      _celebrating = false,
      _celebratingUnique = false;
  WardrobeKind _selectedKind = WardrobeKind.character;
  TabController? _tabs;

  /// Items newly obtained (or upgraded to shine) during this wardrobe session.
  final Set<String> _newIds = <String>{};
  final TextEditingController _search = TextEditingController();
  String _query = '';
  String? _rarityFilter;
  _OwnershipFilter _ownership = _OwnershipFilter.all;
  _ShineFilter _shine = _ShineFilter.all;
  bool _newOnly = false;
  _WardrobeSort _sort = _WardrobeSort.rarity;

  bool get _waitForEntrance => widget.initial != null && widget.initialTab == 0;

  AppController get controller => widget.controller;
  bool get _dupes => dupesAvailable(controller);
  bool get _ensemble => ensembleAvailable(controller);
  bool get _bonus => dailyBonusAvailable(controller);
  bool get _missions => missionsAvailable(controller);
  bool get _eventCrates => eventCratesAvailable(controller);
  bool get _gala => monthlyGalaAvailable(controller);
  bool get _weekly => weeklyRewardsAvailable(controller);
  bool get _gageCrates => gageCratesAvailable(controller);
  bool get _packs => packGoalsAvailable(controller);
  bool get _unique => uniqueFiguresAvailable(controller);
  bool get _targets => crateTargetsAvailable(controller);

  int get _waitingCrates {
    final w = _wardrobe;
    if (w == null) return 0;
    // Own crates stay shut while the collection is complete and the server
    // has no duplicates: they do not wait, as in "Bereit zum Öffnen".
    return (_dupes || !w.progress.complete ? w.progress.crates : 0) +
        (_missions ? w.progress.missionCrates : 0) +
        (_ensemble && w.ensemble != null ? w.progress.ensembleCrates : 0) +
        (_eventCrates ? w.eventCrates.length : 0) +
        (_gala ? w.gala.crates : 0) +
        (_weekly ? w.weekly.crates : 0) +
        (_packs ? w.packCrates : 0);
  }

  @override
  void initState() {
    super.initState();
    if (!_waitForEntrance) _start();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _start() {
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

  /// Loads the wardrobe; false when none came.
  Future<bool> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final w = await loadWardrobe(controller);
      if (!mounted) return false;
      _update(w, recordNew: _wardrobe != null);
      _celebrate(w);
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
      return false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The art in the worn costume, for the obstacles in the statistics; only
  /// if it changed.
  Future<void> _dress() async {
    final base = _base, w = _wardrobe;
    if (base == null || w == null || outfitOf(w) == _outfit) return;
    final dressed = await dressArt(base, w, controller);
    if (mounted && identical(w, _wardrobe)) {
      setState(() => _dressed = dressed);
      _outfit = dressedOutfit(w);
    }
  }

  void _update(Wardrobe w, {bool recordNew = false}) {
    final prev = _wardrobe;
    if (recordNew && prev != null) {
      for (final id in w.owned) {
        if (!prev.owned.contains(id) && w.catalog.item(id) != null) {
          _newIds.add(id);
        }
      }
      for (final id in w.shiny) {
        if (!prev.shiny.contains(id) && w.catalog.item(id) != null) {
          _newIds.add(id);
        }
      }
    }
    _newIds.removeWhere(
      (id) => !w.owned.contains(id) || w.catalog.item(id) == null,
    );
    if (_newIds.isEmpty) _newOnly = false;
    setState(() => _wardrobe = w);
    widget.onChanged?.call(w);
    _dress();
  }

  void _markSeen(String id) {
    if (_newIds.remove(id)) {
      setState(() {
        if (_newIds.isEmpty) _newOnly = false;
      });
    }
  }

  Future<void> _open({
    bool ensemble = false,
    bool mission = false,
    bool gala = false,
    bool weekly = false,
    bool gage = false,
    EventCrate? event,
    PackGoal? packGoal,
    CrateTarget? target,
  }) async {
    final w = _wardrobe;
    if (w == null) return;
    final next = await showCrateOpening(
      context,
      controller: controller,
      wardrobe: w,
      sound: widget.sound,
      art: _base,
      ensemble: ensemble,
      mission: mission,
      gala: gala,
      weekly: weekly,
      gage: gage,
      event: event != null,
      eventCrate: event,
      packGoal: packGoal,
      target: target,
      // The next crate of the own runs is chosen again.
      chooseTarget: target == null
          ? null
          : (w) => chooseCrateTarget(
              context,
              controller: controller,
              wardrobe: w,
              art: _base,
            ),
    );
    if (next != null && mounted) {
      _update(next, recordNew: true);
      await _celebrateUnique(next);
    }
  }

  /// A reached milestone not celebrated yet: once, when the wardrobe opens;
  /// then the unique figures unlocked meanwhile.
  Future<void> _celebrate(Wardrobe w) async {
    await _celebrateEnsemble(w);
    final now = _wardrobe;
    if (mounted && now != null) await _celebrateUnique(now);
  }

  /// A unique figure unlocked and not celebrated yet: once, like an
  /// ensemble goal, right when it comes (from a crate, trade or purchase)
  /// or when the wardrobe opens.
  Future<void> _celebrateUnique(Wardrobe w) async {
    final unseen = w.uniqueFigures?.unseen ?? const <String>[];
    if (!_unique || unseen.isEmpty || _celebratingUnique || !mounted) return;
    final items = [for (final id in unseen) ?w.catalog.item(id)];
    if (items.isEmpty) return;
    _celebratingUnique = true;
    widget.sound.play(RunnerSfx.jackpot);
    final wear = await showDialog<bool>(
      context: context,
      builder: (context) => UniqueCelebration(
        items: items,
        wardrobe: w,
        controller: controller,
        art: _base,
      ),
    );
    try {
      final next = await markUniqueSeen(controller, unseen);
      if (mounted) _update(next);
    } catch (_) {
      // Shown again next time.
    } finally {
      _celebratingUnique = false;
    }
    if (wear == true && mounted) await _wear(items.last);
  }

  Future<void> _celebrateEnsemble(Wardrobe w) async {
    final e = w.ensemble;
    if (!_ensemble || e == null || e.unseen.isEmpty || _celebrating) return;
    _celebrating = true;
    widget.sound.play(RunnerSfx.jackpot);
    final reached = [for (final km in e.unseen) ?e.milestone(km)];
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => EnsembleCelebration(
        reached: reached,
        wardrobe: w,
        controller: controller,
        art: _base,
      ),
    );
    try {
      final next = await markEnsembleSeen(controller, e.unseen.last);
      if (mounted) _update(next);
    } catch (_) {
      // Shown again next time.
    }
    if (open == true && mounted) await _open(ensemble: true);
  }

  /// Wears [item]: every role is a figure of its own (`runnerRoleFigures`),
  /// so there is no role to choose; with older servers the worn role stays.
  Future<void> _wear(WardrobeItem item) async {
    setState(() => _busy = true);
    try {
      final w = await wearItem(controller, item);
      if (!mounted) return;
      _newIds.remove(item.id);
      if (_newIds.isEmpty) _newOnly = false;
      _update(w);
      final label = item.kind == WardrobeKind.character && !item.unique
          ? nameInRole(item.name, w.roleOf(item))
          : item.name;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Angelegt: $label'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Picks a random owned item (different from the worn one) for every slot
  /// with at least two owned items.
  Future<void> _randomizeOutfit(Wardrobe w) async {
    final random = Random();
    final picks = <WardrobeItem>[];
    for (final kind in WardrobeKind.values) {
      final owned = [
        for (final i in w.catalog.items)
          if (i.kind == kind && w.owns(i)) i,
      ];
      if (owned.length < 2) continue;
      final wornId = w.worn(kind)?.id;
      final choices = owned.where((i) => i.id != wornId).toList();
      if (choices.isEmpty) continue;
      picks.add(choices[random.nextInt(choices.length)]);
    }
    if (picks.isEmpty) return;
    setState(() => _busy = true);
    try {
      var latest = w;
      for (final pick in picks) {
        latest = await wearItem(controller, pick);
        _newIds.remove(pick.id);
        if (!mounted) return;
      }
      if (_newIds.isEmpty) _newOnly = false;
      _update(latest);
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              picks.length == 1
                  ? 'Zufällig angelegt: ${picks.single.name}'
                  : 'Zufalls-Outfit angelegt',
            ),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Filters the collection to missing figures of [targetPlay] (a production
  /// name or [_techFilter]).
  void _jumpToMissingPlay(String targetPlay) {
    _search.clear();
    setState(() {
      _selectedKind = WardrobeKind.character;
      _play = targetPlay;
      _person = null;
      _rarityFilter = null;
      _ownership = _OwnershipFilter.missing;
      _shine = _ShineFilter.all;
      _newOnly = false;
      _query = '';
    });
  }

  /// Where a missing collectible [item] can come from (crates, trades).
  List<String> _sourcesOf(Wardrobe w, WardrobeItem item) {
    final sources = <String>[];
    if (_targets && w.crateTargets.isNotEmpty) {
      if (w.crateTargets.any((t) => t.isRandom)) {
        sources.add('Zufallskiste');
      }
      if (item.kind == WardrobeKind.character && item.role != null) {
        final role = item.role!;
        if (role.isFunction) {
          final tech = w.crateTargets
              .where((t) => t.kind == CrateTargetKind.tech)
              .firstOrNull;
          if (tech != null) sources.add(tech.title);
        } else if (role.play != null) {
          final playTarget = w.crateTargets
              .where(
                (t) =>
                    t.kind == CrateTargetKind.play &&
                    t.play == role.play &&
                    (t.year == null || role.year == null || t.year == role.year),
              )
              .firstOrNull;
          if (playTarget != null) sources.add('Kiste „${playTarget.title}“');
        }
      }
    } else {
      sources.add('Kostümkisten');
    }
    if (_dupes) {
      final trade = w.trades
          .where((t) => item.rarities.contains(t.to))
          .firstOrNull;
      if (trade != null) {
        sources.add('Tauschvertrag (${gageText(trade.cost)})');
      }
    }
    return sources;
  }

  /// An owned figure gets a page of its own; everything else (and what is
  /// still missing, which keeps its secret) the details below.
  void _details(WardrobeItem item) {
    final w = _wardrobe!;
    _markSeen(item.id);
    if (item.kind == WardrobeKind.character && w.owns(item)) {
      openFigureDetail(
        context,
        wardrobe: w,
        item: item,
        controller: controller,
        art: _base,
        busy: _busy,
        dupes: _dupes,
        onWear: _wear,
        onMissingTap: (missing) {
          Navigator.pop(context);
          _details(missing);
        },
      );
      return;
    }
    final catalog = w.catalog;
    final owned = w.owns(item);
    final worn = w.worn(item.kind)?.id == item.id;
    final hint = w.lockHint(item) ?? rewardHint(w, item) ?? uniqueHint(w, item);
    final rarities = catalog.raritiesOf(item);
    final label = catalog.labelOf(item);
    final shiny = owned && w.isShiny(item);
    final cost = _dupes ? w.buyCost(item) : null;
    final milestone = item.reward ? w.ensemble?.rewardOf(item) : null;
    final unique = uniqueProgressOf(w, item);
    final lockProgress = !owned && !item.unique && !item.reward
        ? w.lockProgress(catalog.rarityOf(item))
        : null;
    final sources = !owned && !item.unique && !item.reward && hint == null
        ? _sourcesOf(w, item)
        : const <String>[];
    final canGoToCrates = !owned && !item.unique && !item.reward && hint == null;
    final showUniqueParts =
        !owned && item.unique && unique != null && !unique.itemSet;
    showModalBottomSheet<void>(
      isScrollControlled: true,
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                      animateShine: true,
                      showRole: false,
                      small: true,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          owned || item.reward
                              ? item.name
                              : item.unique
                              ? '???'
                              : 'Noch nicht gefunden',
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                        // "als Lucy · Creepshow 2026": the worn role; a
                        // unique figure is the character itself.
                        if (owned)
                          if (w.roleOf(item) case final playing?)
                            Text(
                              item.unique
                                  ? uniqueRoleLine(playing, unique)
                                  : playing.line,
                              key: const ValueKey('wardrobe-role'),
                              style: Theme.of(sheetContext).textTheme.titleSmall,
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
                              Theme.of(sheetContext).colorScheme.surface,
                              minimum: 3,
                            ),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (shiny)
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.auto_awesome,
                                  size: 16,
                                  color: Color(0xFFE4AE39),
                                ),
                                SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Glanz-Version',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (owned && label != null) Text(label),
                        if (owned && item.rarityReason != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              item.rarityReason!,
                              style: Theme.of(sheetContext).textTheme.bodySmall,
                            ),
                          ),
                        if (owned && item.placeholder)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Platzhalter: die eigene Grafik kommt noch.',
                              style: Theme.of(sheetContext).textTheme.bodySmall,
                            ),
                          ),
                        if (milestone != null && owned)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Ensemble-Belohnung für ${kmText(milestone.meters)} gemeinsam.',
                            ),
                          ),
                        if (owned && item.unique)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              unique?.itemSet == true
                                  ? 'Freigeschaltet: alle ${unique!.itemNoun!.many} gesammelt.'
                                  : unique?.allTechnicians == true
                                  ? 'Freigeschaltet: alle Techniker gesammelt.'
                                  : 'Freigeschaltet: alle Rollen aus ${unique?.play ?? item.role?.play ?? 'dem Stück'} gesammelt.',
                            ),
                          ),
                        if (hint != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              item.reward && milestone?.reached != true
                                  ? '$hint: für alle, sobald das Ensemble so weit gelaufen ist.'
                                  : item.unique
                                  ? unique?.itemSet == true
                                        ? '$hint. Wer alle ${unique!.itemNoun!.many} hat, bekommt die Unique-Figur dazu – nicht aus Kisten.'
                                        : unique?.allTechnicians == true
                                        ? '$hint. Wer alle Techniker hat, bekommt die Unique-Figur dazu. Sie kommt nicht aus Kisten.'
                                        : '$hint. Wer alle Rollen ${unique?.several == true ? 'dieser Stücke' : 'des Stücks'} hat, bekommt die Unique-Figur dazu – nicht aus Kisten.'
                                  : hint,
                            ),
                          )
                        else if (!owned)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text(
                              'Kommt vielleicht aus der nächsten Kostümkiste.',
                            ),
                          ),
                        if (lockProgress != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Fortschritt zum Freischalten: ${lockProgress.$1}/${lockProgress.$2}',
                              key: const ValueKey('wardrobe-lock-progress'),
                              style: Theme.of(sheetContext).textTheme.bodySmall,
                            ),
                          ),
                        // Across plays: how far each of them is.
                        if (!owned && unique != null && unique.several)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              unique.parts.map((p) => p.line).join(' · '),
                              key: const ValueKey('wardrobe-unique-parts'),
                              style: Theme.of(sheetContext).textTheme.bodySmall,
                            ),
                          ),
                        if (!owned &&
                            hint == null &&
                            _dupes &&
                            cost == null &&
                            !item.reward &&
                            !item.unique)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '${catalog.rarityOf(item).name} gibt es nur aus Kisten und Tauschverträgen.',
                              style: Theme.of(sheetContext).textTheme.bodySmall,
                            ),
                          ),
                        if (sources.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Fundorte: ${sources.join(' · ')}',
                              key: const ValueKey('wardrobe-source'),
                              style: Theme.of(sheetContext).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      sheetContext,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
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
                          Navigator.pop(sheetContext);
                          _wear(item);
                        },
                  icon: const Icon(Icons.checkroom),
                  label: const Text('Anlegen'),
                ),
              ],
              if (showUniqueParts) ...[
                const SizedBox(height: 16),
                if (unique.allTechnicians)
                  OutlinedButton.icon(
                    key: const ValueKey('wardrobe-unique-show-missing'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _jumpToMissingPlay(_techFilter);
                    },
                    icon: const Icon(Icons.filter_list),
                    label: const Text('Fehlende Techniker anzeigen'),
                  )
                else if (unique.several)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (i, p) in () {
                        final open = unique.parts
                            .where((p) => p.have < p.total)
                            .toList();
                        return open.isEmpty ? unique.parts : open;
                      }().indexed)
                        OutlinedButton.icon(
                          key: i == 0
                              ? const ValueKey('wardrobe-unique-show-missing')
                              : ValueKey(
                                  'wardrobe-unique-show-missing-${p.production}',
                                ),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            _jumpToMissingPlay(p.production);
                          },
                          icon: const Icon(Icons.filter_list),
                          label: Text('Fehlende: ${p.production}'),
                        ),
                    ],
                  )
                else
                  OutlinedButton.icon(
                    key: const ValueKey('wardrobe-unique-show-missing'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _jumpToMissingPlay(unique.production);
                    },
                    icon: const Icon(Icons.filter_list),
                    label: const Text('Fehlende Rollen anzeigen'),
                  ),
              ],
              // Too little gage: what it costs and what is missing, no
              // disabled button.
              if ((cost != null && hint == null && w.gage >= cost) ||
                  canGoToCrates) ...[
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (cost != null && hint == null && w.gage >= cost)
                      FilledButton.tonalIcon(
                        key: const ValueKey('wardrobe-buy'),
                        onPressed: _busy
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                _buy(item, cost);
                              },
                        icon: const Icon(Icons.shopping_bag_outlined),
                        label: Text('Gezielt holen · ${gageText(cost)}'),
                      ),
                    if (canGoToCrates)
                      OutlinedButton.icon(
                        key: const ValueKey('wardrobe-to-crates'),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _tabs?.animateTo(1);
                        },
                        icon: const Icon(Icons.inventory_2_outlined),
                        label: Text(
                          _waitingCrates > 0
                              ? 'Zu den Kisten ($_waitingCrates)'
                              : 'Zu den Kisten',
                        ),
                      ),
                  ],
                ),
              ],
              if (cost != null && hint == null && w.gage < cost)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Gezielt holen kostet ${gageText(cost)} – dir fehlen noch ${gageText(cost - w.gage)}. Gage gibt es für Duplikate.',
                    key: const ValueKey('wardrobe-buy-missing'),
                    style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        sheetContext,
                      ).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              key: const ValueKey('deal-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _buy(WardrobeItem item, int cost) async {
    final w = _wardrobe!;
    final ok = await _confirm(
      'Gezielt holen?',
      '${item.kind.singular} der Stufe ${w.catalog.rarityOf(item).name} für ${gageText(cost)}. Danach bleiben ${gageText(w.gage - cost)}.',
      'Für ${gageText(cost)} holen',
    );
    if (!ok || !mounted) return;
    await _deal(() => buyItem(controller, item));
  }

  /// A crate for gage: the same choice as a crate of the own runs, then the
  /// confirmation every purchase has, then it opens at once.
  Future<void> _buyCrate(int price) async {
    final w = _wardrobe!;
    CrateTarget? target;
    if (_targets && w.crateTargets.isNotEmpty) {
      target = await chooseCrateTarget(
        context,
        controller: controller,
        wardrobe: w,
        art: _base,
      );
      if (target == null || !mounted) return;
    }
    final ok = await _confirm(
      'Kiste kaufen?',
      '${target?.name ?? 'Eine Kiste'} für ${gageText(price)}. Danach bleiben ${gageText(w.gage - price)}.',
      'Für ${gageText(price)} kaufen',
    );
    if (!ok || !mounted) return;
    await _open(gage: true, target: target);
  }

  /// The Tauschvertrag of [t]: the confirmation, then the trade.
  Future<void> _tradeOffer(TradeOption t) async {
    final w = _wardrobe!;
    final name = _rarity(w, t.to).name;
    final ok = await _confirm(
      'Tauschvertrag unterschreiben?',
      '${gageText(t.cost)} gegen ein zufälliges $name-Teil, das dir noch fehlt. Danach bleiben ${gageText(w.gage - t.cost)}.',
      'Unterschreiben',
    );
    if (!ok || !mounted) return;
    await _deal(() => tradeGage(controller, t.from));
  }

  static WardrobeRarity _rarity(Wardrobe w, String id) =>
      w.catalog.rarities.where((r) => r.id == id).firstOrNull ??
      WardrobeRarity.unknown;

  /// Runs a trade or purchase and shows what it brought.
  Future<void> _deal(Future<GageDeal> Function() run) async {
    setState(() => _busy = true);
    try {
      final deal = await run();
      if (!mounted) return;
      _update(deal.wardrobe, recordNew: true);
      widget.sound.play(RunnerSfx.reveal);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(deal.outcome.line ?? 'Neu in der Garderobe'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 140,
                height: 175,
                child: WardrobeCard(
                  key: const ValueKey('deal-item'),
                  item: deal.item,
                  wardrobe: deal.wardrobe,
                  controller: controller,
                  art: _base,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                deal.item.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (deal.wardrobe.roleOf(deal.item) case final playing?)
                Text(playing.line, textAlign: TextAlign.center),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _wear(deal.item);
              },
              child: const Text('Anlegen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fertig'),
            ),
          ],
        ),
      );
      if (mounted) await _celebrateUnique(deal.wardrobe);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    final page = DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      child: Builder(
        builder: (context) {
          _tabs = DefaultTabController.maybeOf(context);
          return Scaffold(
            appBar: AppBar(
              title: _title(),
              // Room for the countdown line under the title in large text.
              toolbarHeight: _wardrobe?.nextDrop == null
                  ? null
                  : max(
                      kToolbarHeight,
                      MediaQuery.textScalerOf(context).scale(44) + 12,
                    ),
              bottom: TabBar(
                isScrollable: largeText,
                tabAlignment: largeText ? TabAlignment.start : TabAlignment.fill,
                tabs: [
                  Tab(
                    key: const ValueKey('wardrobe-tab-collection'),
                    height: largeText ? 64 : null,
                    child: Semantics(
                      label: _newIds.isEmpty
                          ? 'Sammlung'
                          : 'Sammlung, ${_newIds.length} neu',
                      excludeSemantics: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Badge.count(
                          offset: const Offset(14, -6),
                          count: _newIds.length,
                          isLabelVisible: _newIds.isNotEmpty,
                          child: const Text('Sammlung'),
                        ),
                      ),
                    ),
                  ),
                  Tab(
                    key: const ValueKey('wardrobe-tab-crates'),
                    height: largeText ? 64 : null,
                    child: Semantics(
                      label: 'Kisten, $_waitingCrates wartend',
                      excludeSemantics: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Badge.count(
                          // Beside the word, not over its last letter.
                          offset: const Offset(14, -6),
                          count: _waitingCrates,
                          isLabelVisible: _waitingCrates > 0,
                          child: const Text('Kisten'),
                        ),
                      ),
                    ),
                  ),
                  Tab(
                    key: const ValueKey('wardrobe-tab-stats'),
                    height: largeText ? 64 : null,
                    text: 'Statistik',
                  ),
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
                : TabBarView(
                    children: [
                      // Below the DefaultTabController: the collection and the
                      // crates switch to each other with it.
                      Builder(builder: _costumes),
                      Builder(builder: _rewards),
                      Builder(builder: _statistics),
                    ],
                  ),
          );
        },
      ),
    );
    return _waitForEntrance
        ? _AfterEntrance(onEntered: _start, child: page)
        : page;
  }

  /// "Garderobe", with the countdown to a content drop less than a day away
  /// under it; at zero a fresh wardrobe brings the new costumes.
  Widget _title() {
    final drop = _wardrobe?.nextDrop;
    if (drop == null) return const Text('Garderobe');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Garderobe'),
        NextDropLine(
          drop: drop,
          // Another load under way: asked again in a while.
          onDue: () async => mounted && !_loading && await _load(),
        ),
      ],
    );
  }

  Widget _costumes(BuildContext context) {
    final w = _wardrobe!;
    final padding = pagePadding(context, maxWidth: 960, top: 16);
    final kinds = [
      for (final kind in WardrobeKind.values)
        if (w.catalog.items.any((i) => i.kind == kind && !i.isDefault)) kind,
    ];
    final selected = kinds.contains(_selectedKind)
        ? _selectedKind
        : kinds.firstOrNull;
    final overview = WardrobeOverview.of(w, unique: _unique);
    final plays = overview.plays;
    final outfitBar = _outfitBar(context, w, kinds, selected);
    return CustomScrollView(
      key: const PageStorageKey('wardrobe-costumes'),
      slivers: [
        SliverPadding(
          padding: padding.copyWith(bottom: 8),
          sliver: SliverToBoxAdapter(
            child: CollectionSummaryCard(
              overview: overview,
              waitingCrates: _waitingCrates,
              onCrates: () => DefaultTabController.of(context).animateTo(1),
              selectedRarity: _rarityFilter,
              onSelectRarity: (r) => setState(() => _rarityFilter = r),
            ),
          ),
        ),
        if (outfitBar != null)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, 8),
            sliver: SliverToBoxAdapter(child: outfitBar),
          ),
        // The kinds wrap instead of scrolling: on a phone the last one
        // goes to a line of its own rather than being cut off.
        if (kinds.length > 1)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(padding.left, 4, padding.right, 8),
            sliver: SliverToBoxAdapter(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final kind in kinds)
                    ChoiceChip(
                      key: ValueKey('wardrobe-kind-${kind.name}'),
                      label: Text(switch (overview.kinds[kind]) {
                        final t? => '${kind.plural} · ${t.owned}/${t.total}',
                        null => kind.plural,
                      }),
                      selected: selected == kind,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _selectedKind = kind),
                    ),
                ],
              ),
            ),
          ),
        if (plays.isNotEmpty && selected == WardrobeKind.character)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(padding.left, 4, padding.right, 4),
            sliver: SliverToBoxAdapter(
              child: PlayProgressStrip(
                plays: plays,
                selected: _play == _techFilter ? 'Technik' : _play,
                onSelect: (p) => setState(() {
                  final value = p.technicians ? _techFilter : p.production;
                  _play = _play == value ? null : value;
                }),
              ),
            ),
          ),
        if (selected != null)
          ..._kind(context, w, overview, selected, padding, kinds.length > 1)
        else
          SliverPadding(
            padding: padding,
            sliver: const SliverToBoxAdapter(
              child: Text('Im Fundus gibt es noch nichts zu sammeln.'),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  /// Compact summary of the currently equipped outfit across active slots,
  /// with a one-tap random-outfit button when at least one slot has choices.
  Widget? _outfitBar(
    BuildContext context,
    Wardrobe w,
    List<WardrobeKind> kinds,
    WardrobeKind? selected,
  ) {
    final slots = [
      for (final kind in kinds)
        if (w.worn(kind) case final item?) (kind, item),
    ];
    if (slots.isEmpty) return null;
    final canRandomize = kinds.any(
      (kind) => w.catalog.items.where((i) => i.kind == kind && w.owns(i)).length >= 2,
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const ValueKey('wardrobe-outfit-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (kind, item) in slots)
            InkWell(
              key: ValueKey('wardrobe-outfit-${kind.name}'),
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                if (kinds.length > 1 && selected != kind) {
                  setState(() => _selectedKind = kind);
                } else {
                  _details(item);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: selected == kind && kinds.length > 1
                      ? StageTheme.selectedTint(theme.brightness)
                      : scheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: ColoredBox(
                          color: wardrobeInk,
                          child: WardrobeItemArt(
                            item: item.inRole(w.variantOf(item)),
                            controller: controller,
                            art: _base,
                            small: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${kind.singular}: ${item.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (canRandomize)
            TextButton.icon(
              key: const ValueKey('wardrobe-random-outfit'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              onPressed: _busy ? null : () => _randomizeOutfit(w),
              icon: const Icon(Icons.shuffle, size: 16),
              label: const Text('Zufalls-Outfit'),
            ),
        ],
      ),
    );
  }

  /// The crates: what waits to be opened, the gage and its price list,
  /// the next crate of the own runs and the ways to more crates.
  Widget _rewards(BuildContext context) {
    final w = _wardrobe!;
    final theme = Theme.of(context);
    final ways = <Widget>[
      if (_missions)
        _goalSection(
          id: 'missions',
          icon: Icons.flag_outlined,
          title: 'Tagesmissionen',
          summary: w.progress.missionCrates > 0
              ? w.progress.missionCrates == 1
                    ? '1 Missionskiste bereit'
                    : '${w.progress.missionCrates} Missionskisten bereit'
              : 'Deine Aufgaben für heute',
          child: DailyMissionsCard(
            controller: controller,
            crates: w.progress.missionCrates,
            collectibleNames:
                w.worn(WardrobeKind.backdrop)?.collectibleNames ?? const {},
            onOpenCrate: _busy ? null : () => _open(mission: true),
          ),
        ),
      if (_ensemble && w.ensemble != null)
        _goalSection(
          id: 'ensemble',
          icon: Icons.groups_outlined,
          title: 'Ensemble',
          summary: w.progress.ensembleCrates > 0
              ? w.progress.ensembleCrates == 1
                    ? '1 Ensemble-Kiste bereit'
                    : '${w.progress.ensembleCrates} Ensemble-Kisten bereit'
              : 'Gemeinsam ${kmText(w.ensemble!.meters)} gelaufen',
          child: EnsembleCard(
            wardrobe: w,
            controller: controller,
            art: _base,
            onOpen: _busy ? null : () => _open(ensemble: true),
            onReward: _details,
          ),
        ),
      if (_packs && w.packGoals.isNotEmpty)
        _goalSection(
          id: 'packs',
          icon: Icons.collections_outlined,
          title: 'Skinpacks',
          summary: switch ((
            w.packCrates,
            w.packGoals.where((g) => !g.reached).length,
          )) {
            (1, _) => '1 Set-Kiste bereit',
            (final n, _) when n > 1 => '$n Set-Kisten bereit',
            (_, 0) => 'Alle Ziele erreicht',
            (_, 1) => '1 Ziel läuft',
            (_, final n) => '$n Ziele laufen',
          },
          child: PackGoalsCard(
            goals: w.packGoals,
            onOpen: _busy ? null : (goal) => _open(packGoal: goal),
          ),
        ),
      if (_gala && w.gala.trophies.isNotEmpty)
        _goalSection(
          id: 'gala',
          icon: Icons.theater_comedy_outlined,
          title: 'Monatsgala',
          summary: w.gala.trophies.length == 1
              ? '1 Maske in der Vitrine'
              : '${w.gala.trophies.length} Masken in der Vitrine',
          child: GalaVitrineCard(
            gala: w.gala,
            controller: controller,
            art: _base,
            showCrates: false,
          ),
        ),
    ];
    return ListView(
      key: const PageStorageKey('wardrobe-rewards'),
      padding: pagePadding(context, maxWidth: 640, top: 16),
      children: [
        if (_readyCrates(w) case final ready?) ...[
          ready,
          const SizedBox(height: 12),
        ],
        if (_dupes) ...[_gage(context, w), const SizedBox(height: 12)],
        _crates(context, w),
        if (ways.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
            child: Text(
              'Wege zu mehr Kisten',
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final (i, way) in ways.indexed) ...[
            if (i > 0) const SizedBox(height: 12),
            way,
          ],
        ],
        const SizedBox(height: 32),
      ],
    );
  }

  /// The gage and what it buys, prices straight from the server: the
  /// crate, the Tauschverträge and the way to a chosen item.
  Widget _gage(BuildContext context, Wardrobe w) {
    final price = _gageCrates ? w.catalog.dupes.crateGage : null;
    final surface = Theme.of(context).colorScheme.surface;
    final aimed = _targets && w.crateTargets.isNotEmpty;
    // What the details of a missing card would sell: the same rule.
    final costs = [
      for (final i in w.catalog.collectible.where(w.counts))
        if (w.buyCost(i) case final cost?)
          if ((w.lockHint(i) ?? rewardHint(w, i) ?? uniqueHint(w, i)) == null)
            cost,
    ];
    GageOffer trade(TradeOption t) {
      final to = _rarity(w, t.to);
      final remaining = w.catalog.collectible
          .where((i) => w.counts(i) && i.rarities.contains(t.to) && !w.owns(i))
          .length;
      final subtitle = switch (remaining) {
        1 => 'Tauschvertrag · noch 1 offen (garantiert!)',
        final n when n > 1 => 'Tauschvertrag · noch $n offen',
        _ => 'Tauschvertrag',
      };
      return GageOffer(
        id: 'trade-${t.to}',
        action: 'trade-${t.to}',
        title: 'Neues ${to.name}-Teil',
        subtitle: subtitle,
        // The server's price, never worked out here.
        price: t.cost,
        verb: 'Tauschvertrag für ein neues ${to.name}-Teil',
        order: 1 + to.rank,
        trade: true,
        leading: GageOfferIcon(
          Icons.handshake_outlined,
          color: StageTheme.legible(to.color, surface, minimum: 3),
        ),
        onBuy: () => _tradeOffer(t),
      );
    }

    return GageCard(
      gage: w.gage,
      gala: _gala,
      complete: WardrobeOverview.of(w, unique: _unique).all.complete,
      busy: _busy,
      offers: [
        if (price != null)
          GageOffer(
            id: 'crate',
            action: 'wardrobe-buy-crate',
            title: 'Kostümkiste',
            subtitle: aimed
                ? 'Zufall, ein Stück oder Technik – du wählst · öffnet sofort'
                : 'Zufällig aus dem ganzen Fundus · öffnet sofort',
            price: price,
            verb: 'Kostümkiste kaufen',
            leading: const GageOfferIcon(
              Icons.inventory_2,
              color: StageTheme.orange,
            ),
            onBuy: () => _buyCrate(price),
          ),
        for (final t in w.trades) trade(t),
      ],
      shop: costs.isEmpty
          ? null
          : GageShop(
              from: costs.reduce((a, b) => a < b ? a : b),
              onShow: () {
                _search.clear();
                setState(() {
                  _query = '';
                  _play = null;
                  _person = null;
                  _rarityFilter = null;
                  _ownership = _OwnershipFilter.missing;
                  _shine = _ShineFilter.all;
                  _newOnly = false;
                  _selectedKind = WardrobeKind.character;
                });
                DefaultTabController.of(context).animateTo(0);
              },
            ),
    );
  }

  /// Every available crate has its one place to open, before everything
  /// else, including rewards from earlier days.
  Widget? _readyCrates(Wardrobe w) {
    final theme = Theme.of(context);
    final actions = <({String id, Widget label, IconData icon, int count, VoidCallback open})>[
      if (w.progress.crates > 0 && (_dupes || !w.progress.complete))
        (
          id: 'own',
          label: Text(
            'Kostümkiste öffnen${w.progress.crates > 1 ? ' (${w.progress.crates})' : ''}',
          ),
          icon: Icons.inventory_2_outlined,
          count: w.progress.crates,
          open: _openOwn,
        ),
      if (_missions && w.progress.missionCrates > 0)
        (
          id: 'mission',
          label: Text(
            'Missionskiste öffnen${w.progress.missionCrates > 1 ? ' (${w.progress.missionCrates})' : ''}',
          ),
          icon: Icons.flag_outlined,
          count: w.progress.missionCrates,
          open: () => _open(mission: true),
        ),
      if (_ensemble && w.ensemble != null && w.progress.ensembleCrates > 0)
        (
          id: 'ensemble',
          label: Text(
            'Ensemble-Kiste öffnen${w.progress.ensembleCrates > 1 ? ' (${w.progress.ensembleCrates})' : ''}',
          ),
          icon: Icons.groups_outlined,
          count: w.progress.ensembleCrates,
          open: () => _open(ensemble: true),
        ),
      // Two lines: which event the crate thanks for.
      if (_eventCrates)
        for (final event in w.eventCrates)
          (
            id: 'event-${event.eventId}',
            label: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Termin-Kiste öffnen', style: theme.textTheme.labelLarge),
                if (eventCrateEvent(event) case final what when what.isNotEmpty)
                  Text(
                    what,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            icon: Icons.event_available,
            count: 1,
            open: () => _open(event: event),
          ),
      if (_gala && w.gala.crates > 0)
        (
          id: 'gala',
          label: Text(
            'Gala-Kiste öffnen${w.gala.crates > 1 ? ' (${w.gala.crates})' : ''}',
          ),
          icon: Icons.theater_comedy_outlined,
          count: w.gala.crates,
          open: () => _open(gala: true),
        ),
      if (_weekly && w.weekly.crates > 0)
        (
          id: 'weekly',
          label: Text(
            'Wochenkiste öffnen${w.weekly.crates > 1 ? ' (${w.weekly.crates})' : ''}',
          ),
          icon: Icons.emoji_events_outlined,
          count: w.weekly.crates,
          open: () => _open(weekly: true),
        ),
      if (_packs)
        for (final goal in w.packGoals)
          if (goal.crates > 0)
            (
              id: 'pack-${goal.releaseId}',
              label: Text(
                'Set-Kiste öffnen: ${goal.name}${goal.crates > 1 ? ' (${goal.crates})' : ''}',
              ),
              icon: Icons.collections_outlined,
              count: goal.crates,
              open: () => _open(packGoal: goal),
            ),
    ];
    if (actions.isEmpty) return null;
    final inset = wardrobeInset(context);
    return Card(
      key: const ValueKey('wardrobe-ready-crates'),
      child: Padding(
        padding: EdgeInsets.all(inset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Bereit zum Öffnen',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                // What the buttons below open, nothing else.
                Text(
                  '${actions.fold(0, (sum, a) => sum + a.count)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            if (_eventCrates && w.eventCrates.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Danke fürs Dabeisein! Für jeden Termin, bei dem du da warst, gibt es eine Kiste – nur für dich.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final action in actions) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                key: ValueKey('wardrobe-ready-${action.id}'),
                style: FilledButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onPressed: _busy ? null : action.open,
                icon: Icon(action.icon),
                label: action.label,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _goalSection({
    required String id,
    required IconData icon,
    required String title,
    required String summary,
    required Widget child,
  }) => Card(
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      key: PageStorageKey('wardrobe-$id-section'),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(summary),
      shape: const Border(),
      collapsedShape: const Border(),
      children: [child],
    ),
  );

  /// A crate of the own runs: with crate targets first the choice
  /// (Zufallskiste, a play or the Technik-Kiste), else the Zufallskiste.
  Future<void> _openOwn() async {
    final w = _wardrobe;
    if (w == null) return;
    if (!_targets || w.crateTargets.isEmpty) return _open();
    final target = await chooseCrateTarget(
      context,
      controller: controller,
      wardrobe: w,
      art: _base,
    );
    if (target != null && mounted) await _open(target: target);
  }

  /// The next crate of the own runs: how far it is, the Tagesbonus, and
  /// folded the chances and details. It opens with the ready crates.
  Widget _crates(BuildContext context, Wardrobe w) {
    final theme = Theme.of(context);
    final p = w.progress;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final inset = wardrobeInset(context);
    return Card(
      key: const ValueKey('wardrobe-next-crate'),
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, inset, inset, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.inventory_2_outlined,
                  color: StageTheme.orange,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    p.complete && !_dupes
                        ? 'Fundus komplett'
                        : 'Nächste Kostümkiste',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: p.complete ? 1 : p.fraction,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(nextCrateText(p), style: theme.textTheme.bodyMedium),
            if (_bonus && p.bonusOpen)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  key: const ValueKey('wardrobe-daily-bonus'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.wb_sunny_outlined,
                      size: 16,
                      color: StageTheme.accentText(
                        StageTheme.amber,
                        theme.brightness,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(dailyBonusHint, style: quiet)),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            ExpansionTile(
              key: const PageStorageKey('wardrobe-crate-details'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 16),
              title: Text(
                'Chancen & Details',
                style: theme.textTheme.bodyMedium,
              ),
              shape: const Border(),
              collapsedShape: const Border(),
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    Text(
                      crateDistanceText(p, showBonus: _bonus),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (p.complete && _dupes)
                      Text(
                        roleFiguresAvailable(controller)
                            ? 'Fundus komplett – Kisten bringen jetzt Glanz oder Gage.'
                            : 'Fundus komplett – Kisten bringen jetzt Rollen, Glanz oder Gage.',
                        style: theme.textTheme.bodySmall,
                      )
                    else if (p.complete && p.crates > 0)
                      Text(
                        'Deine Kisten bleiben zu, bis es Neues im Fundus gibt.',
                        style: theme.textTheme.bodySmall,
                      ),
                    if (_targets && w.crateTargets.length > 1)
                      Text(
                        'Beim Öffnen wählst du: Zufallskiste mit allem und mehr Glanz, oder gezielt ein Stück bzw. die Technik.',
                        key: const ValueKey('wardrobe-targets-hint'),
                        style: theme.textTheme.bodySmall,
                      ),
                    if (_eventCrates)
                      Text(
                        'Termin-Kisten: Für jeden Termin, bei dem du da warst, gibt es eine Kiste – nur für dich.',
                        style: theme.textTheme.bodySmall,
                      ),
                    _odds(context, w),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The chance of each rarity, available before opening a crate.
  Widget _odds(BuildContext context, Wardrobe w) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final catalog = w.catalog;
    final lockedNotes = [
      for (final r in catalog.rarities.reversed)
        if (w.lockedRarities.contains(r.id) &&
            catalog.collectible.any((i) => i.rarities.contains(r.id)))
          if ((w.lockProgress(r), r.hint) case (final progress, final hint)
              when progress != null || hint != null)
            (
              r.id,
              [
                '${r.name} freischalten',
                if (progress != null) '${progress.$1}/${progress.$2}',
                ?hint,
              ].join(' · '),
            ),
    ];
    final dupeGage = _dupes
        ? [
            for (final r in catalog.rarities)
              if (r.gage > 0 &&
                  catalog.collectible.any((i) => i.rarities.contains(r.id)))
                '${r.name} ${r.gage}',
          ]
        : const <String>[];
    const shineLabels = [
      ('targeted', 'Gezielt'),
      ('mission', 'Mission'),
      ('ensemble', 'Ensemble'),
      ('event', 'Termin'),
      ('weekly', 'Woche'),
      ('gala', 'Gala'),
    ];
    final baseShine = catalog.dupes.shinyChance;
    final extraShines = _dupes
        ? [
            for (final (key, label) in shineLabels)
              if (catalog.dupes.shinyChances[key] case final rate?
                  when (rate - baseShine).abs() > 1e-6)
                '$label ${_percent(rate)}',
          ]
        : const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Wrap(
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
            if (_dupes)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: Color(0xFFE4AE39),
                ),
                label: Text(
                  'Glanz: ${_percent(catalog.dupes.shinyChance)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
        for (final (id, text) in lockedNotes)
          Text(
            text,
            key: ValueKey('wardrobe-odds-locked-$id'),
            style: quiet,
          ),
        if (dupeGage.isNotEmpty)
          Text(
            'Duplikat-Gage: ${dupeGage.join(' · ')}',
            key: const ValueKey('wardrobe-odds-gage'),
            style: quiet,
          ),
        if (extraShines.isNotEmpty)
          Text(
            'Glanz nach Kiste: Zufall ${_percent(baseShine)} · ${extraShines.join(' · ')}',
            key: const ValueKey('wardrobe-odds-shine'),
            style: quiet,
          ),
      ],
    );
  }

  static String _percent(double share) {
    final p = share * 100;
    return '${NumberFormat(p < 10 ? '0.0' : '0', 'de').format(p)} %';
  }

  // The figures' filters: a play ("Creepshow 2026") or the technicians
  // ([_techFilter]) and a person.
  String? _play;
  int? _person;
  static const _techFilter = '\u0000Technik';

  bool get _missingOnly => _ownership == _OwnershipFilter.missing;

  bool get _hasActiveFilters =>
      _query.trim().isNotEmpty ||
      _play != null ||
      _person != null ||
      _rarityFilter != null ||
      _ownership != _OwnershipFilter.all ||
      _shine != _ShineFilter.all ||
      _newOnly ||
      _sort != _WardrobeSort.rarity;

  void _resetFilters() {
    _search.clear();
    setState(() {
      _query = '';
      _play = null;
      _person = null;
      _rarityFilter = null;
      _ownership = _OwnershipFilter.all;
      _shine = _ShineFilter.all;
      _newOnly = false;
      _sort = _WardrobeSort.rarity;
    });
  }

  bool _isBuyableNow(Wardrobe w, WardrobeItem i) {
    if (!_dupes) return false;
    final cost = w.buyCost(i);
    if (cost == null) return false;
    final hint = w.lockHint(i) ?? rewardHint(w, i) ?? uniqueHint(w, i);
    return hint == null && w.gage >= cost;
  }

  bool _matchesOwnership(Wardrobe w, WardrobeItem i) => switch (_ownership) {
    _OwnershipFilter.all => true,
    _OwnershipFilter.owned => w.owns(i),
    _OwnershipFilter.missing => !w.owns(i),
    _OwnershipFilter.buyable => _isBuyableNow(w, i),
  };

  bool _matchesShine(Wardrobe w, WardrobeItem i) => switch (_shine) {
    _ShineFilter.all => true,
    _ShineFilter.shiny => w.owns(i) && w.isShiny(i),
    _ShineFilter.plain =>
      w.owns(i) && !w.isShiny(i) && !i.unique && !i.isDefault,
  };

  bool _matchesRarity(WardrobeItem i) {
    final r = _rarityFilter;
    if (r == null) return true;
    return i.rarity == r || i.rarities.contains(r);
  }

  bool _matchesNew(WardrobeItem i) => !_newOnly || _newIds.contains(i.id);

  /// Multi-token search across visible metadata without spoiling secret names
  /// or roles of unowned figures.
  bool _matchesQuery(Wardrobe w, WardrobeItem item) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final owned = w.owns(item);
    final catalog = w.catalog;
    final role = owned ? (w.roleOf(item) ?? item.role) : item.role;
    final unique = item.unique ? uniqueProgressOf(w, item) : null;
    final haystack = [
      if (owned || item.reward) item.name,
      if (owned && role != null) role.role,
      if (role?.play != null) role!.play!,
      if (role?.year != null) '${role!.year}',
      if (role?.isFunction == true) 'technik',
      if (owned && catalog.labelOf(item) != null) catalog.labelOf(item)!,
      if (owned)
        for (final d in item.departments) ?catalog.department(d)?.name,
      for (final r in catalog.raritiesOf(item)) r.name,
      if (item.unique) 'unique',
      if (unique != null) ...[
        unique.play,
        if (unique.allTechnicians) 'technik',
        if (unique.itemSet) ...[unique.itemNoun!.one, unique.itemNoun!.many],
        for (final p in unique.parts) p.production,
      ],
      if (owned && w.isShiny(item)) 'glanz shiny',
      item.kind.singular,
      item.kind.plural,
    ].join(' ').toLowerCase();
    return tokens.every(haystack.contains);
  }

  bool _matchesCommonFilters(Wardrobe w, WardrobeItem i) =>
      _matchesOwnership(w, i) &&
      _matchesShine(w, i) &&
      _matchesRarity(i) &&
      _matchesNew(i) &&
      _matchesQuery(w, i);

  Widget _dropdownBox<T>(
    BuildContext context, {
    required Key key,
    required T? value,
    required String all,
    required List<(T, String)> options,
    required ValueChanged<T?> onChanged,
  }) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButton<T?>(
        key: key,
        value: value,
        isDense: true,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(12),
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface,
        ),
        items: [
          DropdownMenuItem<T?>(
            value: null,
            child: Text(all, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          for (final (v, label) in options)
            DropdownMenuItem<T?>(
              value: v,
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _sortDropdown(BuildContext context, {required bool forCharacters}) {
    final theme = Theme.of(context);
    final modes = [
      _WardrobeSort.rarity,
      _WardrobeSort.ownedFirst,
      if (forCharacters) _WardrobeSort.playYear,
      _WardrobeSort.alpha,
    ];
    final current = modes.contains(_sort) ? _sort : _WardrobeSort.rarity;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButton<_WardrobeSort>(
        key: const ValueKey('wardrobe-sort'),
        value: current,
        isDense: true,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(12),
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface,
        ),
        items: [
          for (final mode in modes)
            DropdownMenuItem<_WardrobeSort>(
              value: mode,
              child: Text(
                mode == _WardrobeSort.rarity
                    ? 'Sortierung: ${mode.label}'
                    : mode.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _sort = v);
        },
      ),
    );
  }

  Widget _searchField(BuildContext context, WardrobeKind kind) => TextField(
    key: const ValueKey('wardrobe-search'),
    controller: _search,
    textInputAction: TextInputAction.search,
    onChanged: (value) => setState(() => _query = value),
    decoration: InputDecoration(
      isDense: true,
      hintText: kind == WardrobeKind.character
          ? 'Figur, Rolle, Stück oder Seltenheit suchen'
          : '${kind.plural} oder Seltenheit suchen',
      prefixIcon: const Icon(Icons.search, size: 20),
      prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      suffixIcon: _query.isEmpty
          ? null
          : IconButton(
              key: const ValueKey('wardrobe-search-clear'),
              tooltip: 'Suche leeren',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                _search.clear();
                setState(() => _query = '');
              },
            ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );

  /// The switch to the missing ones: "Nur fehlende (37)".
  Widget _missingChip(Tally tally) => FilterChip(
    key: const ValueKey('wardrobe-missing-only'),
    visualDensity: VisualDensity.compact,
    label: Text(
      tally.missing > 0 ? 'Nur fehlende (${tally.missing})' : 'Nur fehlende',
    ),
    selected: _missingOnly,
    onSelected: (on) => setState(
      () => _ownership = on ? _OwnershipFilter.missing : _OwnershipFilter.all,
    ),
  );

  Widget _filterChips(
    BuildContext context,
    Wardrobe w,
    Tally tally,
    Iterable<WardrobeItem> scope,
  ) {
    final buyableCount = _dupes
        ? scope.where((i) => _isBuyableNow(w, i)).length
        : 0;
    final selectedRarityObj = _rarityFilter == null
        ? null
        : w.catalog.rarities.where((r) => r.id == _rarityFilter).firstOrNull ??
              (w.catalog.uniqueRarity?.id == _rarityFilter
                  ? w.catalog.uniqueRarity
                  : null);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        FilterChip(
          key: const ValueKey('wardrobe-owned-only'),
          visualDensity: VisualDensity.compact,
          label: const Text('Nur besessen'),
          selected: _ownership == _OwnershipFilter.owned,
          onSelected: (on) => setState(
            () => _ownership = on ? _OwnershipFilter.owned : _OwnershipFilter.all,
          ),
        ),
        _missingChip(tally),
        if (_dupes) ...[
          FilterChip(
            key: const ValueKey('wardrobe-buyable-only'),
            visualDensity: VisualDensity.compact,
            label: Text(
              buyableCount > 0 ? 'Kaufbar ($buyableCount)' : 'Kaufbar',
            ),
            selected: _ownership == _OwnershipFilter.buyable,
            onSelected: (on) => setState(
              () => _ownership =
                  on ? _OwnershipFilter.buyable : _OwnershipFilter.all,
            ),
          ),
          FilterChip(
            key: const ValueKey('wardrobe-shiny-only'),
            visualDensity: VisualDensity.compact,
            label: const Text('Glanz'),
            selected: _shine == _ShineFilter.shiny,
            onSelected: (on) => setState(
              () => _shine = on ? _ShineFilter.shiny : _ShineFilter.all,
            ),
          ),
          FilterChip(
            key: const ValueKey('wardrobe-plain-only'),
            visualDensity: VisualDensity.compact,
            label: const Text('Ohne Glanz'),
            selected: _shine == _ShineFilter.plain,
            onSelected: (on) => setState(
              () => _shine = on ? _ShineFilter.plain : _ShineFilter.all,
            ),
          ),
        ],
        if (_newIds.isNotEmpty)
          FilterChip(
            key: const ValueKey('wardrobe-new-only'),
            visualDensity: VisualDensity.compact,
            label: Text('Neu (${_newIds.length})'),
            selected: _newOnly,
            onSelected: (on) => setState(() => _newOnly = on),
          ),
        if (selectedRarityObj != null)
          InputChip(
            key: const ValueKey('wardrobe-rarity-active'),
            visualDensity: VisualDensity.compact,
            avatar: CircleAvatar(
              radius: 5,
              backgroundColor: selectedRarityObj.color,
            ),
            label: Text(selectedRarityObj.name),
            onDeleted: () => setState(() => _rarityFilter = null),
          ),
        if (_hasActiveFilters)
          ActionChip(
            key: const ValueKey('wardrobe-reset-filters'),
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.restart_alt, size: 16),
            label: const Text('Zurücksetzen'),
            onPressed: _resetFilters,
          ),
      ],
    );
  }

  /// "Bühnenbilder: 3 von 12" with a bar when there is only one kind and so
  /// no chip counts it.
  Widget _tallyHeader(BuildContext context, String text, Tally tally) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        TallyBar(tally.fraction, color: StageTheme.orange, height: 4),
      ],
    );
  }

  /// Search, responsive dropdowns and filter chips without overflowing on
  /// narrow screens or large text.
  Widget _filterControls({
    required BuildContext context,
    required WardrobeKind kind,
    required List<Widget> dropdowns,
    required Widget chips,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
      final search = _searchField(context, kind);
      if (largeText) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [search, ...dropdowns, chips],
        );
      }
      if (constraints.maxWidth >= 640) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            search,
            if (dropdowns.isNotEmpty)
              Row(
                spacing: 12,
                children: [
                  for (final d in dropdowns)
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 240),
                        child: d,
                      ),
                    ),
                ],
              ),
            chips,
          ],
        );
      }
      // Phone: up to 2 dropdowns per row so labels stay readable.
      final rows = <Widget>[];
      for (var i = 0; i < dropdowns.length; i += 2) {
        final pair = dropdowns.sublist(i, min(i + 2, dropdowns.length));
        rows.add(
          Row(
            spacing: 10,
            children: [for (final d in pair) Expanded(child: d)],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [search, ...rows, chips],
      );
    },
  );

  Widget _emptyState(BuildContext context, String message) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(message),
      if (_hasActiveFilters)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: TextButton.icon(
            key: const ValueKey('wardrobe-empty-reset'),
            onPressed: _resetFilters,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Filter zurücksetzen'),
          ),
        ),
    ],
  );

  List<Widget> _kind(
    BuildContext context,
    Wardrobe w,
    WardrobeOverview overview,
    WardrobeKind kind,
    EdgeInsets padding,
    bool chips,
  ) {
    if (kind == WardrobeKind.character) {
      return _characters(context, w, overview, padding, chips);
    }
    final allOfKind = [
      for (final i in w.catalog.items)
        if (i.kind == kind) i,
    ];
    final items = [
      for (final i in allOfKind)
        if (_matchesCommonFilters(w, i)) i,
    ];
    items.sort((a, b) {
      if (_sort == _WardrobeSort.alpha) {
        if (w.owns(a) != w.owns(b)) return w.owns(a) ? -1 : 1;
        if (w.owns(a)) {
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
        final rank = w.catalog.rarityOf(b).rank - w.catalog.rarityOf(a).rank;
        return rank != 0 ? rank : a.id.compareTo(b.id);
      }
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      if (_sort == _WardrobeSort.ownedFirst && w.owns(a) != w.owns(b)) {
        return w.owns(a) ? -1 : 1;
      }
      final rank = w.catalog.rarityOf(b).rank - w.catalog.rarityOf(a).rank;
      if (rank != 0) return rank;
      return a.name.compareTo(b.name);
    });
    // The same count as the kind's chip: ensemble rewards are everybody's
    // and do not count for the collection, as in the Sammel-Rangliste.
    final tally = overview.kinds[kind] ?? const Tally(0, 0);
    final worn = w.worn(kind)?.id;
    final rarityOptions = [
      for (final r in overview.rarities) (r.rarity.id, r.rarity.name),
    ];
    final activeRarity = rarityOptions.any((o) => o.$1 == _rarityFilter)
        ? _rarityFilter
        : null;
    final dropdowns = <Widget>[
      if (rarityOptions.length > 1)
        _dropdownBox<String>(
          context,
          key: const ValueKey('wardrobe-filter-rarity'),
          value: activeRarity,
          all: 'Alle Seltenheiten',
          options: rarityOptions,
          onChanged: (v) => setState(() => _rarityFilter = v),
        ),
      _sortDropdown(context, forCharacters: false),
    ];
    return [
      if (!chips)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 12, padding.right, 4),
          sliver: SliverToBoxAdapter(
            child: _tallyHeader(context, '${kind.plural}: ${tally.text}', tally),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          padding.left,
          chips ? 4 : 4,
          padding.right,
          8,
        ),
        sliver: SliverToBoxAdapter(
          child: _filterControls(
            context: context,
            kind: kind,
            dropdowns: dropdowns,
            chips: _filterChips(context, w, tally, allOfKind),
          ),
        ),
      ),
      if (items.isEmpty)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 4, padding.right, 0),
          sliver: SliverToBoxAdapter(
            child: _emptyState(
              context,
              _missingOnly && !_hasOtherFiltersThanOwnership
                  ? 'Alle ${kind.plural} gefunden.'
                  : _ownership == _OwnershipFilter.buyable
                  ? 'Mit deiner aktuellen Gage (${gageText(w.gage)}) ist gerade nichts kaufbar.'
                  : 'Keine ${kind.plural} in dieser Auswahl.',
            ),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: padding.left),
        sliver: SliverGrid.builder(
          // Figures are a little taller: their role stands under the name.
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _cardWidth(context),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: kind == WardrobeKind.character ? .7 : .78,
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
            onQuickEquip: _busy ? null : () => _wear(items[i]),
            isNew: _newIds.contains(items[i].id),
            showPrice: _dupes,
            small: true,
          ),
        ),
      ),
    ];
  }

  bool get _hasOtherFiltersThanOwnership =>
      _query.trim().isNotEmpty ||
      _play != null ||
      _person != null ||
      _rarityFilter != null ||
      _shine != _ShineFilter.all ||
      _newOnly;

  /// The figures, one card per role: grouped by rarity from rare to common
  /// (or sorted by ownership, play & year, or A–Z). Can be narrowed by search,
  /// play, person, rarity, ownership, shine or new-in-session.
  List<Widget> _characters(
    BuildContext context,
    Wardrobe w,
    WardrobeOverview overview,
    EdgeInsets padding,
    bool chips,
  ) {
    final theme = Theme.of(context);
    final catalog = w.catalog;
    final all = [
      for (final i in catalog.items)
        if (i.kind == WardrobeKind.character) i,
    ];
    final collectible = [
      for (final i in all)
        if (!i.isDefault && !i.unique) i,
    ];
    final allYears = <String, int>{
      for (final i in collectible) ?i.role?.production: i.role?.year ?? 0,
    };
    final allHasTech = collectible.any((i) => i.role?.isFunction == true);
    final allPeople = <int, String>{
      for (final i in collectible) ?i.personId: i.name,
    };
    bool matchesPlay(WardrobeItem i, String? p) =>
        p == null ||
        (p == _techFilter
            ? i.role?.isFunction == true
            : i.role?.production == p);
    var play = allYears.containsKey(_play) || (allHasTech && _play == _techFilter)
        ? _play
        : null;
    var person = allPeople.containsKey(_person) ? _person : null;
    // Cross-filter: if both are selected but yield no overlap, keep play so a
    // tap on PlayProgressStrip or play dropdown always shows its cast.
    if (play != null &&
        person != null &&
        !collectible.any((i) => matchesPlay(i, play) && i.personId == person)) {
      person = null;
    }
    final playSource = person == null
        ? collectible
        : collectible.where((i) => i.personId == person);
    final years = <String, int>{
      for (final i in playSource) ?i.role?.production: i.role?.year ?? 0,
    };
    // Newest play first.
    final plays = years.keys.toList()
      ..sort((a, b) {
        final year = years[b]!.compareTo(years[a]!);
        return year != 0 ? year : a.compareTo(b);
      });
    final technicians = playSource.any((i) => i.role?.isFunction == true);
    final personSource = play == null
        ? collectible
        : collectible.where((i) => matchesPlay(i, play));
    final people = <int, String>{
      for (final i in personSource) ?i.personId: i.name,
    };
    final persons = people.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    bool selection(WardrobeItem i) =>
        matchesPlay(i, play) && (person == null || i.personId == person);
    bool shown(WardrobeItem i) => selection(i) && _matchesCommonFilters(w, i);
    int order(WardrobeItem a, WardrobeItem b) {
      if (w.owns(a) != w.owns(b)) return w.owns(a) ? -1 : 1;
      final weight = (b.importance ?? 0).compareTo(a.importance ?? 0);
      if (weight != 0) return weight;
      return nameInRole(a.name, a.role).compareTo(nameInRole(b.name, b.role));
    }

    int orderByRarityThenRole(WardrobeItem a, WardrobeItem b) {
      final rank = catalog.rarityOf(b).rank - catalog.rarityOf(a).rank;
      if (rank != 0) return rank;
      final weight = (b.importance ?? 0).compareTo(a.importance ?? 0);
      if (weight != 0) return weight;
      return nameInRole(a.name, a.role).compareTo(nameInRole(b.name, b.role));
    }

    bool matchesUniquePlay(WardrobeItem i) {
      if (play == null) return true;
      final p = uniqueProgressOf(w, i);
      if (play == _techFilter) return p?.allTechnicians == true;
      if (p != null && p.matchesProduction(play)) return true;
      return i.role?.production == play;
    }

    final worn = w.worn(WardrobeKind.character)?.id;
    // The default figure only for whoever still wears it: with a figure of
    // their own (a present) Engel Logge is not in the collection.
    final defaults = [
      if (play == null &&
          person == null &&
          _rarityFilter == null &&
          _ownership != _OwnershipFilter.missing &&
          _ownership != _OwnershipFilter.buyable &&
          _shine == _ShineFilter.all &&
          !_newOnly &&
          _query.trim().isEmpty)
        for (final i in all)
          if (i.isDefault && w.owns(i)) i,
    ];
    // The unique figures (unlocked or hidden), including Technik and
    // multi-play figures under every involved play.
    final uniques = [
      if (_unique && person == null)
        for (final i in uniqueCards(w))
          if (matchesUniquePlay(i) && _matchesCommonFilters(w, i)) i,
    ];
    final filtered = [
      for (final i in collectible)
        if (shown(i)) i,
    ];
    // The same count as the kind's chip.
    final tally =
        overview.kinds[WardrobeKind.character] ?? Tally.of(collectible, w);
    final showPlayFilter =
        allYears.length > 1 || (allYears.isNotEmpty && allHasTech);
    final showPersonFilter = allPeople.length > 1;
    final playFilter = showPlayFilter
        ? _dropdownBox<String>(
            context,
            key: const ValueKey('wardrobe-filter-play'),
            value: play,
            all: 'Alle Stücke',
            options: [
              for (final p in plays) (p, p),
              if (technicians) (_techFilter, 'Technik'),
            ],
            onChanged: (v) => setState(() {
              _play = v;
              if (v != null &&
                  _person != null &&
                  !collectible.any(
                    (i) => matchesPlay(i, v) && i.personId == _person,
                  )) {
                _person = null;
              }
            }),
          )
        : null;
    final personFilter = showPersonFilter
        ? _dropdownBox<int>(
            context,
            key: const ValueKey('wardrobe-filter-person'),
            value: person,
            all: 'Alle Personen',
            options: [for (final e in persons) (e.key, e.value)],
            onChanged: (v) => setState(() => _person = v),
          )
        : null;
    final rarityOptions = [
      for (final r in overview.rarities) (r.rarity.id, r.rarity.name),
      if (_unique &&
          catalog.uniqueRarity != null &&
          uniqueCards(w).isNotEmpty)
        (catalog.uniqueRarity!.id, catalog.uniqueRarity!.name),
    ];
    final activeRarity = rarityOptions.any((o) => o.$1 == _rarityFilter)
        ? _rarityFilter
        : null;
    final rarityFilter = rarityOptions.length > 1
        ? _dropdownBox<String>(
            context,
            key: const ValueKey('wardrobe-filter-rarity'),
            value: activeRarity,
            all: 'Alle Seltenheiten',
            options: rarityOptions,
            onChanged: (v) => setState(() => _rarityFilter = v),
          )
        : null;
    final dropdowns = <Widget>[
      ?playFilter,
      ?personFilter,
      ?rarityFilter,
      _sortDropdown(context, forCharacters: true),
    ];
    final sectionSlivers = <Widget>[];
    switch (_sort) {
      case _WardrobeSort.rarity:
        final groups = [
          for (final r in catalog.rarities.reversed)
            if ([
                  for (final i in filtered)
                    if (i.rarity == r.id) i,
                ]..sort(order)
                case final items when items.isNotEmpty)
              (
                r,
                items,
                Tally.of(
                  collectible.where((i) => i.rarity == r.id && selection(i)),
                  w,
                ),
              ),
        ];
        for (final (rarity, items, groupTally) in groups) {
          final lockProgress = w.lockProgress(rarity);
          final lockedText = [
            rarity.name,
            if (lockProgress != null) '${lockProgress.$1}/${lockProgress.$2}',
            rarity.hint ?? 'gesperrt',
          ].join(' · ');
          sectionSlivers.addAll([
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padding.left, 14, padding.right, 6),
              sliver: SliverToBoxAdapter(
                // The summary card has the bar; here only the count.
                child: Row(
                  key: ValueKey('wardrobe-group-${rarity.id}'),
                  children: [
                    CircleAvatar(radius: 5, backgroundColor: rarity.color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        w.lockedRarities.contains(rarity.id)
                            ? lockedText
                            : rarity.name,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      groupTally.complete
                          ? 'alle ${groupTally.total} ✓'
                          : '${groupTally.owned}/${groupTally.total}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            _grid(items, w, worn, padding),
          ]);
        }
      case _WardrobeSort.ownedFirst:
        final ownedItems = [
          for (final i in filtered)
            if (w.owns(i)) i,
        ]..sort(orderByRarityThenRole);
        final missingItems = [
          for (final i in filtered)
            if (!w.owns(i)) i,
        ]..sort(orderByRarityThenRole);
        for (final (keyId, title, color, items) in [
          if (ownedItems.isNotEmpty)
            ('owned', 'Besessen', StageTheme.green, ownedItems),
          if (missingItems.isNotEmpty)
            (
              'missing',
              'Noch fehlend',
              theme.colorScheme.onSurfaceVariant,
              missingItems,
            ),
        ]) {
          sectionSlivers.addAll([
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padding.left, 14, padding.right, 6),
              sliver: SliverToBoxAdapter(
                child: Row(
                  key: ValueKey('wardrobe-group-$keyId'),
                  children: [
                    CircleAvatar(radius: 5, backgroundColor: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(title, style: theme.textTheme.titleSmall),
                    ),
                    Text('${items.length}', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            _grid(items, w, worn, padding),
          ]);
        }
      case _WardrobeSort.playYear:
        final byGroup = <String, List<WardrobeItem>>{};
        final groupYear = <String, int>{};
        for (final i in filtered) {
          final String groupKey;
          if (i.role?.production case final prod?) {
            groupKey = prod;
            groupYear[groupKey] = i.role?.year ?? 0;
          } else if (i.role?.isFunction == true) {
            groupKey = 'Technik';
            groupYear[groupKey] = -1;
          } else {
            groupKey = 'Sonstige';
            groupYear[groupKey] = -2;
          }
          (byGroup[groupKey] ??= []).add(i);
        }
        final orderedKeys = byGroup.keys.toList()
          ..sort((a, b) {
            final year = groupYear[b]!.compareTo(groupYear[a]!);
            return year != 0 ? year : a.compareTo(b);
          });
        for (final title in orderedKeys) {
          final items = byGroup[title]!
            ..sort((a, b) {
              if (w.owns(a) != w.owns(b)) return w.owns(a) ? -1 : 1;
              return orderByRarityThenRole(a, b);
            });
          final groupTally = Tally.of(items, w);
          sectionSlivers.addAll([
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padding.left, 14, padding.right, 6),
              sliver: SliverToBoxAdapter(
                child: Row(
                  key: ValueKey('wardrobe-group-play-$title'),
                  children: [
                    Expanded(
                      child: Text(title, style: theme.textTheme.titleSmall),
                    ),
                    Text(
                      '${groupTally.owned}/${groupTally.total}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            _grid(items, w, worn, padding),
          ]);
        }
      case _WardrobeSort.alpha:
        if (filtered.isNotEmpty) {
          final sorted = [...filtered]
            ..sort((a, b) {
              if (w.owns(a) != w.owns(b)) return w.owns(a) ? -1 : 1;
              if (w.owns(a)) {
                return nameInRole(a.name, a.role)
                    .toLowerCase()
                    .compareTo(nameInRole(b.name, b.role).toLowerCase());
              }
              // Keep unowned cards spoiler-free: never reveal alphabetical name.
              final prodA = a.role?.production ?? 'Technik';
              final prodB = b.role?.production ?? 'Technik';
              final prod = prodA.compareTo(prodB);
              if (prod != 0) return prod;
              final rank = catalog.rarityOf(b).rank - catalog.rarityOf(a).rank;
              return rank != 0 ? rank : a.id.compareTo(b.id);
            });
          sectionSlivers.addAll([
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padding.left, 14, padding.right, 6),
              sliver: SliverToBoxAdapter(
                child: Row(
                  key: const ValueKey('wardrobe-group-alpha'),
                  children: [
                    Expanded(
                      child: Text(
                        'Figuren A–Z',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text('${sorted.length}', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            _grid(sorted, w, worn, padding),
          ]);
        }
    }
    return [
      if (!chips)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 12, padding.right, 4),
          sliver: SliverToBoxAdapter(
            child: _tallyHeader(context, 'Figuren: ${tally.text}', tally),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(padding.left, 4, padding.right, 4),
        sliver: SliverToBoxAdapter(
          child: _filterControls(
            context: context,
            kind: WardrobeKind.character,
            dropdowns: dropdowns,
            chips: _filterChips(
              context,
              w,
              tally,
              collectible.where(selection),
            ),
          ),
        ),
      ),
      if (defaults.isNotEmpty) _grid(defaults, w, worn, padding, top: 8),
      if (uniques.isNotEmpty) ...[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 14, padding.right, 6),
          sliver: SliverToBoxAdapter(
            child: Row(
              key: const ValueKey('wardrobe-group-unique'),
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(colors: holoColors),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${catalog.uniqueRarity?.name ?? 'Unique'} · vollständige Sammlungen',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  '${uniques.where(w.owns).length}/${uniques.length}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        _grid(uniques, w, worn, padding),
      ],
      ...sectionSlivers,
      if (sectionSlivers.isEmpty && uniques.isEmpty && defaults.isEmpty)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 12, padding.right, 0),
          sliver: SliverToBoxAdapter(
            child: _emptyState(
              context,
              _ownership == _OwnershipFilter.buyable
                  ? 'Mit deiner aktuellen Gage (${gageText(w.gage)}) ist gerade nichts kaufbar.'
                  : _missingOnly
                  ? 'In dieser Auswahl fehlt dir nichts mehr.'
                  : 'Keine Figur in dieser Auswahl.',
            ),
          ),
        ),
    ];
  }

  /// Larger system text gets wider cards so the picture still has room.
  double _cardWidth(BuildContext context) =>
      132 *
      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
        1,
        double.infinity,
      );

  /// A grid of figure cards.
  Widget _grid(
    List<WardrobeItem> items,
    Wardrobe w,
    String? worn,
    EdgeInsets padding, {
    double top = 0,
  }) => SliverPadding(
    padding: EdgeInsets.fromLTRB(padding.left, top, padding.left, 0),
    sliver: SliverGrid.builder(
      // Figures are a little taller: their role stands under the name.
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _cardWidth(context),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: .7,
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
        onQuickEquip: _busy ? null : () => _wear(items[i]),
        isNew: _newIds.contains(items[i].id),
        showPrice: _dupes,
        small: true,
      ),
    ),
  );

  Widget _statistics(BuildContext context) {
    final theme = Theme.of(context);
    final w = _wardrobe!;
    final s = w.stats;
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
        CrateBalanceCard(
          opened: w.progress.opened,
          earned: w.progress.earned,
          shiny: w.shiny.where((id) => w.catalog.item(id) != null).length,
          gageEarned: _dupes ? w.gageEarned : null,
          duplicates: w.stats.duplicates,
        ),
        const SizedBox(height: 12),
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
        // Crate points (`runnerCratePoints`): what the crates count, apart
        // from the metres of the Gesamtstrecke.
        if (_wardrobe!.progress.points case final points?) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              [
                'Kistenpunkte gesamt: ${pointsText(points.total)}',
                'aus Läufen ${_number.format(points.runs)}',
                if (points.bonus > 0)
                  'Tagesbonus ${_number.format(points.bonus)}',
                if (points.missions > 0)
                  'Missionen ${_number.format(points.missions)}',
              ].join(' · '),
              key: const ValueKey('wardrobe-points-total'),
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (points.base > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Text(
                s.crateMeters > 0
                    ? 'Davon ${pointsText(points.base)} aus deiner früheren Kistenstrecke (${metersText(s.crateMeters)}): gleich viele Kisten, gleicher Stand bis zur nächsten.'
                    : 'Davon ${pointsText(points.base)} aus deiner früheren Kistenstrecke.',
                key: const ValueKey('wardrobe-points-base'),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ]
        // The Tagesbonus is not in the Gesamtstrecke: it counts only for
        // the crates (the Kistenstrecke).
        else if (_bonus)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              'Tagesbonus gesamt: ${metersText(s.bonusMeters)} · zählt nur für die Kisten (Kistenstrecke ${metersText(_wardrobe!.progress.meters)}).',
              key: const ValueKey('wardrobe-bonus-total'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (_missions && !_wardrobe!.progress.inPoints)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text(
              'Tagesmissionen gesamt: ${metersText(s.missionMeters)} · zählen wie der Tagesbonus nur für die Kisten.',
              key: const ValueKey('wardrobe-mission-total'),
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

/// After a run: what it added to the Ensemble-Strecke, and a milestone it
/// reached.
class EnsembleRunNote extends StatelessWidget {
  const EnsembleRunNote(this.run, {super.key});
  final EnsembleRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('runner-ensemble'),
      children: [
        const SizedBox(height: 8),
        Text(
          ensembleRunText(run),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        for (final m in run.reached) ...[
          const SizedBox(height: 6),
          Text(
            ensembleReachedText(m),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: StageTheme.orange,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}

/// Whether [w] has a crate waiting that can be opened.
bool crateWaiting(Wardrobe? w) =>
    w != null &&
    (w.progress.canOpen ||
        w.progress.ensembleCrates > 0 ||
        w.progress.missionCrates > 0 ||
        w.eventCrates.isNotEmpty ||
        w.gala.crates > 0 ||
        w.weekly.crates > 0 ||
        w.packCrates > 0);

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
