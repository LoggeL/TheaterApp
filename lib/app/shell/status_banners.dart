import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../features/sync/ui/sync_screen.dart';
import '../../shared/navigation.dart';

/// Marks the local demo with its sample data.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
    color: Theme.of(context).colorScheme.secondary.withValues(alpha: .12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.science_outlined,
          size: 15,
          color: Theme.of(context).colorScheme.secondary,
        ),
        const SizedBox(width: 6),
        const Flexible(
          child: Text(
            'DEMO · Beispieldaten, lokal auf deinem Gerät',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// Offline or failed changes, linking to the sync page.
class SyncBanner extends StatelessWidget {
  const SyncBanner({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Material(
      // Offline is a normal state; only failed changes alarm.
      color: c.failedCount > 0
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => openPage(context, SyncScreen(controller: c)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            children: [
              Icon(
                c.failedCount > 0 ? Icons.error_outline : Icons.cloud_off,
                size: 17,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  c.failedCount > 0
                      ? '${c.failedCount} Änderung(en) benötigen deine Prüfung'
                      : 'Offline · Du siehst zuletzt gespeicherte Inhalte',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const Icon(Icons.chevron_right, size: 17),
            ],
          ),
        ),
      ),
    );
  }
}

/// App bar action with the sync state and the number of waiting changes.
class SyncStatusButton extends StatelessWidget {
  const SyncStatusButton({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return IconButton(
      tooltip: 'Synchronisierung',
      onPressed: () => openPage(context, SyncScreen(controller: c)),
      icon: Badge(
        isLabelVisible: c.pendingCount + c.failedCount > 0,
        label: Text('${c.pendingCount + c.failedCount}'),
        child: Icon(
          c.isOffline ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
          size: 22,
        ),
      ),
    );
  }
}
