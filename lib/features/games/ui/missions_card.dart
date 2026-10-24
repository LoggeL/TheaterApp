import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../data/missions_api.dart';

final _number = NumberFormat.decimalPattern('de');

/// "120/300 m", "3/3 Läufe", "4/25 Bonbons" ([names]: the worn backdrop's
/// `collectibleNames`).
String missionProgressText(
  DailyMission m, [
  Map<String, String> names = const {},
]) =>
    '${_number.format(m.progress)}/${_number.format(m.target)} ${m.unitFor(names)}'
        .trim();

/// "+600 m für die Kisten".
String missionRewardText(DailyMission m) =>
    '+${_number.format(m.reward)} m für die Kisten';

/// "Tagesmissionen": the day's three missions with progress, reward and a
/// free reroll. Loads them itself when [missions] is not given.
class DailyMissionsCard extends StatefulWidget {
  const DailyMissionsCard({
    super.key,
    required this.controller,
    this.missions,
    this.onChanged,
    this.crates = 0,
    this.onOpenCrate,
    this.collectibleNames = const {},
  });
  final AppController controller;

  /// What the worn backdrop calls the pickups (`collectibleNames`).
  final Map<String, String> collectibleNames;
  final DailyMissions? missions;
  final ValueChanged<DailyMissions>? onChanged;

  /// Missionskisten waiting, and how to open one (in the wardrobe).
  final int crates;
  final VoidCallback? onOpenCrate;

  @override
  State<DailyMissionsCard> createState() => _DailyMissionsCardState();
}

class _DailyMissionsCardState extends State<DailyMissionsCard> {
  DailyMissions? _loaded;
  bool _busy = false;
  String? _error;

  DailyMissions? get _missions => widget.missions ?? _loaded;

  @override
  void initState() {
    super.initState();
    if (widget.missions == null) _load();
  }

  Future<void> _load() async {
    try {
      final m = await loadMissions(widget.controller);
      if (!mounted) return;
      setState(() {
        _loaded = m;
        _error = null;
      });
      widget.onChanged?.call(m);
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
    }
  }

  Future<void> _reroll(DailyMission m) async {
    setState(() => _busy = true);
    try {
      final next = await rerollMission(widget.controller, m.slot);
      if (!mounted) return;
      setState(() {
        _loaded = next;
        _error = null;
      });
      widget.onChanged?.call(next);
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = _missions;
    final done = m?.missions.where((x) => x.done).length ?? 0;
    return Card(
      key: const ValueKey('runner-missions'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.flag_outlined, color: StageTheme.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Tagesmissionen',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (m != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '$done/${m.missions.length} geschafft',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (m == null && _error == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (m != null)
              for (final mission in m.missions)
                _MissionRow(
                  mission,
                  names: widget.collectibleNames,
                  onReroll: m.rerollAvailable && !mission.done && !_busy
                      ? () => _reroll(mission)
                      : null,
                ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (m != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  m.allDone
                      ? 'Alle drei geschafft – die Missionskiste ist verdient.'
                      : 'Alle drei an einem Tag: eine Missionskiste dazu${m.shinyChance > 0 ? ' (${_number.format((m.shinyChance * 100).round())} % Glanzchance)' : ''}. ${m.rerollAvailable ? 'Eine Mission am Tag lässt sich neu würfeln.' : 'Heute schon neu gewürfelt.'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            if (widget.crates > 0 && widget.onOpenCrate != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.icon(
                  key: const ValueKey('mission-crate-open'),
                  onPressed: widget.onOpenCrate,
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: Text(
                    widget.crates == 1
                        ? 'Missionskiste öffnen'
                        : '${widget.crates} Missionskisten öffnen',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MissionRow extends StatelessWidget {
  const _MissionRow(this.mission, {this.onReroll, this.names = const {}});
  final DailyMission mission;
  final Map<String, String> names;
  final VoidCallback? onReroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = mission;
    return Padding(
      key: ValueKey('mission-${m.slot}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              m.done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: m.done ? StageTheme.green : theme.hintColor,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${m.slotLabel} · ${m.textFor(names)}'),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: m.fraction,
                    minHeight: 5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${missionProgressText(m, names)} · ${missionRewardText(m)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (onReroll != null)
            IconButton(
              key: ValueKey('mission-reroll-${m.slot}'),
              tooltip: 'Neu würfeln (einmal am Tag)',
              onPressed: onReroll,
              icon: const Icon(Icons.casino_outlined),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// After a run: the missions it completed, and a small celebration when the
/// day's last one fell.
class MissionRunNote extends StatelessWidget {
  const MissionRunNote(this.missions, {super.key, this.names = const {}});
  final DailyMissions missions;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = missions.justDone;
    if (done.isEmpty) return const SizedBox.shrink();
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: StageTheme.green,
      fontWeight: FontWeight.w700,
    );
    return Column(
      key: const ValueKey('runner-mission-note'),
      children: [
        for (final m in done) ...[
          const SizedBox(height: 6),
          Text(
            'Mission geschafft: ${m.textFor(names)} · ${missionRewardText(m)}',
            textAlign: TextAlign.center,
            style: style,
          ),
        ],
        if (missions.justCompletedAll) ...[
          const SizedBox(height: 10),
          TweenAnimationBuilder<double>(
            key: const ValueKey('runner-missions-all'),
            tween: Tween(begin: .6, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.elasticOut,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Column(
              children: [
                const Icon(Icons.celebration, color: StageTheme.orange),
                const SizedBox(height: 4),
                Text(
                  'Alle drei Tagesmissionen geschafft! Eine Missionskiste wartet in der Garderobe.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: StageTheme.orange,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The short banner while running, when a mission is made.
class MissionBanner extends StatelessWidget {
  const MissionBanner(this.mission, {super.key, this.names = const {}});
  final DailyMission mission;
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      key: const ValueKey('runner-mission-banner'),
      decoration: BoxDecoration(
        color: theme.colorScheme.inverseSurface.withValues(alpha: .85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.flag, size: 16, color: StageTheme.green),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Mission geschafft: ${mission.textFor(names)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
