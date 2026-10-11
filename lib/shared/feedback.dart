import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/controller/pending_action.dart';
import '../core/identity.dart';

/// A readable German message for an error shown to the member. A plain
/// [String] is already such a message and is shown unchanged.
String userMessage(Object error) =>
    error is String ? error : identityError(error);

void showProblem(BuildContext context, Object error) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(userMessage(error))));

/// Runs [action] and reports the result in a SnackBar: [message] on success,
/// or [queuedMessage] when the action completed with [ActionOutcome.queued]
/// (the change waits for a connection). Errors show a readable German text.
Future<void> runAction<T>(
  BuildContext context,
  Future<T> Function() action, {
  String? message,
  String? queuedMessage,
}) async {
  try {
    // Commands like `respond` complete with an ActionOutcome.
    final Object? result = await action();
    final text = result is ActionOutcome && queuedMessage != null
        ? outcomeText(
            result,
            done: message ?? queuedMessage,
            queued: queuedMessage,
          )
        : message;
    if (context.mounted && text != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(userMessage(e)),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }
}

/// The confirmation for a change: [done] once the server has it, [queued]
/// while it waits in the outbox for a connection.
String outcomeText(
  ActionOutcome outcome, {
  required String done,
  required String queued,
}) => switch (outcome) {
  ActionOutcome.synced => done,
  ActionOutcome.queued => queued,
};

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

/// Asks the member to confirm [title]. Resolves to true only when the member
/// explicitly confirms. A [destructive] action gets an error-coloured button.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Abbrechen',
  bool scrollable = false,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        scrollable: scrollable,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

/// Asks before an action that cannot be undone. Resolves to true only when
/// the member explicitly confirms.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Abbrechen',
  bool scrollable = false,
}) => confirmAction(
  context,
  title: title,
  message: message,
  confirmLabel: confirmLabel,
  cancelLabel: cancelLabel,
  scrollable: scrollable,
  destructive: true,
);

/// Asks before unsaved input is thrown away.
Future<bool> confirmDiscardChanges(BuildContext context) => confirmDestructive(
  context,
  title: 'Änderungen verwerfen?',
  message: 'Deine ungespeicherten Änderungen gehen dabei verloren.',
  confirmLabel: 'Verwerfen',
  cancelLabel: 'Weiter bearbeiten',
);

/// The mounted guards that currently hold unsaved input.
final _dirtyGuards = <_DiscardGuardState>{};

/// Whether a page above the first route of [navigator] holds unsaved input.
bool hasUnsavedChanges(NavigatorState navigator) => _dirtyGuards.any((guard) {
  final route = guard.route;
  return route != null &&
      route.navigator == navigator &&
      route.isActive &&
      !route.isFirst;
});

/// Goes back to the first route of [navigator]. Pages with unsaved input ask
/// first; resolves to false (and stays put) when the member keeps editing.
///
/// [Navigator.popUntil] ignores [PopScope.canPop], so every jump to a
/// section start goes through here instead.
Future<bool> popToFirst(BuildContext context, NavigatorState navigator) async {
  if (hasUnsavedChanges(navigator) && !await confirmDiscardChanges(context)) {
    return false;
  }
  if (!navigator.mounted) return false;
  navigator.popUntil((route) => route.isFirst);
  return true;
}

/// Blocks leaving a page with unsaved input until the member confirms.
class DiscardGuard extends StatefulWidget {
  const DiscardGuard({super.key, required this.dirty, required this.child});
  final bool dirty;
  final Widget child;

  @override
  State<DiscardGuard> createState() => _DiscardGuardState();
}

class _DiscardGuardState extends State<DiscardGuard> {
  ModalRoute<Object?>? route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _dirtyGuards.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dirty) {
      _dirtyGuards.add(this);
    } else {
      _dirtyGuards.remove(this);
    }
    return PopScope<Object?>(
      canPop: !widget.dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await confirmDiscardChanges(context)) navigator.pop(result);
      },
      child: widget.child,
    );
  }
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
