import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../domain/poll_selectors.dart';
import 'poll_detail_screen.dart';
import 'poll_editor_screen.dart';
import 'widgets/poll_updates.dart';

class PollsScreen extends StatelessWidget {
  const PollsScreen({
    super.key,
    required this.controller,
    this.embedded = false,
    this.switcher,
    this.floatingActionButton,
  });
  final AppController controller;

  /// Shown as the Abstimmungen segment of the Mitteilungen tab: no app bar,
  /// the tab's header and [switcher] on top.
  final bool embedded;

  /// Shown below the header, e.g. to switch back to the messages.
  final Widget? switcher;

  /// Replaces the own create button, e.g. by the shared one of the tab.
  final Widget? floatingActionButton;

  /// Open polls the member still has to answer first, then by deadline.
  static int _byUrgency(AppController c, Poll a, Poll b) {
    bool waiting(Poll p) =>
        p.selectedOptionId == null && pollAddressesUser(c, p);
    if (waiting(a) != waiting(b)) return waiting(a) ? -1 : 1;
    final x = a.closesAt, y = b.closesAt;
    if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
    return x.compareTo(y);
  }

  @override
  Widget build(BuildContext context) => PollUpdates(
    controller: controller,
    builder: (context, _) {
      final c = controller, admin = c.user?.isAdmin == true;
      final open = c.polls.where((p) => !p.isClosedAt(c.now)).toList()
        ..sort((a, b) => _byUrgency(c, a, b));
      final closed = c.polls.where((p) => p.isClosedAt(c.now)).toList();
      final waiting = pollsToVote(c).length;
      Widget list(EdgeInsets padding) => ListView(
        padding: padding,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (embedded)
            PageHeader(
              'Mitteilungen.',
              subtitle: waiting == 0
                  ? 'Fragen an das Ensemble'
                  : waiting == 1
                  ? '1 offene Abstimmung für dich'
                  : '$waiting offene Abstimmungen für dich',
            ),
          if (switcher != null) ...[switcher!, const SizedBox(height: 14)],
          if (c.polls.isEmpty)
            const EmptyState(
              icon: Icons.poll_outlined,
              title: 'Noch keine Abstimmungen',
              message: 'Offene Fragen an euer Ensemble erscheinen hier.',
            ),
          for (final (title, polls) in [
            ('Offen', open),
            ('Abgeschlossen', closed),
          ])
            if (polls.isNotEmpty) ...[
              SectionTitle(title),
              for (final p in polls)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _PollCard(controller: c, poll: p),
                ),
            ],
        ],
      );

      return Scaffold(
        appBar: embedded ? null : AppBar(title: const Text('Abstimmungen')),
        floatingActionButton:
            floatingActionButton ??
            (admin
                ? FloatingActionButton.extended(
                    tooltip: 'Abstimmung erstellen',
                    onPressed: () =>
                        openPage(context, PollEditorScreen(controller: c)),
                    icon: const Icon(Icons.add),
                    label: const Text('Neue Abstimmung'),
                  )
                : null),
        body: RefreshIndicator(
          onRefresh: () => refreshWithFeedback(context, c),
          child: embedded
              // Same width and spacing as the messages segment.
              ? Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: list(const EdgeInsets.fromLTRB(20, 20, 20, 96)),
                  ),
                )
              : list(pagePadding(context, bottom: 96)),
        ),
      );
    },
  );
}

class _PollCard extends StatelessWidget {
  const _PollCard({required this.controller, required this.poll});
  final AppController controller;
  final Poll poll;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), p = poll;
    final closed = p.isClosedAt(controller.now);
    final addressed = pollAddressesUser(controller, p);
    final pill = p.selectedOptionId != null
        ? const StatePill(
            'Abgestimmt',
            icon: Icons.check,
            color: StageTheme.green,
          )
        : !addressed
        ? StatePill('Nicht an dich', color: theme.colorScheme.outline)
        : !closed
        ? const StatePill(
            'Noch nicht abgestimmt',
            icon: Icons.how_to_vote_outlined,
            color: StageTheme.orange,
          )
        : null;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(20),
        title: Text(p.title, style: theme.textTheme.titleMedium),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${p.privacyLabel} · ${p.voteCountLabel}${p.closesAt == null ? '' : '\nBis ${DateFormat('d. MMMM · HH:mm', 'de').format(p.closesAt!.toLocal())}'}',
              ),
              if (pill != null) ...[const SizedBox(height: 10), pill],
            ],
          ),
        ),
        leading: Icon(
          closed ? Icons.check_circle_outline : Icons.poll_outlined,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(
          context,
          PollDetailScreen(controller: controller, pollId: p.id),
        ),
      ),
    );
  }
}
