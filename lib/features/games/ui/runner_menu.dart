import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../shared/widgets/page_header.dart';
import '../data/leaderboard_api.dart';
import '../data/runner_menu_preferences.dart';

final _number = NumberFormat.decimalPattern('de');

/// The Bühnenlauf menu ("Hub") in its parts, top down: [RunnerHero] (the
/// worn figure and the big start), [RunnerStandCard] (the own standing),
/// then the Ensemble-Strecke, [RunnerRankingCard] and the Tagesmissionen.

/// The dark stage the hero stands on, in light and dark mode alike.
final _stageTheme = StageTheme.build(Brightness.dark);

/// The worn figure and the start: the first thing on the menu, on a dark
/// stage under a spotlight.
class RunnerHero extends StatelessWidget {
  const RunnerHero({
    super.key,
    required this.figure,
    required this.name,
    required this.onStart,
    this.story,
    this.note,
    this.wardrobe,
  });

  /// The worn figure, about 88 × 116.
  final Widget figure;
  final String name;
  final String? story;

  /// Null while the game is not ready yet.
  final VoidCallback? onStart;

  /// A short line under the start, e.g. the open Tagesbonus.
  final Widget? note;

  /// The way into the wardrobe.
  final Widget? wardrobe;

  @override
  Widget build(BuildContext context) {
    final theme = _stageTheme;
    return Theme(
      data: theme,
      child: Card(
        key: const ValueKey('runner-hero'),
        clipBehavior: Clip.antiAlias,
        color: const Color(0xFF1B211D),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-.65, -1.1),
              radius: 1.25,
              colors: [Color(0x55E96131), Color(0x00E96131)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(width: 88, height: 116, child: figure),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Eyebrow(
                            'Am Flugseil',
                            color: StageTheme.onInkAccent,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            name,
                            key: const ValueKey('runner-hero-name'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge,
                          ),
                          if (story != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              story!,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xCCF2F3ED),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('runner-start'),
                  style: FilledButton.styleFrom(
                    backgroundColor: StageTheme.orange,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(56),
                    textStyle: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  onPressed: onStart,
                  icon: const Icon(Icons.play_arrow, size: 28),
                  label: const Text('Vorhang auf'),
                ),
                if (note != null) ...[const SizedBox(height: 10), note!],
                if (wardrobe != null) ...[
                  const SizedBox(height: 10),
                  wardrobe!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One figure of the own standing: a value with its label.
class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.value,
    required this.label,
    this.detail,
    this.highlight = false,
    this.onTap,
    super.key,
  });
  final IconData icon;
  final String value, label;

  /// A second, stronger line, e.g. the place in the ranking.
  final String? detail;
  final bool highlight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = highlight ? StageTheme.orange : null;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color ?? theme.hintColor),
              const SizedBox(height: 4),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(color: color),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              if (detail != null)
                Text(
                  detail!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Dein Stand": best points and place, gage, waiting crates and the
/// collection as "X von Y" with its bar; the crates and the collection lead
/// into the wardrobe ([onWardrobe]). Figures the server does not know are
/// left out.
class RunnerStandCard extends StatelessWidget {
  const RunnerStandCard({
    super.key,
    this.best,
    this.rank,
    this.players = 0,
    this.gage,
    this.crates,
    this.collected,
    this.collectible,
    this.collectionRank,
    this.monthRank,
    this.nextCrate,
    this.nextCrateFraction,
    this.onWardrobe,
  });

  /// Best points of a run, and its place among [players].
  final int? best, rank;
  final int players;

  /// The place in this month's ranking; shown instead of [rank] when known.
  final int? monthRank;
  final int? gage, crates;
  final int? collected, collectible;

  /// The place in the collection ranking.
  final int? collectionRank;

  /// "noch 376 Punkte bis zur nächsten Kiste" with its share of the way.
  final String? nextCrate;
  final double? nextCrateFraction;
  final VoidCallback? onWardrobe;

  /// Whether there is anything to show at all.
  static bool has({int? best, int? crates, int? collectible}) =>
      best != null || crates != null || (collectible ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = <Widget>[
      if (best != null)
        _Stat(
          key: const ValueKey('stand-best'),
          icon: Icons.emoji_events_outlined,
          value: _number.format(best),
          label: 'Bestwert',
          detail: monthRank != null
              ? 'Platz $monthRank diesen Monat'
              : rank == null
              ? null
              : players > 0
              ? 'Platz $rank von $players'
              : 'Platz $rank',
        ),
      if (gage != null)
        _Stat(
          key: const ValueKey('stand-gage'),
          icon: Icons.payments_outlined,
          value: _number.format(gage),
          label: 'Gage',
          onTap: onWardrobe,
        ),
      if (crates != null)
        _Stat(
          key: const ValueKey('stand-crates'),
          icon: Icons.inventory_2_outlined,
          value: '$crates',
          label: crates == 1 ? 'Kiste' : 'Kisten',
          detail: crates! > 0 ? 'bereit' : null,
          highlight: crates! > 0,
          onTap: onWardrobe,
        ),
    ];
    final total = collectible ?? 0;
    final have = collected ?? 0;
    return Card(
      key: const ValueKey('runner-stand'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text('Dein Stand', style: theme.textTheme.titleMedium),
            ),
            if (stats.isNotEmpty)
              LayoutBuilder(
                builder: (context, constraints) {
                  // Side by side while each keeps about 90 pixels.
                  final perRow = constraints.maxWidth >= stats.length * 96
                      ? stats.length
                      : 2;
                  final width =
                      (constraints.maxWidth - (perRow - 1) * 8) / perRow;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in stats) SizedBox(width: width, child: s),
                    ],
                  );
                },
              ),
            if (total > 0) ...[
              const SizedBox(height: 8),
              InkWell(
                key: const ValueKey('stand-collection'),
                borderRadius: BorderRadius.circular(12),
                onTap: onWardrobe,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 0, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.style_outlined,
                            size: 18,
                            color: StageTheme.orange,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              collectionRank == null
                                  ? 'Sammlung'
                                  : 'Sammlung · Platz $collectionRank',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          Text(
                            '$have von $total',
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (onWardrobe != null)
                            Icon(Icons.chevron_right, color: theme.hintColor),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: LinearProgressIndicator(
                          value: (have / total).clamp(0, 1).toDouble(),
                          minHeight: 8,
                          color: StageTheme.orange,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (nextCrate != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 16,
                      color: theme.hintColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        nextCrate!,
                        key: const ValueKey('stand-next-crate'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (nextCrateFraction != null)
                      SizedBox(
                        width: 56,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: nextCrateFraction,
                            minHeight: 5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

const _monthNames = [
  'Januar',
  'Februar',
  'März',
  'April',
  'Mai',
  'Juni',
  'Juli',
  'August',
  'September',
  'Oktober',
  'November',
  'Dezember',
];

/// Europe/Berlin's offset from UTC at [utc]: summer time from the last
/// Sunday in March to the last Sunday in October, 01:00 UTC each.
Duration _berlinOffset(DateTime utc) {
  final at = utc.toUtc();
  DateTime switchOf(int month) {
    final last = DateTime.utc(at.year, month + 1, 0);
    return DateTime.utc(last.year, last.month, last.day - last.weekday % 7, 1);
  }

  final summer = !at.isBefore(switchOf(3)) && at.isBefore(switchOf(10));
  return Duration(hours: summer ? 2 : 1);
}

/// The headline of a month list: "Oktober 2026 · noch 3 Tage", today
/// included, counted in German time; "· letzter Tag" on the last one.
/// [month] is `YYYY-MM`; once [endsAt] has passed only the month shows.
String? monthHeadline(String? month, DateTime? endsAt, DateTime now) {
  final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(month ?? '');
  if (m == null) return null;
  final year = int.parse(m[1]!), index = int.parse(m[2]!);
  if (index < 1 || index > 12) return null;
  final name = '${_monthNames[index - 1]} $year';
  if (endsAt != null && !now.isBefore(endsAt)) return name;
  final wall = now.toUtc().add(_berlinOffset(now));
  final next = DateTime.utc(year, index + 1);
  final days = DateTime.utc(year, index + 1, 0).day;
  final left = next
      .difference(DateTime.utc(wall.year, wall.month, wall.day))
      .inDays
      .clamp(0, days);
  if (left > 1) return '$name · noch $left Tage';
  if (left == 1) return '$name · letzter Tag';
  return name;
}

/// The rankings: the best run of this month ("Monat", the main view where
/// the server has it), the best points of all time ("Allzeit") and, where
/// the server has it, who owns the most complete collection. A switch picks
/// one; the own row stands out and stays visible below the list when it is
/// not among the first.
class RunnerRankingCard extends StatefulWidget {
  const RunnerRankingCard({
    super.key,
    required this.view,
    required this.onView,
    this.monthShown = false,
    this.monthly,
    this.now,
    this.board,
    this.boardNote,
    this.boardLoading = false,
    this.boardError,
    this.onRetryBoard,
    this.me,
    this.collectionShown = false,
    this.collection,
    this.collectionLoading = false,
    this.collectionError,
    this.onRetryCollection,
  });
  final RunnerBoardView view;
  final ValueChanged<RunnerBoardView> onView;

  /// Whether the Monatsrangliste is offered (announced and not failed);
  /// [monthly] is null while it loads.
  final bool monthShown;
  final Leaderboard? monthly;

  /// The time the month's days are counted from; now by default.
  final DateTime? now;

  /// The best points of all time; [boardNote] instead where there is no list at all
  /// (the demo, older servers).
  final Leaderboard? board;
  final String? boardNote;
  final bool boardLoading;
  final String? boardError;
  final VoidCallback? onRetryBoard;

  /// The member's person, to find the own row of the points.
  final int? me;

  /// Whether the collection ranking is offered (and not refused with 404).
  final bool collectionShown;
  final CollectionBoard? collection;
  final bool collectionLoading;
  final String? collectionError;
  final VoidCallback? onRetryCollection;

  /// Rows before "Alle anzeigen".
  static const shortList = 10;

  @override
  State<RunnerRankingCard> createState() => _RunnerRankingCardState();
}

class _RunnerRankingCardState extends State<RunnerRankingCard> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final view = switch (widget.view) {
      RunnerBoardView.month when widget.monthShown => RunnerBoardView.month,
      RunnerBoardView.collection when widget.collectionShown =>
        RunnerBoardView.collection,
      RunnerBoardView.collection when widget.monthShown =>
        RunnerBoardView.month,
      _ => RunnerBoardView.score,
    };
    final three = widget.monthShown && widget.collectionShown;
    return Card(
      key: const ValueKey('runner-ranking'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.emoji_events_outlined,
                  color: StageTheme.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Rangliste', style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            if (widget.monthShown || widget.collectionShown) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<RunnerBoardView>(
                  key: const ValueKey('ranking-switch'),
                  showSelectedIcon: false,
                  // Three labels need the room of their icons on a phone.
                  segments: [
                    if (widget.monthShown)
                      ButtonSegment(
                        value: RunnerBoardView.month,
                        icon: three
                            ? null
                            : const Icon(
                                Icons.calendar_month_outlined,
                                size: 18,
                              ),
                        label: const Text('Monat'),
                      ),
                    ButtonSegment(
                      value: RunnerBoardView.score,
                      icon: three
                          ? null
                          : const Icon(Icons.bolt_outlined, size: 18),
                      label: Text(widget.monthShown ? 'Allzeit' : 'Punkte'),
                    ),
                    if (widget.collectionShown)
                      ButtonSegment(
                        value: RunnerBoardView.collection,
                        icon: three
                            ? null
                            : const Icon(Icons.style_outlined, size: 18),
                        label: const Text('Sammlung'),
                      ),
                  ],
                  selected: {view},
                  onSelectionChanged: (s) {
                    setState(() => _all = false);
                    widget.onView(s.first);
                  },
                ),
              ),
            ],
            const SizedBox(height: 10),
            ...switch (view) {
              RunnerBoardView.month => _month(context),
              RunnerBoardView.score => _score(context),
              RunnerBoardView.collection => _collection(context),
            },
          ],
        ),
      ),
    );
  }

  Widget _retry(String text, VoidCallback? onRetry) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(text),
      if (onRetry != null)
        TextButton(onPressed: onRetry, child: const Text('Erneut laden')),
    ],
  );

  static const _loading = Padding(
    padding: EdgeInsets.symmetric(vertical: 12),
    child: Center(child: CircularProgressIndicator()),
  );

  /// The first rows, "Alle anzeigen" for the rest, and the own row apart
  /// when it is not among those shown.
  List<Widget> _rows<T>(
    List<T> entries,
    bool Function(T) own,
    Widget Function(T) row,
  ) {
    final shown = _all || entries.length <= RunnerRankingCard.shortList
        ? entries
        : entries.take(RunnerRankingCard.shortList).toList();
    final mine = entries.where(own).firstOrNull;
    // Only when more than the own row lies beyond the first ones.
    final more = entries.any((e) => !shown.contains(e) && !own(e));
    return [
      for (final e in shown) row(e),
      if (mine != null && !shown.contains(mine)) ...[
        const Divider(height: 12),
        row(mine),
      ],
      if (more || _all && entries.length > RunnerRankingCard.shortList)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('ranking-all'),
            onPressed: () => setState(() => _all = !_all),
            child: Text(
              _all ? 'Weniger anzeigen' : 'Alle ${entries.length} anzeigen',
            ),
          ),
        ),
    ];
  }

