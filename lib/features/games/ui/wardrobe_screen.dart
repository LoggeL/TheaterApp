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
import 'missions_card.dart';
import 'pack_goals_card.dart';
import 'stage_runner_art.dart';
import 'stage_runner_fx.dart' show obstacleName;
import 'stage_runner_look.dart';
import 'stage_runner_sound.dart';
import 'unique_figures.dart';
import 'wardrobe_cards.dart';
import 'wardrobe_overview.dart';

/// Opens the wardrobe; [onChanged] gets every new state of it.
Future<void> openWardrobe(
  BuildContext context,
  AppController controller, {
  Wardrobe? wardrobe,
  RunnerArt? dressed,
  required RunnerSound sound,
  ValueChanged<Wardrobe>? onChanged,
}) => openPage<void>(
  context,
  WardrobeScreen(
    controller: controller,
    initial: wardrobe,
    dressed: dressed,
    sound: sound,
    onChanged: onChanged,
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
  });
  final AppController controller;
  final RunnerSound sound;

  /// What is known already (the game's wardrobe): the page is there at once
  /// and the refresh waits until it has come in.
  final Wardrobe? initial;

  /// The art in the costume of [initial], if the game has it.
  final RunnerArt? dressed;

  /// Told about every new state, e.g. so the game wears the new costume.
  final ValueChanged<Wardrobe>? onChanged;

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

  AppController get controller => widget.controller;
  bool get _dupes => dupesAvailable(controller);
  bool get _ensemble => ensembleAvailable(controller);
  bool get _bonus => dailyBonusAvailable(controller);
  bool get _missions => missionsAvailable(controller);
  bool get _eventCrates => eventCratesAvailable(controller);
  bool get _packs => packGoalsAvailable(controller);
  bool get _unique => uniqueFiguresAvailable(controller);
  bool get _targets => crateTargetsAvailable(controller);

  int get _waitingCrates {
    final w = _wardrobe;
    if (w == null) return 0;
    return w.progress.crates +
        (_missions ? w.progress.missionCrates : 0) +
        (_ensemble && w.ensemble != null ? w.progress.ensembleCrates : 0) +
        (_eventCrates ? w.eventCrates.length : 0) +
        (_packs ? w.packCrates : 0);
  }

  @override
  void initState() {
    super.initState();
    if (widget.initial == null) _start();
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final w = await loadWardrobe(controller);
      if (!mounted) return;
      _update(w);
      _celebrate(w);
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
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

  void _update(Wardrobe w) {
    setState(() => _wardrobe = w);
    widget.onChanged?.call(w);
    _dress();
  }

  Future<void> _open({
    bool ensemble = false,
    bool mission = false,
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
      _update(next);
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
      if (mounted) _update(w);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// An owned figure gets a page of its own; everything else (and what is
  /// still missing, which keeps its secret) the details below.
  void _details(WardrobeItem item) {
    final w = _wardrobe!;
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
    showModalBottomSheet<void>(
      isScrollControlled: true,
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
                          style: Theme.of(context).textTheme.titleLarge,
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
                              style: Theme.of(context).textTheme.titleSmall,
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
                                Text(
                                  'Glanz-Version',
                                  style: TextStyle(fontWeight: FontWeight.w700),
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
                              unique?.allTechnicians == true
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
                                  ? unique?.allTechnicians == true
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
                        // Across plays: how far each of them is.
                        if (!owned && unique != null && unique.several)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              unique.parts.map((p) => p.line).join(' · '),
                              key: const ValueKey('wardrobe-unique-parts'),
                              style: Theme.of(context).textTheme.bodySmall,
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
                              style: Theme.of(context).textTheme.bodySmall,
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
              if (cost != null && hint == null) ...[
                const SizedBox(height: 20),
                FilledButton.tonalIcon(
                  key: const ValueKey('wardrobe-buy'),
                  onPressed: _busy || w.gage < cost
                      ? null
                      : () {
                          Navigator.pop(context);
                          _buy(item, cost);
                        },
                  icon: const Icon(Icons.shopping_bag_outlined),
                  label: Text('Gezielt holen · ${gageText(cost)}'),
                ),
                if (w.gage < cost)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Dir fehlen noch ${gageText(cost - w.gage)}. Gage gibt es für Duplikate.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
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

  /// The Tauschvertrag: one of the offered trades, then a confirmation.
  Future<void> _trade() async {
    final w = _wardrobe!;
    final catalog = w.catalog;
    WardrobeRarity rarity(String id) =>
        catalog.rarities.where((r) => r.id == id).firstOrNull ??
        WardrobeRarity.unknown;
    final chosen = await showModalBottomSheet<TradeOption>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        TradeOption? pick = w.trades.where((t) => t.cost <= w.gage).lastOrNull;
        return StatefulBuilder(
          builder: (context, setSheet) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tauschvertrag',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${catalog.dupes.tradeDupes} Duplikate einer Stufe in Gage gegen ein zufälliges Teil, das dir in der Stufe darüber noch fehlt. Du hast ${gageText(w.gage)}.',
                  ),
                  const SizedBox(height: 8),
                  if (w.trades.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Gerade ist kein Tausch möglich.'),
                    ),
                  for (final t in w.trades)
                    ListTile(
                      key: ValueKey('trade-${t.to}'),
                      contentPadding: EdgeInsets.zero,
                      enabled: t.cost <= w.gage,
                      selected: identical(pick, t),
                      leading: Icon(
                        identical(pick, t)
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text('→ zufällig ${rarity(t.to).name}'),
                      subtitle: Text(
                        '${catalog.dupes.tradeDupes} × ${rarity(t.from).name} · ${gageText(t.cost)}',
                      ),
                      trailing: CircleAvatar(
                        radius: 8,
                        backgroundColor: rarity(t.to).color,
                      ),
                      onTap: () => setSheet(() => pick = t),
                    ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const ValueKey('trade-sign'),
                    onPressed: pick == null
                        ? null
                        : () => Navigator.pop(context, pick),
                    icon: const Icon(Icons.draw_outlined),
                    label: Text(
                      pick == null
                          ? 'Vertrag unterschreiben'
                          : 'Für ${gageText(pick!.cost)} unterschreiben',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    final ok = await _confirm(
      'Tauschvertrag unterschreiben?',
      '${gageText(chosen.cost)} gegen ein zufälliges ${rarity(chosen.to).name}-Teil, das dir noch fehlt.',
      'Unterschreiben',
    );
    if (!ok || !mounted) return;
    await _deal(() => tradeGage(controller, chosen.from));
  }

  /// Runs a trade or purchase and shows what it brought.
  Future<void> _deal(Future<GageDeal> Function() run) async {
    setState(() => _busy = true);
    try {
      final deal = await run();
      if (!mounted) return;
      _update(deal.wardrobe);
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
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Garderobe'),
          bottom: TabBar(
            isScrollable: largeText,
            tabAlignment: largeText ? TabAlignment.start : TabAlignment.fill,
            tabs: [
              Tab(
                key: const ValueKey('wardrobe-tab-collection'),
                height: largeText ? 64 : null,
                text: 'Sammlung',
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
                      count: _waitingCrates,
                      isLabelVisible: _waitingCrates > 0,
                      child: const Text('Kisten'),
                    ),
                  ),
                ),
              ),
              Tab(height: largeText ? 64 : null, text: 'Statistik'),
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
                  // Below the DefaultTabController: the crates pill switches
                  // to the crates with it.
                  Builder(builder: _costumes),
                  _rewards(context),
                  _statistics(context),
                ],
              ),
      ),
    );
    return widget.initial == null
        ? page
        : _AfterEntrance(onEntered: _start, child: page);
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
              gage: _dupes ? gageText(w.gage) : null,
              onTrade: _dupes && !_busy ? _trade : null,
            ),
          ),
        ),
        if (plays.isNotEmpty && kinds.contains(WardrobeKind.character))
          SliverPadding(
            padding: EdgeInsets.fromLTRB(padding.left, 4, padding.right, 12),
            sliver: SliverToBoxAdapter(
              child: PlayProgressStrip(
                plays: plays,
                selected: selected == WardrobeKind.character
                    ? (_play == _techFilter ? 'Technik' : _play)
                    : null,
                onSelect: (p) => setState(() {
                  _selectedKind = WardrobeKind.character;
                  final value = p.technicians ? _techFilter : p.production;
                  _play = _play == value ? null : value;
                }),
              ),
            ),
          ),
        if (kinds.length > 1)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              key: const PageStorageKey('wardrobe-kind-selector'),
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: padding.left),
              child: Row(
                spacing: 8,
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
        if (selected != null)
          ..._kind(context, w, overview, selected, padding)
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

  Widget _rewards(BuildContext context) {
    final w = _wardrobe!;
    return ListView(
      key: const PageStorageKey('wardrobe-rewards'),
      padding: pagePadding(context, maxWidth: 640, top: 16),
      children: [
        _crates(context, w),
        const SizedBox(height: 12),
        CrateBalanceCard(
          waiting: [
            if (w.progress.crates > 0)
              ('Kostümkiste', 'Kostümkisten', w.progress.crates),
            if (_missions && w.progress.missionCrates > 0)
              ('Missionskiste', 'Missionskisten', w.progress.missionCrates),
            if (_ensemble &&
                w.ensemble != null &&
                w.progress.ensembleCrates > 0)
              ('Ensemble-Kiste', 'Ensemble-Kisten', w.progress.ensembleCrates),
            if (_eventCrates && w.eventCrates.isNotEmpty)
              ('Termin-Kiste', 'Termin-Kisten', w.eventCrates.length),
            if (_packs && w.packCrates > 0)
              ('Set-Kiste', 'Set-Kisten', w.packCrates),
          ],
          opened: w.progress.opened,
          earned: w.progress.earned,
          shiny: w.shiny.where((id) => w.catalog.item(id) != null).length,
          gageEarned: _dupes ? w.gageEarned : null,
          duplicates: w.stats.duplicates,
        ),
        if (_packs && w.packGoals.isNotEmpty) ...[
          const SizedBox(height: 12),
          PackGoalsCard(
            goals: w.packGoals,
            onOpen: _busy ? null : (goal) => _open(packGoal: goal),
          ),
        ],
        if (_eventCrates && w.eventCrates.isNotEmpty) ...[
          const SizedBox(height: 12),
          EventCratesCard(
            crates: w.eventCrates,
            onOpen: _busy ? null : (e) => _open(event: e),
          ),
        ],
        if (_missions) ...[
          const SizedBox(height: 12),
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
        ],
        if (_ensemble && w.ensemble != null) ...[
          const SizedBox(height: 12),
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
        ],
        const SizedBox(height: 32),
      ],
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

  Widget _crates(BuildContext context, Wardrobe w) {
    final theme = Theme.of(context);
    final p = w.progress;
    final ready = !_busy && p.crates > 0 && (_dupes || !p.complete);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
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
                    p.crates == 0
                        ? 'Keine Kostümkiste bereit'
                        : p.crates == 1
                        ? '1 Kostümkiste bereit'
                        : '${p.crates} Kostümkisten bereit',
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
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('wardrobe-open'),
              onPressed: ready ? _openOwn : null,
              icon: const Icon(Icons.inventory_2),
              label: const Text('Kiste öffnen'),
            ),
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
                    if (_bonus && p.bonusOpen)
                      Text(
                        dailyBonusHint,
                        key: const ValueKey('wardrobe-daily-bonus'),
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
                    if (_dupes)
                      Text(
                        'Duplikate einer kompletten Stufe bringen Gage. Fehlende Teile kannst du über ihre Karte gezielt holen.',
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
    );
  }

  static String _percent(double share) {
    final p = share * 100;
    return '${NumberFormat(p < 10 ? '0.0' : '0', 'de').format(p)} %';
  }

  List<Widget> _kind(
    BuildContext context,
    Wardrobe w,
    WardrobeOverview overview,
    WardrobeKind kind,
    EdgeInsets padding,
  ) {
    if (kind == WardrobeKind.character) {
      return _characters(context, w, overview, padding);
    }
    final items = w.catalog.items.where((i) => i.kind == kind).toList()
      // Defaults first, then from rare to common; owned before missing.
      ..sort((a, b) {
        if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
        final rank = w.catalog.rarityOf(b).rank - w.catalog.rarityOf(a).rank;
        if (rank != 0) return rank;
        return a.name.compareTo(b.name);
      });
    // The same count as the kind's chip: ensemble rewards are everybody's
    // and do not count for the collection, as in the Sammel-Rangliste.
    final tally = overview.kinds[kind] ?? const Tally(0, 0);
    final worn = w.worn(kind)?.id;
    if (_missingOnly) items.removeWhere(w.owns);
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(padding.left, 12, padding.right, 8),
        sliver: SliverToBoxAdapter(
          child: _tallyHeader(context, '${kind.plural}: ${tally.text}', tally),
        ),
      ),
      if (items.isEmpty)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 4, padding.right, 0),
          sliver: SliverToBoxAdapter(
            child: Text('Alle ${kind.plural} gefunden.'),
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
            small: true,
          ),
        ),
      ),
    ];
  }

  // The figures' filters: a play ("Creepshow 2026") or the technicians
  // ([_techFilter]), a person, and only the missing ones.
  String? _play;
  int? _person;
  bool _missingOnly = false;
  static const _techFilter = '\u0000Technik';

  /// "Bühnenbilder: 3 von 12" with a bar and the switch to the missing ones.
  Widget _tallyHeader(BuildContext context, String text, Tally tally) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              TallyBar(tally.fraction, color: StageTheme.orange, height: 4),
            ],
          ),
        ),
        const SizedBox(width: 12),
        FilterChip(
          key: const ValueKey('wardrobe-missing-only'),
          label: Text(
            tally.missing > 0
                ? 'Nur fehlende (${tally.missing})'
                : 'Nur fehlende',
          ),
          selected: _missingOnly,
          onSelected: (on) => setState(() => _missingOnly = on),
        ),
      ],
    );
  }

  /// The figures, one card per role: grouped by rarity from rare to common,
  /// in a rarity the owned ones first, then by the weight of the role. The
  /// list can be narrowed to one play or one person.
  List<Widget> _characters(
    BuildContext context,
    Wardrobe w,
    WardrobeOverview overview,
    EdgeInsets padding,
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
    final years = <String, int>{
      for (final i in collectible) ?i.role?.production: i.role?.year ?? 0,
    };
    // Newest play first.
    final plays = years.keys.toList()
      ..sort((a, b) {
        final year = years[b]!.compareTo(years[a]!);
        return year != 0 ? year : a.compareTo(b);
      });
    final people = <int, String>{
      for (final i in collectible) ?i.personId: i.name,
    };
    final persons = people.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final technicians = collectible.any((i) => i.role?.isFunction == true);
    final play = plays.contains(_play) || (technicians && _play == _techFilter)
        ? _play
        : null;
    final person = people.containsKey(_person) ? _person : null;
    bool shown(WardrobeItem i) =>
        (play == null ||
            (play == _techFilter
                ? i.role?.isFunction == true
                : i.role?.production == play)) &&
        (person == null || i.personId == person) &&
        (!_missingOnly || !w.owns(i));
    int order(WardrobeItem a, WardrobeItem b) {
      if (w.owns(a) != w.owns(b)) return w.owns(a) ? -1 : 1;
      final weight = (b.importance ?? 0).compareTo(a.importance ?? 0);
      if (weight != 0) return weight;
      return nameInRole(a.name, a.role).compareTo(nameInRole(b.name, b.role));
    }

    final worn = w.worn(WardrobeKind.character)?.id;
    // The default figure only for whoever still wears it: with a figure of
    // their own (a present) Engel Logge is not in the collection.
    final defaults = [
      if (play == null && person == null && !_missingOnly)
        for (final i in all)
          if (i.isDefault && w.owns(i)) i,
    ];
    // The unique figures, one per play (unlocked or hidden), on top.
    final uniques = [
      if (_unique && person == null && play != _techFilter)
        for (final i in uniqueCards(w))
          if ((play == null || i.role?.production == play) &&
              (!_missingOnly || !w.owns(i)))
            i,
    ];
    // Per rarity the shown figures and how many of the selection (without
    // the switch to the missing ones) are owned.
    bool selection(WardrobeItem i) =>
        (play == null ||
            (play == _techFilter
                ? i.role?.isFunction == true
                : i.role?.production == play)) &&
        (person == null || i.personId == person);
    final groups = [
      for (final r in catalog.rarities.reversed)
        if ([
              for (final i in collectible)
                if (i.rarity == r.id && shown(i)) i,
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
    // The same count as the kind's chip.
    final tally =
        overview.kinds[WardrobeKind.character] ?? Tally.of(collectible, w);
    Widget filter<T>({
      required Key key,
      required T? value,
      required String all,
      required List<(T, String)> options,
      required ValueChanged<T?> onChanged,
    }) => DropdownButton<T?>(
      key: key,
      value: value,
      isDense: true,
      isExpanded: true,
      underline: const SizedBox.shrink(),
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
    );
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(padding.left, 12, padding.right, 4),
        sliver: SliverToBoxAdapter(
          child: _tallyHeader(context, 'Figuren: ${tally.text}', tally),
        ),
      ),
      if (plays.length > 1 || persons.length > 1)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, 4),
          sliver: SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final largeText =
                    MediaQuery.textScalerOf(context).scale(14) > 20;
                final width = largeText
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 16) / 2;
                return Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: width,
                      height: 48,
                      child: filter<String>(
                        key: const ValueKey('wardrobe-filter-play'),
                        value: play,
                        all: 'Alle Stücke',
                        options: [
                          for (final p in plays) (p, p),
                          if (technicians) (_techFilter, 'Technik'),
                        ],
                        onChanged: (v) => setState(() => _play = v),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      height: 48,
                      child: filter<int>(
                        key: const ValueKey('wardrobe-filter-person'),
                        value: person,
                        all: 'Alle Personen',
                        options: [for (final e in persons) (e.key, e.value)],
                        onChanged: (v) => setState(() => _person = v),
                      ),
                    ),
                  ],
                );
              },
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
      for (final (rarity, items, tally) in groups) ...[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 14, padding.right, 6),
          sliver: SliverToBoxAdapter(
            child: Column(
              key: ValueKey('wardrobe-group-${rarity.id}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    CircleAvatar(radius: 5, backgroundColor: rarity.color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        w.lockedRarities.contains(rarity.id)
                            ? '${rarity.name} · ${rarity.hint ?? 'gesperrt'}'
                            : rarity.name,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      tally.complete
                          ? 'alle ${tally.total} ✓'
                          : '${tally.owned}/${tally.total} · ${tally.missing} offen',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                TallyBar(
                  tally.fraction,
                  color: StageTheme.legible(
                    rarity.color,
                    theme.colorScheme.surface,
                    minimum: 3,
                  ),
                  height: 3,
                ),
              ],
            ),
          ),
        ),
        _grid(items, w, worn, padding),
      ],
      if (groups.isEmpty)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 12, padding.right, 0),
          sliver: SliverToBoxAdapter(
            child: Text(
              _missingOnly
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
        small: true,
      ),
    ),
  );

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
