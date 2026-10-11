import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Synchronisierung')),
      body: ListView(
        padding: pagePadding(context),
        children: [
          StatePill(
            controller.isDemo
                ? 'Lokale Demo'
                : controller.isOffline
                ? 'Offline'
                : 'Server verbunden',
            color: controller.isOffline ? StageTheme.orange : StageTheme.green,
            icon: controller.isOffline
                ? Icons.cloud_off
                : Icons.cloud_done_outlined,
          ),
          const SizedBox(height: 18),
          Text(
            controller.lastSync == null
                ? 'Noch keine Server-Synchronisierung.'
                : 'Zuletzt aktualisiert: ${DateFormat('dd.MM.yyyy · HH:mm').format(controller.lastSync!.toLocal())}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          if (!controller.isDemo)
            SelectableText(
              controller.apiBaseUrl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: controller.busy
                ? null
                : () => runAction(context, controller.retryPending),
            icon: const Icon(Icons.sync),
            label: const Text('Jetzt synchronisieren'),
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                        ? Theme.of(context).colorScheme.error
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
                      if (entry.failed)
                        const PopupMenuItem(
                          value: 'retry',
                          child: Text('Erneut versuchen'),
                        ),
                      const PopupMenuItem(
                        value: 'discard',
                        child: Text('Änderung verwerfen'),
                      ),
                    ],
                    onSelected: (choice) => runAction(
                      context,
                      () => choice == 'retry'
                          ? controller.retryFailed(entry.id)
                          : controller.discardAction(entry.id),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
