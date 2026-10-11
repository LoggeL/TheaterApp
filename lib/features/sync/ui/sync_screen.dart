import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/controller/pending_action.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';

/// What is still waiting after a manual sync, or null when nothing is left.
String? remainingChanges(int pending, int failed) {
  if (pending + failed == 0) return null;
  final parts = [
    if (pending > 0)
      pending == 1
          ? '1 Änderung wartet noch'
          : '$pending Änderungen warten noch',
    if (failed > 0)
      failed == 1
          ? '1 Änderung braucht deine Prüfung'
          : '$failed Änderungen brauchen deine Prüfung',
  ];
  return parts.join(' · ');
}

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key, required this.controller});
  final AppController controller;

  Future<void> _sync(BuildContext context) async {
    await controller.retryPending();
    if (!context.mounted || controller.error != null) return;
    // The fresh result replaces an older note instead of queueing behind it.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    showDone(
      context,
      remainingChanges(controller.pendingCount, controller.failedCount) ??
          'Alles übertragen',
    );
  }

  Future<void> _discard(BuildContext context, PendingAction entry) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Änderung verwerfen?',
      message:
          '„${entry.label}“ wird nicht mehr übertragen und auf diesem Gerät gelöscht.',
      confirmLabel: 'Verwerfen',
    );
    if (!confirmed || !context.mounted) return;
    await runAction(
      context,
      () => controller.discardAction(entry.id),
      message: 'Änderung verworfen.',
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(title: const Text('Synchronisierung')),
        body: ListView(
          padding: pagePadding(context),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: controller.isDemo
                  ? StatePill(
                      'Lokale Demo',
                      color: theme.colorScheme.outline,
                      icon: Icons.phone_android_outlined,
                    )
                  : StatePill(
                      controller.isOffline ? 'Offline' : 'Server verbunden',
                      color: controller.isOffline
                          ? StageTheme.orange
                          : StageTheme.green,
                      icon: controller.isOffline
                          ? Icons.cloud_off
                          : Icons.cloud_done_outlined,
                    ),
            ),
            const SizedBox(height: 18),
            Text(
              controller.isDemo
                  ? 'In der Demo bleibt alles auf diesem Gerät. Es gibt nichts zu übertragen.'
                  : controller.lastSync == null
                  ? 'Noch keine Server-Synchronisierung.'
                  : 'Zuletzt aktualisiert: ${DateFormat('dd.MM.yyyy · HH:mm').format(controller.lastSync!.toLocal())}',
              style: theme.textTheme.bodyMedium,
            ),
            if (!controller.isDemo) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: controller.busy ? null : () => _sync(context),
                icon: const Icon(Icons.sync),
                label: const Text('Jetzt synchronisieren'),
              ),
            ],
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Text(
                  controller.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SectionTitle('Ausstehende Änderungen'),
            if (controller.outbox.isEmpty)
              const EmptyState(
                icon: Icons.done_all,
                title: 'Alles auf dem aktuellen Stand.',
                message: 'Es warten keine lokalen Änderungen auf Übertragung.',
              ),
            ...controller.outbox.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    leading: Icon(
                      entry.failed
                          ? Icons.error_outline
                          : Icons.schedule_send_outlined,
                      color: entry.failed
                          ? theme.colorScheme.error
                          : StageTheme.orange,
                    ),
                    title: Text(entry.label),
                    subtitle: Text(
                      entry.lastError ??
                          'Wartet auf Übertragung · ${DateFormat.Hm().format(entry.createdAt)}',
                    ),
                    isThreeLine: entry.lastError != null,
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Änderung bearbeiten',
                      itemBuilder: (_) => [
                        // Retrying cannot help after e.g. a passed deadline.
                        if (entry.failed && entry.retryable)
                          const PopupMenuItem(
                            value: 'retry',
                            child: Text('Erneut versuchen'),
                          ),
                        const PopupMenuItem(
                          value: 'discard',
                          child: Text('Änderung verwerfen'),
                        ),
                      ],
                      onSelected: (choice) => choice == 'retry'
                          ? runAction(
                              context,
                              () => controller.retryFailed(entry.id),
                            )
                          : _discard(context, entry),
                    ),
                  ),
                ),
              ),
            ),
            const SectionTitle('Offline'),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Geöffnete Drehbücher und zuletzt geladene Termine bleiben auf diesem Gerät verfügbar. Rückmeldungen werden zwischengespeichert und bei der nächsten Synchronisierung übertragen. Beim Abmelden werden diese Kontodaten entfernt.',
                ),
              ),
            ),
            if (!controller.isDemo) ...[
              const SizedBox(height: 12),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: const Text('Technische Details'),
                  childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Server', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    SelectableText(
                      controller.apiBaseUrl,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
