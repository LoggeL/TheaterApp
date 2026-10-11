import 'package:flutter/material.dart';

import '../../../../core/app_controller.dart';
import '../../../../shared/feedback.dart';
import '../../../../shared/navigation.dart';
import '../../../sync/ui/sync_screen.dart';

enum _LogoutChoice { stay, sync, logout }

/// Leaves the local demo after a confirmation. The demo banner and the
/// button in Mein Bereich share it, so both name the action the same way.
Future<void> confirmLeaveDemo(
  BuildContext context,
  AppController controller,
) async {
  final confirmed = await confirmDestructive(
    context,
    title: 'Demo beenden?',
    message:
        'Die Beispieldaten und alles, was du in der Demo geändert hast, '
        'werden von diesem Gerät gelöscht.',
    confirmLabel: 'Demo beenden',
    cancelLabel: 'Hierbleiben',
  );
  // Logging out also switches push off (DeviceServices.disablePush).
  if (confirmed && context.mounted) await runAction(context, controller.logout);
}

/// Signs out after a confirmation that names what gets lost. Push devices are
/// unregistered by the controller's `beforeLogout` hook.
class LogoutButton extends StatelessWidget {
  const LogoutButton({super.key, required this.controller});
  final AppController controller;

  Future<void> _confirm(BuildContext context) async {
    if (controller.isDemo) return confirmLeaveDemo(context, controller);
    final unsent = controller.pendingCount + controller.failedCount;
    final canSync = controller.pendingCount > 0 && !controller.isOffline;
    final choice = await showDialog<_LogoutChoice>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Abmelden?'),
          content: Text(
            unsent > 0
                ? unsent == 1
                      ? 'Eine Änderung ist noch nicht übertragen. Beim Abmelden gehen sie und die auf diesem Gerät gespeicherten Daten verloren.'
                      : '$unsent Änderungen sind noch nicht übertragen. Beim Abmelden gehen sie und die auf diesem Gerät gespeicherten Daten verloren.'
                : 'Die auf diesem Gerät gespeicherten Kontodaten und Drehbücher werden entfernt.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, _LogoutChoice.stay),
              child: const Text('Hierbleiben'),
            ),
            if (canSync)
              TextButton(
                onPressed: () => Navigator.pop(ctx, _LogoutChoice.sync),
                child: const Text('Erst synchronisieren'),
              ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(ctx, _LogoutChoice.logout),
              child: Text(unsent > 0 ? 'Trotzdem abmelden' : 'Abmelden'),
            ),
          ],
        );
      },
    );
    if (!context.mounted) return;
    switch (choice) {
      case _LogoutChoice.logout:
        await runAction(context, controller.logout);
      case _LogoutChoice.sync:
        await controller.retryPending();
        if (!context.mounted) return;
        if (controller.pendingCount + controller.failedCount == 0) {
          showDone(context, 'Alles übertragen. Du kannst dich jetzt abmelden.');
        } else {
          await openPage(context, SyncScreen(controller: controller));
        }
      case _LogoutChoice.stay || null:
        return;
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () => _confirm(context),
    icon: const Icon(Icons.logout),
    label: Text(controller.isDemo ? 'Demo beenden' : 'Abmelden'),
  );
}
