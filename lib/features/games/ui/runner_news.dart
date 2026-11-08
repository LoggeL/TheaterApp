import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/widgets/page_header.dart';
import '../data/weekly_api.dart' show weeklyAvailable;

/// "Neu im Bühnenlauf": what is new in the game, told once per entry when
/// the menu opens. The entries live in the app (oldest first, see
/// [runnerNews]); which ones were shown is kept on the device
/// (`RunnerMenuPreferences.newsSeen`). Only the newest entry not seen yet
/// shows, and with it all older ones count as seen: whoever comes back after
/// a long time reads one, not a pile.

/// Where an entry's button leads.
enum RunnerNewsAction {
  /// The Wochenprobe's page.
  weekly,
}

/// One entry of "Neu im Bühnenlauf".
class RunnerNews {
  const RunnerNews({
    required this.id,
    required this.title,
    required this.points,
    this.icon = Icons.campaign_outlined,
    this.action,
    this.actionLabel,
    this.offered,
  });

  /// Never changes once released: the device remembers it as seen.
  final String id;
  final String title;

  /// Short lines, one per point.
  final List<String> points;
  final IconData icon;

  /// The button besides "Später"; none without it.
  final RunnerNewsAction? action;
  final String? actionLabel;

  /// Whether this app and server have what the entry tells of; without it
  /// the entry waits (and is not marked as seen). Null: always.
  final bool Function(AppController controller)? offered;
}

/// The entries, oldest first. Add new ones at the end with a fresh id.
const runnerNews = <RunnerNews>[
  RunnerNews(
    id: 'wochenprobe-2026-11',
    title: 'Neu: Die Wochenprobe',
    icon: Icons.event_repeat,
    points: [
      'Jede Woche eine feste Strecke für alle, von Montag bis Sonntag.',
      'Drei Wertungsläufe, der beste zählt. Ein Versuch zählt, sobald der '
          'Lauf startet.',
      'Training auf der Wochenstrecke, so oft du willst.',
      'Die Geister aller laufen mit, die besten drei mit Namen.',
      'Belohnung: eine Wochenkiste fürs Mitmachen, Pokal und Gage für die '
          'Plätze 1 bis 3.',
    ],
    action: RunnerNewsAction.weekly,
    actionLabel: 'Zur Wochenprobe',
    offered: _weeklyRewardsOffered,
  ),
];

/// The Wochenprobe with its rewards (`runnerWeeklyRewards`): the entry
/// names the Wochenkiste and the Pokale, so it waits for a server that
/// gives them.
bool _weeklyRewardsOffered(AppController controller) =>
    weeklyAvailable(controller) && controller.supports('runnerWeeklyRewards');

/// The entry to show: the newest of [entries] that is [offered] and not in
/// [seen], with the ids to mark as seen along with it (it and every older
/// one). Null when there is none.
({RunnerNews news, List<String> seen})? pendingRunnerNews(
  List<RunnerNews> entries,
  Set<String> seen,
  bool Function(RunnerNews news) offered,
) {
  for (var i = entries.length - 1; i >= 0; i--) {
    final news = entries[i];
    if (seen.contains(news.id)) return null;
    if (!offered(news)) continue;
    return (news: news, seen: [for (final e in entries.take(i + 1)) e.id]);
  }
  return null;
}

/// Shows [news]; gives its action if its button was chosen, else null.
Future<RunnerNewsAction?> showRunnerNews(
  BuildContext context,
  RunnerNews news,
) => showDialog<RunnerNewsAction>(
  context: context,
  builder: (context) => RunnerNewsDialog(news: news),
);

/// The dialog of one entry: its icon, "Neu im Bühnenlauf", the title, the
/// points and the buttons. It scrolls where the screen is low, e.g. on a
/// phone held sideways.
class RunnerNewsDialog extends StatelessWidget {
  const RunnerNewsDialog({super.key, required this.news});
  final RunnerNews news;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final low = MediaQuery.sizeOf(context).height < 480;
    return AlertDialog(
      key: const ValueKey('runner-news'),
      scrollable: true,
      semanticLabel: 'Neu im Bühnenlauf: ${news.title}',
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      // Sideways the icon would take the room of the text.
      icon: low ? null : Icon(news.icon, color: StageTheme.orange, size: 36),
      title: Column(
        children: [
          // Read as words, not in capitals letter by letter.
          Semantics(
            label: 'Neu im Bühnenlauf',
            excludeSemantics: true,
            child: const Eyebrow('Neu im Bühnenlauf', color: StageTheme.orange),
          ),
          const SizedBox(height: 6),
          Semantics(
            header: true,
            child: Text(news.title, textAlign: TextAlign.center),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, point) in news.points.indexed)
              Padding(
                key: ValueKey('runner-news-point-$i'),
                padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: ExcludeSemantics(
                        child: Icon(
                          Icons.star_rounded,
                          size: 18,
                          color: StageTheme.orange,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(point, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('runner-news-later'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Später'),
        ),
        if (news.action case final action?)
          FilledButton(
            key: const ValueKey('runner-news-action'),
            style: FilledButton.styleFrom(
              backgroundColor: StageTheme.orange,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, action),
            child: Text(news.actionLabel ?? 'Ansehen'),
          ),
      ],
    );
  }
}
