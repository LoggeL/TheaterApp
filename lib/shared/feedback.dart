import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/identity.dart';

/// A readable German message for an error shown to the member.
String userMessage(Object error) => identityError(error);

void showProblem(BuildContext context, Object error) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(userMessage(error))));

Future<void> runAction(
  BuildContext context,
  Future<void> Function() action, {
  String? message,
}) async {
  try {
    await action();
    if (context.mounted && message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }
}

/// Confirms a finished action, optionally with one follow-up action.
void showDone(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) => ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text(message),
    action: actionLabel == null || onAction == null
        ? null
        : SnackBarAction(label: actionLabel, onPressed: onAction),
  ),
);

/// Asks before an action that cannot be undone. Resolves to true only when
/// the member explicitly confirms.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Abbrechen',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

/// Asks before unsaved input is thrown away.
Future<bool> confirmDiscardChanges(BuildContext context) => confirmDestructive(
  context,
  title: 'Änderungen verwerfen?',
  message: 'Deine ungespeicherten Änderungen gehen dabei verloren.',
  confirmLabel: 'Verwerfen',
  cancelLabel: 'Weiter bearbeiten',
);

/// Blocks leaving a page with unsaved input until the member confirms.
class DiscardGuard extends StatelessWidget {
  const DiscardGuard({super.key, required this.dirty, required this.child});
  final bool dirty;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !dirty,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      final navigator = Navigator.of(context);
      if (await confirmDiscardChanges(context)) navigator.pop(result);
    },
    child: child,
  );
}

/// Refreshes and, if that failed, offers a retry in a SnackBar.
Future<void> refreshWithFeedback(
  BuildContext context,
  AppController controller,
) async {
  await controller.refresh();
  final error = controller.error;
  if (!context.mounted || error == null) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(error),
      action: SnackBarAction(
        label: 'Erneut versuchen',
        onPressed: () => refreshWithFeedback(context, controller),
      ),
    ),
  );
}
