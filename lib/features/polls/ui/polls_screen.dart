import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import 'poll_detail_screen.dart';
import 'poll_editor_screen.dart';
import 'widgets/poll_updates.dart';

class PollsScreen extends StatelessWidget {
  const PollsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => PollUpdates(
    controller: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Abstimmungen'),
        actions: [
          if (controller.user?.isAdmin == true)
            IconButton(
              tooltip: 'Abstimmung erstellen',
              icon: const Icon(Icons.add),
              onPressed: () =>
                  openPage(context, PollEditorScreen(controller: controller)),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          padding: pagePadding(context),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (controller.polls.isEmpty)
              const EmptyState(
                icon: Icons.poll_outlined,
                title: 'Noch keine Abstimmungen',
                message: 'Offene Fragen an euer Ensemble erscheinen hier.',
              ),
            for (final closed in [false, true]) ...[
              if (controller.polls.any((p) => p.isClosed == closed))
                SectionTitle(closed ? 'Abgeschlossen' : 'Offen'),
              for (final p in controller.polls.where(
                (p) => p.isClosed == closed,
              ))
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(20),
                      title: Text(
                        p.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${p.privacyLabel} · ${p.voteCountLabel}${p.selectedOptionId != null ? ' · Du hast abgestimmt' : ''}${p.closesAt == null ? '' : '\nBis ${DateFormat('d. MMMM · HH:mm', 'de').format(p.closesAt!.toLocal())}'}',
                        ),
                      ),
                      leading: Icon(
                        closed
                            ? Icons.check_circle_outline
                            : Icons.poll_outlined,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openPage(
                        context,
                        PollDetailScreen(controller: controller, pollId: p.id),
                      ),
                    ),
                  ),
                ),
            ],
            if (controller.user?.isAdmin == true)
              FilledButton.icon(
                onPressed: () =>
                    openPage(context, PollEditorScreen(controller: controller)),
                icon: const Icon(Icons.add),
                label: const Text('Abstimmung erstellen'),
              ),
          ],
        ),
      ),
    ),
  );
}