  /// This month's best runs under "Oktober 2026 · noch 3 Tage". A failed
  /// load never shows here: the screen then offers the all-time list alone.
  List<Widget> _month(BuildContext context) {
    final theme = Theme.of(context);
    final board = widget.monthly;
    if (board == null) return [_loading];
    final headline = monthHeadline(
      board.month,
      board.endsAt,
      widget.now ?? DateTime.now(),
    );
    return [
      if (headline != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            headline,
            key: const ValueKey('ranking-month'),
            style: theme.textTheme.labelLarge,
          ),
        ),
      ..._points(
        context,
        board,
        empty:
            'Diesen Monat hat noch niemand Punkte. Lauf als Erste oder '
            'Erster!',
        absent: 'Du stehst diesen Monat noch nicht auf der Liste.',
      ),
    ];
  }

  List<Widget> _score(BuildContext context) {
    final board = widget.board;
    if (widget.boardNote case final note?) return [Text(note)];
    if (board == null) {
      return [
        if (widget.boardLoading)
          _loading
        else
          _retry(
            widget.boardError ?? 'Die Bestenliste konnte nicht geladen werden.',
            widget.onRetryBoard,
          ),
      ];
    }
    return _points(
      context,
      board,
      empty: 'Noch keine Punkte. Lauf als Erste oder Erster!',
      absent: 'Du stehst noch nicht auf der Liste.',
    );
  }

  /// The rows of a points list: the best, and the own row apart when it is
  /// not among them.
  List<Widget> _points(
    BuildContext context,
    Leaderboard board, {
    required String empty,
    required String absent,
  }) {
    final theme = Theme.of(context);
    if (board.top.isEmpty) return [Text(empty)];
    final own = board.own;
    final entries = [
      ...board.top,
      if (own != null && !board.top.any((e) => e.personId == own.personId)) own,
    ];
    bool mine(LeaderboardEntry e) => e.personId == (own?.personId ?? widget.me);
    return [
      ..._rows<LeaderboardEntry>(
        entries,
        mine,
        (e) => _RankRow(
          rank: e.rank,
          name: e.name,
          own: mine(e),
          trailing: _number.format(e.score),
        ),
      ),
      if (own == null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(absent, style: theme.textTheme.bodySmall),
        ),
    ];
  }

  List<Widget> _collection(BuildContext context) {
    final theme = Theme.of(context);
    final board = widget.collection;
    if (board == null) {
      return [
        if (widget.collectionLoading || widget.collectionError == null)
          _loading
        else
          _retry(widget.collectionError!, widget.onRetryCollection),
      ];
    }
    if (board.entries.isEmpty) {
      return [const Text('Noch hat niemand etwas gesammelt.')];
    }
    final total = board.total;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          total > 0
              ? 'Wer hat die kompletteste Sammlung? $total Stücke gibt es.'
              : 'Wer hat die kompletteste Sammlung?',
          style: theme.textTheme.bodySmall,
        ),
      ),
      ..._rows<CollectionEntry>(
        board.entries,
        (e) => e.me,
        (e) => _RankRow(
          rank: e.rank,
          name: e.name,
          own: e.me,
          trailing: total > 0 ? '${e.owned}/$total' : '${e.owned}',
          shiny: e.shiny,
          fraction: total > 0
              ? (e.owned / total).clamp(0, 1).toDouble()
              : (e.percent / 100).clamp(0, 1).toDouble(),
        ),
      ),
      if (board.own == null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Du stehst noch nicht auf der Liste.',
            style: theme.textTheme.bodySmall,
          ),
        ),
    ];
  }
}

/// One place of a ranking; the own one tinted and bold.
class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.rank,
    required this.name,
    required this.own,
    required this.trailing,
    this.shiny = 0,
    this.fraction,
  });
  final int rank, shiny;
  final String name, trailing;
  final bool own;
  final double? fraction;

  static const _medals = {
    1: Color(0xFFE4AE39),
    2: Color(0xFFA9B1B8),
    3: Color(0xFFB07A45),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = own
        ? theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.primary,
          )
        : theme.textTheme.bodyLarge;
    final medal = _medals[rank];
    return Container(
      key: own ? const ValueKey('ranking-own') : null,
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: own
          ? BoxDecoration(
              color: StageTheme.orange.withValues(alpha: StageTheme.tintAlpha),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: medal == null
                ? Text('$rank.', style: style)
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: medal,
                      child: Text(
                        '$rank',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (fraction != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, right: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 4,
                        color: own ? StageTheme.orange : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (shiny > 0) ...[
            Tooltip(
              message: shiny == 1 ? '1 glänzend' : '$shiny glänzend',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    size: 14,
                    color: Color(0xFFE4AE39),
                  ),
                  Text('$shiny', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text(trailing, style: style),
        ],
      ),
    );
  }
}
