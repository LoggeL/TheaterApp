import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../features/me/ui/widgets/logout_button.dart';
import '../../features/sync/ui/sync_screen.dart';
import '../../shared/navigation.dart';

/// Marks the local demo with its sample data and offers to leave it.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 2, 8, 2),
      color: scheme.secondary.withValues(alpha: .12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.science_outlined, size: 16, color: scheme.secondary),
          const SizedBox(width: 6),
          const Flexible(
            child: Text(
              'DEMO · Beispieldaten, lokal auf deinem Gerät',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: () => confirmLeaveDemo(context, controller),
            child: const Text('Demo beenden'),
          ),
        ],
      ),
    );
  }
}

/// Offline or failed changes, linking to the sync page.
class SyncBanner extends StatelessWidget {
  const SyncBanner({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final failed = c.failedCount;
    return Material(
      // Offline is a normal state; only failed changes alarm.
      color: failed > 0
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => openPage(context, SyncScreen(controller: c)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            children: [
              Icon(
                failed > 0 ? Icons.error_outline : Icons.cloud_off,
                size: 17,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  failed == 1
                      ? '1 Änderung braucht deine Prüfung'
                      : failed > 1
                      ? '$failed Änderungen brauchen deine Prüfung'
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

/// The sync state for screen readers and the tooltip, e.g.
/// 'Offline · 2 Änderungen warten'.
String syncStatusLabel(AppController controller) {
  final waiting = controller.pendingCount + controller.failedCount;
  return [
    if (controller.isOffline) 'Offline',
    if (waiting == 1) '1 Änderung wartet',
    if (waiting > 1) '$waiting Änderungen warten',
    if (!controller.isOffline && waiting == 0) 'Alles synchronisiert',
  ].join(' · ');
}

/// App bar action with the sync state and the number of waiting changes. The
/// shell shows it only while offline or while changes wait.
class SyncStatusButton extends StatelessWidget {
  const SyncStatusButton({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final waiting = c.pendingCount + c.failedCount;
    return IconButton(
      tooltip: syncStatusLabel(c),
      onPressed: () => openPage(context, SyncScreen(controller: c)),
      icon: ExcludeSemantics(
        child: Badge(
          isLabelVisible: waiting > 0,
          label: Text('$waiting'),
          child: Icon(
            c.isOffline
                ? Icons.cloud_off_outlined
                : Icons.cloud_upload_outlined,
            size: 22,
          ),
        ),
      ),
    );
  }
}
