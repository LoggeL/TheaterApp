import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_controller.dart';
import '../../../core/telemetry/perf_telemetry.dart';
import '../../../shared/feedback.dart';
import '../data/missions_api.dart' show missionsAvailable;
import '../data/wardrobe_api.dart';
import '../domain/crate_reel.dart';
import 'crate_animation.dart';
import 'crate_choice.dart' show chooseCrateTarget;
import 'event_crates_card.dart';
import 'stage_runner_art.dart';
import 'stage_runner_look.dart';
import 'stage_runner_sound.dart';
import 'wardrobe_cards.dart';

final _crateNumber = NumberFormat.decimalPattern('de');

/// Opens a costume crate with the reel animation; returns the wardrobe as
/// it is afterwards (null if nothing changed).
Future<Wardrobe?> showCrateOpening(
  BuildContext context, {
  required AppController controller,
  required Wardrobe wardrobe,
  required RunnerSound sound,
  RunnerArt? art,
  bool ensemble = false,
  bool mission = false,
  bool event = false,
  bool gala = false,
  bool weekly = false,
  bool gage = false,
  EventCrate? eventCrate,
  PackGoal? packGoal,
  CrateTarget? target,
  Future<CrateTarget?> Function(Wardrobe wardrobe)? chooseTarget,
}) {
  final route = PageRouteBuilder<Wardrobe>(
    opaque: false,
    barrierColor: Colors.black87,
    pageBuilder: (context, _, _) => CrateOpeningPage(
      controller: controller,
      wardrobe: wardrobe,
      sound: sound,
      art: art,
      ensemble: ensemble,
      mission: mission,
      event: event,
      gala: gala,
      weekly: weekly,
      gage: gage,
      eventCrate: eventCrate,
      packGoal: packGoal,
      target: target,
      chooseTarget: chooseTarget,
    ),
    transitionsBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
  PerfTelemetry.nameRouteAs(route, 'CrateOpening');
  return Navigator.of(context).push(route);
}

enum _Phase { opening, unboxing, spinning, revealed, failed }

/// The unboxing: a short shake of the crate while the server draws, then the
/// reel runs fast and brakes long, ticking at every card, and stops on the
/// won item, which shines in its rarity colour. A tap skips to the end.
class CrateOpeningPage extends StatefulWidget {
  const CrateOpeningPage({
    super.key,
    required this.controller,
    required this.wardrobe,
    required this.sound,
    this.art,
    this.open,
    this.random,
    this.ensemble = false,
    this.mission = false,
    this.event = false,
    this.gala = false,
    this.weekly = false,
    this.gage = false,
    this.eventCrate,
    this.packGoal,
    this.target,
    this.chooseTarget,
  });
  final AppController controller;

  /// A crate of the own runs aimed at a play or the Technik-Kiste, or the
  /// Zufallskiste (`runnerCrateTargets`): it opens with its own animation.
  /// Null: the plain crate of older servers and the other crate kinds.
  final CrateTarget? target;

  /// Asks for the target of the next crate ("Nächste Kiste").
  final Future<CrateTarget?> Function(Wardrobe wardrobe)? chooseTarget;
  final Wardrobe wardrobe;
  final RunnerSound sound;
  final RunnerArt? art;

  /// An Ensemble-Kiste instead of a crate of the own metres.
  final bool ensemble;

  /// A Missionskiste (all three Tagesmissionen of a day).
  final bool mission;

  /// A Termin-Kiste: [eventCrate] if one was chosen, else the earliest.
  final bool event;
  final EventCrate? eventCrate;

  /// A Gala-Kiste of the Monatsgala, the earliest waiting.
  final bool gala;

  /// A Wochenkiste of the Wochenprobe, the earliest waiting.
  final bool weekly;

  /// A crate bought with gage: each one is paid and confirmed on its own, so
  /// it offers no "Nächste Kiste".
  final bool gage;

  /// A contributor reward restricted to this release's skin set.
  final PackGoal? packGoal;

  /// Replaces the server call in tests.
  @visibleForTesting
  final Future<CrateOpening> Function()? open;

  /// Fixes where on the card the reel stops, in tests.
  @visibleForTesting
  final Random? random;

  @override
  State<CrateOpeningPage> createState() => _CrateOpeningPageState();
}

class _CrateOpeningPageState extends State<CrateOpeningPage>
    with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Listenable _revealAnim = Listenable.merge([_glow, _pop]);
  late final CurvedAnimation _elasticPop = CurvedAnimation(
    parent: _pop,
    curve: Curves.elasticOut,
  );
  late final CurvedAnimation _easeOutBackPop = CurvedAnimation(
    parent: _pop,
    curve: Curves.easeOutBack,
  );
  final _position = ValueNotifier<double>(0);
  _Phase _phase = _Phase.opening;
  CrateOpening? _result;
  CrateReel? _reel;

  /// The reel's pictures, held while the crate is open: the shared cache
  /// may drop them meanwhile, the reel must not.
  final _pictures = <String, ui.Image>{};
  late Wardrobe _wardrobe = widget.wardrobe;

  /// The crate source currently opening; may advance to another waiting
  /// category once this one runs out.
  late bool _ensemble = widget.ensemble;
  late bool _mission = widget.mission;
  late bool _event = widget.event;
  late bool _gala = widget.gala;
  late bool _weekly = widget.weekly;
  late bool _gage = widget.gage;

  /// The Termin-Kiste to open; after the first one "Nächste Kiste" takes the
  /// earliest waiting.
  late EventCrate? _eventCrate = widget.eventCrate;

  /// The Set-Kiste's pack goal, if opening from one.
  late PackGoal? _packGoal = widget.packGoal;

  /// The target of the crate opening now; "Nächste Kiste" may choose another.
  late CrateTarget? _target = _own ? widget.target : null;

  /// True after chaining from another category into own crates with target
  /// selection, so subsequent own crates can repeat or re-pick a target even
  /// when the original caller omitted [widget.chooseTarget].
  bool _chainedTargetChoice = false;

  /// Remembered on this device: skip unboxing & reel and show the reveal at
  /// once.
  static const _fastOpenKey = 'stageRunner.fastCrateOpen';
  bool _fastOpen = false;
  bool _fastOpenTouched = false;

  /// The crate with a look of its own: it opens its own way before the reel.
  /// A Set-Kiste borrows the look of its play's crate (a set named like the
  /// play, e.g. „Eine höllische Herausforderung“), if that has one.
  CrateTarget? get _look =>
      _target ??
      (_gala
          ? _wardrobe.gala.crate
          : _weekly
          ? _wardrobe.weekly.crate
          : _packGoal != null
          ? _wardrobe.crateTargets
                .where(
                  (t) =>
                      t.kind == CrateTargetKind.play &&
                      (t.play ?? t.name) == _packGoal!.name &&
                      t.image != null,
                )
                .firstOrNull
          : null);

  // Keep the key after a failed reply: retrying must return this opening,
  // even if the server already consumed its crate before the connection failed.
  String _openingKey = crateKey();

  /// An opening that waits for its crate's animation before the reel.
  CrateOpening? _pending;

  bool get _own =>
      !_ensemble &&
      !_mission &&
      !_event &&
      !_gala &&
      !_weekly &&
      _packGoal == null;
  bool _changed = false, _wearing = false;
  String? _error;
  int _card = 0;
  Duration _lastTick = Duration.zero;
  double _skipTo = -1;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFastOpen());
    _start();
  }

  Future<void> _loadFastOpen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fast = prefs.getBool(_fastOpenKey);
      if (!mounted || _fastOpenTouched || fast != true) return;
      setState(() => _fastOpen = true);
      if (_phase == _Phase.unboxing && _pending != null) {
        _revealInstant(_pending!);
      } else if (_phase == _Phase.spinning && _reel != null) {
        _skipTo = _reel!.duration;
      }
    } catch (_) {
      // Storage may be unavailable; defaults to animated opening.
    }
  }

  void _toggleFastOpen() {
    _fastOpenTouched = true;
    final next = !_fastOpen;
    setState(() => _fastOpen = next);
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setBool(_fastOpenKey, next))
          .catchError((Object _) => false),
    );
    if (next) _skip();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elasticPop.dispose();
    _easeOutBackPop.dispose();
    _glow.dispose();
    _pop.dispose();
    _position.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    // The previous reveal is no longer visible while the next crate loads
    // or rolls. A failed request must also leave no reveal ticker running.
    _glow.stop();
    _pop.stop();
    setState(() {
      _phase = _Phase.opening;
      _error = null;
      _result = null;
      _reel = null;
      _pictures.clear();
      _position.value = 0;
    });
    widget.sound.prepare();
    try {
      final opening =
          await (widget.open ??
              () => openCrate(
                widget.controller,
                key: _openingKey,
                dupes: dupesAvailable(widget.controller),
                ensemble: _ensemble,
                mission: _mission,
                event: _event,
                gala: _gala,
                weekly: _weekly,
                gage: _gage,
                eventId: _eventCrate?.eventId,
                target: _target?.id,
                packId: _packGoal?.releaseId,
              ))();
      await _loadReel(opening);
      if (!mounted) return;
      _wardrobe = opening.wardrobe;
      _changed = true;
      _eventCrate = null;
      if (_fastOpen) {
        _revealInstant(opening);
        return;
      }
      if (_look != null) {
        // The crate opens its own way first, then the reel runs.
        widget.sound.play(RunnerSfx.whoosh);
        setState(() {
          _pending = opening;
          _phase = _Phase.unboxing;
        });
        return;
      }
      _spin(opening);
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = userMessage(e);
        });
      }
    }
  }

  /// The pictures of the reel. Around the winner it comes to rest and is
  /// looked at: only those (and the large won card) are waited for, a moment
  /// at most on a slow connection. The others follow as they come: they fly
  /// past, and all of them at once are a burst the connection handles well,
  /// but a slow one should not hold up the crate.
  Future<void> _loadReel(CrateOpening opening) {
    final reel = opening.reel, winner = opening.winnerIndex;
    final asked = <String>{};
    Future<void>? card(WardrobeItem item, {bool Function()? shown}) {
      final path = item.thumb ?? item.portrait;
      if (path == null || !asked.add(path)) return null;
      final load = item.thumb != null
          ? WardrobePictures.load(widget.controller, path, shown: shown)
          : WardrobePictures.loadPortrait(
              widget.controller,
              path,
              shown: shown,
            );
      return load.then((image) {
        if (image != null) _pictures[path] = image;
      });
    }

    final waited = [
      for (
        var i = max(0, winner - 4);
        i <= min(reel.length - 1, winner + 4);
        i++
      )
        ?card(reel[i]),
      loadLargeArt(widget.controller, opening.item),
    ];
    for (final item in reel) {
      card(item, shown: () => false);
    }
    return Future.wait(
      waited,
    ).timeout(const Duration(milliseconds: 1500), onTimeout: () => []);
  }

  /// The reel of [opening], after its crate opened (or at once).
  void _spin(CrateOpening opening) {
    if (!mounted || _phase == _Phase.spinning || _phase == _Phase.revealed) {
      return;
    }
    _pending = null;
    final quick = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    setState(() {
      _result = opening;
      _reel = CrateReel(
        winner: opening.winnerIndex,
        duration: quick ? 2.2 : 6.4,
        random: widget.random,
      );
      _phase = _Phase.spinning;
      _card = 0;
      _skipTo = -1;
    });
    _lastTick = Duration.zero;
    _ticker
      ..stop()
      ..start();
  }

  /// Jumps directly to the revealed item (skipping both unboxing and reel).
  void _revealInstant(CrateOpening opening) {
    if (!mounted || _phase == _Phase.revealed) return;
    _pending = null;
    final reel = CrateReel(
      winner: opening.winnerIndex,
      duration: 6.4,
      random: widget.random,
    );
    _ticker.stop();
    _result = opening;
    _reel = reel;
    _card = opening.winnerIndex;
    _skipTo = reel.duration;
    _position.value = reel.stop;
    _reveal();
  }

  bool get _hasTargetChoice =>
      widget.chooseTarget != null || _chainedTargetChoice;

  Future<CrateTarget?> _chooseTarget(Wardrobe w) => widget.chooseTarget != null
      ? widget.chooseTarget!(w)
      : chooseCrateTarget(
          context,
          controller: widget.controller,
          wardrobe: w,
          art: widget.art,
        );

  /// "Nächste Kiste": with a choice the target is asked again unless
  /// [sameTarget] repeats the current target directly.
  Future<void> _next({bool sameTarget = false}) async {
    if (_own && _target != null) {
      if (sameTarget) {
        _target = _wardrobe.crateTarget(_target!.id) ?? _target;
      } else if (_hasTargetChoice) {
        final next = await _chooseTarget(_wardrobe);
        if (next == null || !mounted) return;
        _target = next;
      }
    }
    _openingKey = crateKey();
    await _start();
  }

  void _resetSource() {
    _ensemble = false;
    _mission = false;
    _event = false;
    _gala = false;
    _weekly = false;
    _gage = false;
    _eventCrate = null;
    _packGoal = null;
    _target = null;
    _chainedTargetChoice = false;
  }

  /// Next waiting crate from another category once the current one is empty.
  ({String label, IconData icon, Future<void> Function() open})?
  _nextCategory() {
    final w = _wardrobe;
    final p = w.progress;
    final c = widget.controller;
    String withCount(String name, int n) =>
        n > 1 ? 'Nächste: $name ($n)' : 'Nächste: $name';
    if (!_own && p.crates > 0 && (p.dupes || !p.complete)) {
      return (
        label: withCount('Kostümkiste', p.crates),
        icon: Icons.inventory_2_outlined,
        open: () async {
          CrateTarget? chosen;
          var usedChoice = false;
          if (crateTargetsAvailable(c) && w.crateTargets.isNotEmpty) {
            chosen = await _chooseTarget(w);
            if (chosen == null || !mounted) return;
            usedChoice = true;
          }
          _resetSource();
          _target = chosen;
          _chainedTargetChoice = usedChoice;
          _openingKey = crateKey();
          await _start();
        },
      );
    }
    if (!_mission && missionsAvailable(c) && p.missionCrates > 0) {
      return (
        label: withCount('Missionskiste', p.missionCrates),
        icon: Icons.flag_outlined,
        open: () async {
          _resetSource();
          _mission = true;
          _openingKey = crateKey();
          await _start();
        },
      );
    }
    final ensembleLeft = w.ensemble?.crates ?? 0;
    if (!_ensemble && ensembleAvailable(c) && ensembleLeft > 0) {
      return (
        label: withCount('Ensemble-Kiste', ensembleLeft),
        icon: Icons.groups_outlined,
        open: () async {
          _resetSource();
          _ensemble = true;
          _openingKey = crateKey();
          await _start();
        },
      );
    }
    if (!_event && eventCratesAvailable(c) && w.eventCrates.isNotEmpty) {
      final first = w.eventCrates.first;
      return (
        label: withCount('Termin-Kiste', w.eventCrates.length),
        icon: Icons.event_available,
        open: () async {
          _resetSource();
          _event = true;
          _eventCrate = first;
          _openingKey = crateKey();
          await _start();
        },
      );
    }
    if (!_gala && monthlyGalaAvailable(c) && w.gala.crates > 0) {
      return (
        label: withCount('Gala-Kiste', w.gala.crates),
        icon: Icons.theater_comedy_outlined,
        open: () async {
          _resetSource();
          _gala = true;
          _openingKey = crateKey();
          await _start();
        },
      );
    }
    if (!_weekly && weeklyRewardsAvailable(c) && w.weekly.crates > 0) {
      return (
        label: withCount('Wochenkiste', w.weekly.crates),
        icon: Icons.emoji_events_outlined,
        open: () async {
          _resetSource();
          _weekly = true;
          _openingKey = crateKey();
          await _start();
        },
      );
    }
    if (packGoalsAvailable(c)) {
      final other = w.packGoals
          .where((g) => g.crates > 0 && g.releaseId != _packGoal?.releaseId)
          .firstOrNull;
      if (other != null) {
        return (
          label: withCount('Set-Kiste · ${other.name}', other.crates),
          icon: Icons.collections_outlined,
          open: () async {
            _resetSource();
            _packGoal = other;
            _openingKey = crateKey();
            await _start();
          },
        );
      }
    }
    return null;
  }

  /// Contextual progress pills shown below the outcome in [_revealView].
  List<({IconData icon, String text, bool highlight})> _revealContext(
    CrateOpening result,
  ) {
    final chips = <({IconData icon, String text, bool highlight})>[];
    final outcome = result.outcome;
    final w = _wardrobe;
    if (outcome.type == 'gage') {
      chips.add((
        icon: Icons.payments_outlined,
        text: 'Kontostand: ${_crateNumber.format(w.gage)} Gage',
        highlight: false,
      ));
      final offers = <({int price, String label})>[
        if (gageCratesAvailable(widget.controller))
          if (w.catalog.dupes.crateGage case final price?)
            (price: price, label: 'Kostümkiste'),
        for (final t in w.trades)
          (
            price: t.cost,
            label: 'Tauschvertrag (${w.catalog.rarity(t.to)?.name ?? t.to})',
          ),
      ]..sort((a, b) => a.price.compareTo(b.price));
      if (offers.isNotEmpty) {
        final affordable = offers.where((o) => o.price <= w.gage).toList();
        if (affordable.isNotEmpty) {
          chips.add((
            icon: Icons.check_circle_outline,
            text: 'Reicht für ${affordable.last.label}',
            highlight: true,
          ));
        } else {
          final next = offers.first;
          chips.add((
            icon: Icons.savings_outlined,
            text:
                'Noch ${_crateNumber.format(next.price - w.gage)} Gage bis ${next.label}',
            highlight: false,
          ));
        }
      }
      return chips;
    }
    if (outcome.type == 'new' ||
        outcome.type == 'shine' ||
        outcome.type == 'variant') {
      if (_target case final target?) {
        final updated = w.crateTarget(target.id);
        if (updated != null && updated.total > 0) {
          chips.add((
            icon: updated.complete
                ? Icons.check_circle_outline
                : Icons.inventory_2_outlined,
            text: updated.complete
                ? '${updated.title}: ${updated.owned}/${updated.total} · komplett!'
                : '${updated.title}: ${updated.owned}/${updated.total}',
            highlight: updated.complete,
          ));
        }
      }
      if (w.collectible > 0 && _target?.isRandom != true) {
        chips.add((
          icon: Icons.style_outlined,
          text: 'Sammlung: ${w.collected}/${w.collectible}',
          highlight: w.collected >= w.collectible,
        ));
      }
      final item = result.item;
      final uniques = w.uniqueFigures?.plays;
      if (uniques != null && uniques.isNotEmpty) {
        final isTech =
            item.kind == WardrobeKind.character &&
            (item.role?.isFunction ?? false);
        final play = item.role?.play;
        final match = uniques.where((u) {
          if (isTech) return u.allTechnicians;
          if (play == null) return false;
          return !u.allTechnicians &&
              !u.itemSet &&
              (u.play == play || u.parts.any((part) => part.play == play));
        }).firstOrNull;
        if (match != null && match.total > 0) {
          final missing = max(0, match.total - match.have);
          chips.add((
            icon: Icons.auto_awesome,
            text: match.unlocked
                ? 'Unique freigeschaltet: ${match.name}!'
                : missing == 1
                ? 'Noch 1 Figur bis Unique (${match.production})'
                : 'Unique (${match.production}): ${match.have}/${match.total}',
            highlight: match.unlocked || missing == 1,
          ));
        }
      }
    }
    return chips;
  }

  Widget _fastOpenToggle() => TextButton.icon(
    key: const ValueKey('crate-fast-open'),
    onPressed: _toggleFastOpen,
    style: TextButton.styleFrom(
      foregroundColor: _fastOpen ? const Color(0xFFFFD86B) : Colors.white60,
      visualDensity: VisualDensity.compact,
    ),
    icon: Icon(_fastOpen ? Icons.bolt : Icons.bolt_outlined, size: 18),
    label: Text(_fastOpen ? 'Schnell öffnen: An' : 'Schnell öffnen'),
  );

  void _tick(Duration elapsed) {
    final reel = _reel;
    if (reel == null) return;
    var t = elapsed.inMicroseconds / 1e6;
    if (_skipTo >= 0) t = _skipTo;
    _position.value = reel.position(t);
    final card = reel.cardAt(t);
    if (card != _card) {
      _card = card;
      // One tick per card, but never closer than 35 ms: at full speed the
      // cards pass faster than a click can sound.
      if (_skipTo < 0 &&
          elapsed - _lastTick >= const Duration(milliseconds: 35)) {
        _lastTick = elapsed;
        widget.sound.play(RunnerSfx.tick);
      }
    }
    if (reel.done(t)) {
      _ticker.stop();
      _reveal();
    }
  }

  /// A new shine: its own, bigger reveal.
  bool get _shine => _result?.outcome.shineNew ?? false;

  bool get _jackpot {
    final item = _result?.item;
    if (item == null) return false;
    if (_shine) return true;
    final rarities = _wardrobe.catalog.rarities;
    return rarities.isNotEmpty &&
        _wardrobe.catalog.rarityOf(item).id == rarities.last.id;
  }

  void _reveal() {
    widget.sound.play(_jackpot ? RunnerSfx.jackpot : RunnerSfx.reveal);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    setState(() => _phase = _Phase.revealed);
    if (reduced) {
      _pop.value = 1;
      _glow.value = 0;
    } else {
      _pop.forward(from: 0);
      _glow.repeat();
    }
  }

  void _skip() {
    if (_phase == _Phase.unboxing && _pending != null) {
      _revealInstant(_pending!);
      return;
    }
    if (_phase == _Phase.spinning && _reel != null) {
      _skipTo = _reel!.duration;
    }
  }

  Future<void> _wear(WardrobeItem item, [WardrobeVariant? role]) async {
    setState(() => _wearing = true);
    try {
      final next = await wearItem(widget.controller, item, variant: role);
      if (mounted) setState(() => _wardrobe = next);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _wearing = false);
    }
  }

  void _close() => Navigator.of(context).pop(_changed ? _wardrobe : null);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _phase != _Phase.spinning && _phase != _Phase.unboxing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _skip();
    },
    child: Scaffold(
      backgroundColor: const Color(0xF2101412),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _skip,
          child: switch (_phase) {
            _Phase.opening when _look != null => _unboxing(context, false),
            _Phase.unboxing => _unboxing(context, true),
            _Phase.opening => _opening(context),
            _Phase.failed => _failed(context),
            _ => _stage(context),
          },
        ),
      ),
    ),
  );

  Widget _opening(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ShakingCrate(vsync: this),
        const SizedBox(height: 24),
        Text(
          _packGoal != null
              ? 'Die Set-Kiste geht auf …'
              : _gala
              ? 'Die Gala-Kiste geht auf …'
              : _weekly
              ? 'Die Wochenkiste geht auf …'
              : _event
              ? 'Die Termin-Kiste geht auf …'
              : _mission
              ? 'Die Missionskiste geht auf …'
              : _ensemble
              ? 'Die Ensemble-Kiste geht auf …'
              : 'Die Kostümkiste geht auf …',
          style: const TextStyle(color: Colors.white70, fontSize: 16),
        ),
        const SizedBox(height: 16),
        _fastOpenToggle(),
      ],
    ),
  );

  /// A crate of the own runs in its own look: wobbling while the server
  /// draws, then [opening] it its own way (see [CrateMotion]).
  Widget _unboxing(BuildContext context, bool opening) {
    final target = _look!;
    final quick = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final size = min(220.0, MediaQuery.sizeOf(context).shortestSide * .5);
    return Stack(
      children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CrateUnboxing(
                key: ValueKey('crate-unboxing-${target.id}'),
                target: target,
                controller: widget.controller,
                art: widget.art,
                opening: opening,
                quick: quick,
                size: size,
                onOpened: () {
                  if (_pending case final pending?) _spin(pending);
                },
              ),
              Text(
                _packGoal != null
                    ? 'Die Set-Kiste geht auf …'
                    : '${_crateName(target)} geht auf …',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (opening)
                const Text(
                  'Antippen zum Überspringen',
                  key: ValueKey('crate-skip-hint'),
                  style: TextStyle(color: Colors.white38),
                ),
              const SizedBox(height: 4),
              _fastOpenToggle(),
            ],
          ),
        ),
      ],
    );
  }

  /// "Die Zufallskiste", "Die Technik-Kiste", "Die Kiste „Creepshow“".
  static String _crateName(CrateTarget t) => t.kind == CrateTargetKind.play
      ? 'Die Kiste „${t.name}“'
      : 'Die ${t.name}';

  Widget _failed(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.inventory_2_outlined,
            color: Colors.white54,
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            _error ?? 'Die Kiste klemmt.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                onPressed: _start,
                child: const Text('Erneut versuchen'),
              ),
              OutlinedButton(onPressed: _close, child: const Text('Schließen')),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _stage(BuildContext context) {
    final result = _result!;
    final revealed = _phase == _Phase.revealed;
    return LayoutBuilder(
      builder: (context, box) {
        final cardWidth = (box.maxWidth / 5.2).clamp(92.0, 150.0);
        return Stack(
          children: [
            Column(
              children: [
                const SizedBox(height: 16),
                Text(
                  revealed
                      ? 'Aus der Kiste:'
                      : _packGoal != null
                      ? 'Set-Kiste · ${result.outcome.packName ?? _packGoal!.name}'
                      : _gala
                      ? 'Gala-Kiste'
                      : _weekly
                      ? 'Wochenkiste'
                      : _event
                      ? eventCrateTitle(result.outcome.event ?? _eventCrate)
                      : _mission
                      ? 'Missionskiste'
                      : _ensemble
                      ? 'Ensemble-Kiste'
                      : _target?.title ?? 'Kostümkiste',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 15,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: cardWidth * 1.25 + 40,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      key: const ValueKey('crate-reel'),
                      size: Size.infinite,
                      painter: _ReelPainter(
                        result.reel,
                        _wardrobe.catalog,
                        widget.art,
                        _position,
                        cardWidth,
                        dim: revealed,
                        pictures: _pictures,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                if (!revealed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Antippen zum Überspringen',
                          key: ValueKey('crate-skip-hint'),
                          style: TextStyle(color: Colors.white38),
                        ),
                        const SizedBox(height: 4),
                        _fastOpenToggle(),
                      ],
                    ),
                  ),
              ],
            ),
            if (revealed) Positioned.fill(child: _revealView(context, result)),
          ],
        );
      },
    );
  }

  Widget _revealView(BuildContext context, CrateOpening result) {
    final item = result.item;
    final catalog = _wardrobe.catalog;
    final rarity = catalog.rarityOf(item);
    final shine = _shine;
    final colors = shine ? shineColors : rarityColors(catalog, item);
    final jackpot = _jackpot;
    final outcome = result.outcome;
    final role = outcome.type == 'variant'
        ? item.variants.where((v) => v.id == outcome.variantId).firstOrNull
        : null;
    final worn =
        _wardrobe.worn(item.kind)?.id == item.id &&
        (role == null || _wardrobe.variantOf(item)?.id == role.id);
    final p = _wardrobe.progress;
    final left = _gage
        ? 0
        : _packGoal != null
        ? _wardrobe.packGoal(_packGoal!.releaseId)?.crates ?? 0
        : _gala
        ? _wardrobe.gala.crates
        : _weekly
        ? _wardrobe.weekly.crates
        : _event
        ? _wardrobe.eventCrates.length
        : _mission
        ? p.missionCrates
        : _ensemble
        ? _wardrobe.ensemble?.crates ?? 0
        : p.crates;
    final more =
        left > 0 &&
        (_packGoal != null ||
            _ensemble ||
            _mission ||
            _event ||
            _gala ||
            _weekly ||
            p.dupes ||
            !p.complete);
    final currentTarget = _own && _target != null
        ? _wardrobe.crateTarget(_target!.id) ?? _target
        : null;
    final canRepeatTarget =
        more &&
        currentTarget != null &&
        currentTarget.available &&
        _hasTargetChoice;
    final nextCategory = !_gage && !more ? _nextCategory() : null;
    final contextChips = _revealContext(result);
    final line = outcome.type == 'new' && outcome.shiny
        ? 'Neu – und gleich in Glanz!'
        : outcome.line;
    final label = catalog.labelOf(item);
    // "als Johanna · Anno 1146 2025": the role just won, else the one the
    // card shows.
    final playing = role != null
        ? role.role ?? outcome.variantRole
        : _wardrobe.roleOf(item);
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _GlowPainter(
                  colors,
                  _glow,
                  _pop,
                  _revealAnim,
                  jackpot: jackpot,
                ),
              ),
            ),
          ),
        ),
        SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (shine)
                ScaleTransition(
                  scale: _elasticPop,
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _glow,
                      builder: (context, _) {
                        // Direct foreground shader avoids ShaderMask's per-frame
                        // offscreen saveLayer FBO on CanvasKit/iOS WebGL.
                        final paint = Paint()
                          ..shader = LinearGradient(
                            colors: const [
                              Color(0xFFFFD86B),
                              Color(0xFFFFFFFF),
                              Color(0xFFB8F1FF),
                              Color(0xFFFFC2F0),
                              Color(0xFFFFD86B),
                            ],
                            transform: GradientRotation(_glow.value * 2 * pi),
                            tileMode: TileMode.mirror,
                          ).createShader(const Rect.fromLTWH(0, 0, 260, 56));
                        return Text(
                          'GLANZ!',
                          key: const ValueKey('crate-shine'),
                          style: TextStyle(
                            foreground: paint,
                            fontSize: 44,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 6,
                            shadows: kIsWeb
                                ? const [
                                    Shadow(
                                      color: Color(0x88FFE7A3),
                                      offset: Offset(0, 2),
                                    ),
                                  ]
                                : const [
                                    Shadow(
                                      color: Color(0xFFFFE7A3),
                                      blurRadius: 28,
                                    ),
                                  ],
                          ),
                        );
                      },
                    ),
                  ),
                )
              else if (jackpot)
                ScaleTransition(
                  scale: _elasticPop,
                  child: RepaintBoundary(
                    child: Text(
                      '${rarity.name.toUpperCase()}!',
                      style: TextStyle(
                        color: rarity.color,
                        fontSize: 40,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4,
                        shadows: [
                          Shadow(
                            color: rarity.color,
                            blurRadius: kIsWeb ? 8 : 24,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              ScaleTransition(
                scale: jackpot ? _elasticPop : _easeOutBackPop,
                child: SizedBox(
                  width: 200,
                  height: 250,
                  child: WardrobeCard(
                    key: const ValueKey('crate-won'),
                    item: item,
                    wardrobe: _wardrobe,
                    controller: widget.controller,
                    art: widget.art,
                    worn: worn,
                    animateShine: true,
                    role: role,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                item.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (playing != null && !item.reward)
                Text(
                  playing.line,
                  key: const ValueKey('crate-role'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                [
                  item.kind.singular,
                  ...catalog.raritiesOf(item).map((r) => r.name),
                  ?label,
                ].join(' · '),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.first,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (line != null) ...[
                const SizedBox(height: 10),
                Container(
                  key: const ValueKey('crate-outcome'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: colors.first.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: colors.first.withValues(alpha: .6),
                    ),
                  ),
                  child: Text(
                    line,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
              if (contextChips.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  key: const ValueKey('crate-context'),
                  spacing: 8,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final chip in contextChips)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: chip.highlight
                              ? const Color(0x33FFD86B)
                              : Colors.white.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: chip.highlight
                                ? const Color(0x99FFD86B)
                                : Colors.white24,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              chip.icon,
                              size: 14,
                              color: chip.highlight
                                  ? const Color(0xFFFFD86B)
                                  : Colors.white70,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              chip.text,
                              style: TextStyle(
                                color: chip.highlight
                                    ? const Color(0xFFFFE7A3)
                                    : Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              if (item.rarityReason case final reason?) ...[
                const SizedBox(height: 6),
                Text(
                  reason,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (!worn)
                    FilledButton.icon(
                      onPressed: _wearing ? null : () => _wear(item, role),
                      icon: const Icon(Icons.checkroom),
                      label: Text(role == null ? 'Anlegen' : 'Rolle anlegen'),
                    ),
                  if (canRepeatTarget)
                    FilledButton.tonalIcon(
                      key: const ValueKey('crate-next-same'),
                      onPressed: () => _next(sameTarget: true),
                      icon: const Icon(Icons.replay),
                      label: const Text('Gleiche Kiste nochmal'),
                    ),
                  if (more)
                    Tooltip(
                      message: canRepeatTarget
                          ? 'Anderes Ziel wählen'
                          : 'Nächste Kiste öffnen',
                      child: FilledButton.tonalIcon(
                        key: const ValueKey('crate-next-choose'),
                        onPressed: _next,
                        icon: Icon(
                          canRepeatTarget
                              ? Icons.tune
                              : Icons.inventory_2_outlined,
                        ),
                        label: Text('Nächste Kiste ($left)'),
                      ),
                    )
                  else if (nextCategory != null)
                    FilledButton.tonalIcon(
                      key: const ValueKey('crate-next-category'),
                      onPressed: nextCategory.open,
                      icon: Icon(nextCategory.icon),
                      label: Text(nextCategory.label),
                    ),
                  OutlinedButton(
                    onPressed: _close,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Fertig'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _fastOpenToggle(),
            ],
          ),
        ),
      ],
    );
  }
}

/// The closed crate wobbling while the server draws.
class _ShakingCrate extends StatefulWidget {
  const _ShakingCrate({required this.vsync});
  final TickerProvider vsync;
  @override
  State<_ShakingCrate> createState() => _ShakingCrateState();
}

class _ShakingCrateState extends State<_ShakingCrate> {
  late final AnimationController _shake = AnimationController(
    vsync: widget.vsync,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _shake.stop();
    } else if (!_shake.isAnimating) {
      _shake.repeat();
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _shake,
      builder: (context, child) => Transform.rotate(
        angle: sin(_shake.value * 2 * pi) * .08,
        child: child,
      ),
      child: const Icon(Icons.inventory_2, size: 96, color: Color(0xFFB07A45)),
    ),
  );
}

class _ReelCardStyle {
  _ReelCardStyle(this.antique, this.ground, this.bar, this.name);
  final bool antique;
  final Paint ground, bar;
  final TextPainter name;
}

/// The reel: cards side by side, the marker in the middle. Everything is
/// laid out once; a frame only moves the cards.
class _ReelPainter extends CustomPainter {
  _ReelPainter(
    this.items,
    this.catalog,
    this.art,
    this.position,
    this.cardWidth, {
    this.dim = false,
    this.pictures = const {},
  }) : super(repaint: position);

  /// Pictures by path, held by the opening (see [paintItemArt]).
  final Map<String, ui.Image> pictures;
  final List<WardrobeItem> items;
  final WardrobeCatalog catalog;
  final RunnerArt? art;
  final ValueListenable<double> position;
  final double cardWidth;
  final bool dim;

  static const _gap = 8.0;
  static const _cardRadius = Radius.circular(10);
  final _styles = <String, _ReelCardStyle>{};
  final _bars = <String, Paint>{};
  final _grounds = <String, Paint>{};
  static final _ink = Paint()..color = wardrobeInk;
  static final _antiqueInk = Paint()..color = const Color(0xFF2A2117);
  static final _marker = Paint()
    ..color = const Color(0xFFFFE7A3)
    ..strokeWidth = 3;
  static final _shade = Paint()..color = const Color(0xD0000000);
  static final _markerPath = Path();

  Size? _fadeSize;
  late Rect _leftFadeRect, _rightFadeRect;
  late Paint _leftFadePaint, _rightFadePaint;

  _ReelCardStyle _styleFor(WardrobeItem item, double h) =>
      _styles[item.id] ??= () {
        final colors = rarityColors(catalog, item);
        final antique = catalog.rarityOf(item).antique;
        final key = colors.map((c) => c.toARGB32()).join(',');
        final ground = _grounds[key] ??= Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, colors.first.withValues(alpha: .38)],
          ).createShader(Rect.fromLTWH(0, 0, cardWidth, h));
        final bar = _bars[key] ??= colors.length == 1
            ? (Paint()..color = colors.first)
            : (Paint()
                ..shader = rarityGradient(
                  colors,
                ).createShader(Rect.fromLTWH(0, h - 7, cardWidth, 7)));
        final name = TextPainter(
          text: TextSpan(
            text: item.name,
            style: TextStyle(
              // On the web the bundled font avoids loading fallback fonts.
              fontFamily: kIsWeb ? 'Roboto' : null,
              color: Colors.white,
              fontSize: cardWidth * .11,
              fontWeight: FontWeight.w700,
            ),
          ),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: cardWidth - 12);
        return _ReelCardStyle(antique, ground, bar, name);
      }();

  @override
  void paint(Canvas canvas, Size size) {
    final pitch = cardWidth + _gap, h = cardWidth * 1.25;
    final top = (size.height - h) / 2, center = size.width / 2;
    final p = position.value;
    final first = max(0, (p - center / pitch - 1).floor());
    final last = min(items.length - 1, (p + center / pitch + 1).ceil());
    final localCard = RRect.fromLTRBR(0, 0, cardWidth, h, _cardRadius);
    final artRect = Rect.fromLTWH(8, 8, cardWidth - 16, h * .66);
    final barRRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, h - 7, cardWidth, 7),
      bottomLeft: _cardRadius,
      bottomRight: _cardRadius,
    );
    final nameOffset = Offset(6, h * .72);
    for (var i = first; i <= last; i++) {
      final item = items[i];
      final style = _styleFor(item, h);
      final left = center + (i - p) * pitch - cardWidth / 2;
      canvas.save();
      canvas.translate(left, top);
      // Draw rounded card directly without per-card clipRRect stencil passes.
      canvas.drawRRect(localCard, style.antique ? _antiqueInk : _ink);
      canvas.drawRRect(localCard, style.ground);
      paintItemArt(
        canvas,
        artRect,
        item,
        art,
        antique: style.antique,
        portrait: pictures[item.thumb ?? item.portrait],
        lowQuality: kIsWeb,
      );
      style.name.paint(canvas, nameOffset);
      canvas.drawRRect(barRRect, style.bar);
      canvas.restore();
    }
    // Edges fade into the dark, so the eye stays on the marker.
    if (_fadeSize != size) {
      _fadeSize = size;
      final fade = size.width * .18;
      _leftFadeRect = Rect.fromLTWH(0, 0, fade, size.height);
      _rightFadeRect = Rect.fromLTWH(size.width - fade, 0, fade, size.height);
      _leftFadePaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xF2101412), Color(0x00101412)],
        ).createShader(_leftFadeRect);
      _rightFadePaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [Color(0xF2101412), Color(0x00101412)],
        ).createShader(_rightFadeRect);
    }
    canvas.drawRect(_leftFadeRect, _leftFadePaint);
    canvas.drawRect(_rightFadeRect, _rightFadePaint);
    // Behind the won card the reel only sets the scene: dark enough for the
    // title and rarity in front, and without the marker running through them.
    if (dim) {
      canvas.drawRect(Offset.zero & size, _shade);
      return;
    }
    final topY = top - 14, bottomY = top + h + 14;
    canvas.drawLine(Offset(center, topY), Offset(center, bottomY), _marker);
    _markerPath
      ..reset()
      ..moveTo(center - 9, topY)
      ..lineTo(center + 9, topY)
      ..lineTo(center, topY + 11)
      ..close()
      ..moveTo(center - 9, bottomY)
      ..lineTo(center + 9, bottomY)
      ..lineTo(center, bottomY - 11)
      ..close();
    canvas.drawPath(_markerPath, _marker);
  }

  @override
  bool shouldRepaint(_ReelPainter old) =>
      old.items != items ||
      old.art != art ||
      old.cardWidth != cardWidth ||
      old.dim != dim;
}

/// The shine behind the won card: turning rays in the rarity colours; the
/// rarest rarity gets more of them and a burst of sparks.
class _GlowPainter extends CustomPainter {
  _GlowPainter(
    this.colors,
    this.turn,
    this.pop,
    Listenable repaint, {
    this.jackpot = false,
  }) : super(repaint: repaint);
  final List<Color> colors;
  final Animation<double> turn, pop;
  final bool jackpot;

  static final _rayPath = Path();
  static final _rayPaint = Paint();
  static final _sparkPaint = Paint();
  static final _sparks = () {
    final random = Random(7);
    return [
      for (var i = 0; i < 60; i++)
        () {
          final a = random.nextDouble() * 2 * pi;
          return (
            cos(a),
            sin(a),
            .25 + random.nextDouble() * .55,
            2.0 + random.nextDouble() * 3.0,
          );
        }(),
    ];
  }();

  final _haloPaint = Paint();
  Size? _haloSize;
  double _haloRadius = -1;
  Color? _haloColor;

  @override
  void paint(Canvas canvas, Size size) {
    final p = pop.value;
    final c = Offset(size.width / 2, size.height * .42);
    final r =
        size.longestSide * (jackpot ? .75 : .5) * Curves.easeOut.transform(p);
    if (r <= 0) return;
    if (_haloSize != size ||
        (_haloRadius - r).abs() > .5 ||
        _haloColor != colors.first) {
      _haloSize = size;
      _haloRadius = r;
      _haloColor = colors.first;
      _haloPaint.shader = RadialGradient(
        colors: [
          colors.first.withValues(alpha: jackpot ? .55 : .4),
          colors.first.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    }
    canvas.drawCircle(c, r, _haloPaint);
    final rays = jackpot ? 18 : 10;
    final baseAngle = turn.value * 2 * pi;
    final step = 2 * pi / rays;
    for (var i = 0; i < rays; i++) {
      final a = baseAngle + i * step;
      final color = colors[i % colors.length];
      _rayPath
        ..reset()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + cos(a - .06) * r, c.dy + sin(a - .06) * r)
        ..lineTo(c.dx + cos(a + .06) * r, c.dy + sin(a + .06) * r)
        ..close();
      _rayPaint.color = color.withValues(alpha: .16);
      canvas.drawPath(_rayPath, _rayPaint);
    }
    if (!jackpot) return;
    // Sparks fly out once and fall.
    final shortest = size.shortestSide;
    final dropY = 120 * p * p;
    final alpha = 1 - p * .7;
    final primarySpark = colors.first.withValues(alpha: alpha);
    final whiteSpark = Colors.white.withValues(alpha: alpha);
    final radiusScale = 1 - p * .6;
    for (var i = 0; i < _sparks.length; i++) {
      final (ca, sa, speed, radius) = _sparks[i];
      final d = shortest * speed * p;
      _sparkPaint.color = i.isEven ? primarySpark : whiteSpark;
      canvas.drawCircle(
        Offset(c.dx + ca * d, c.dy + sa * d + dropY),
        radius * radiusScale,
        _sparkPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.colors != colors || old.jackpot != jackpot;
}
