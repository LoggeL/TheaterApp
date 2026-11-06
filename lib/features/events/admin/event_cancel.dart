import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';

/// Longest reason for a cancellation; matches `cancelReasonMaxLength` on the
/// server.
const cancelReasonMaxLength = 300;

/// Whether [event] can be called off here: by those managing events, on
/// servers with `eventCancel`, for a not yet ended event outside the
/// Terminfinder.
bool canCancelEvent(AppController controller, TheaterEvent event) =>
    _manages(controller, event) && !event.cancelled;

/// Whether the cancellation of [event] can be withdrawn here.
bool canUncancelEvent(AppController controller, TheaterEvent event) =>
    _manages(controller, event) && event.cancelled;

bool _manages(AppController controller, TheaterEvent event) =>
    controller.user?.canManageEvents == true &&
    controller.supports('eventCancel') &&
    !event.fromSlotPool &&
    (event.endsAt ?? event.startsAt)?.isAfter(controller.now) != false;

/// Who hears of a cancellation of [event] by push (as the server decides).
String cancelPushNotice(AppController controller, TheaterEvent event) {
  if (!controller.pushConfigured) {
    return 'Push ist nicht eingerichtet, es geht keine Benachrichtigung raus.';
  }
  return event.autoAccept
      ? 'Alle Eingeladenen, die nicht abgesagt haben, erfahren per Push von '
            'der Absage.'
      : 'Wer zugesagt hat, erfährt per Push von der Absage.';
}

/// Asks for the optional reason and calls [event] off; true once done or
/// queued. The event stays visible as cancelled.
Future<bool> cancelEvent(
  BuildContext context,
  AppController controller,
  TheaterEvent event,
) async {
  final reason = await showDialog<String>(
    context: context,
    builder: (context) =>
        _CancelDialog(notice: cancelPushNotice(controller, event)),
  );
  if (reason == null || !context.mounted) return false;
  try {
    final result = await controller.performActionWithResult({
      'action': 'event.cancel',
      'id': event.id,
      'version': event.version,
      'reason': reason,
    });
    if (!context.mounted) return true;
    final data = result.data;
    final recipients = data?['recipients'];
    final done = switch (data?['pushSkipped']) {
      'disabled' =>
        'Termin abgesagt – kein Push, der Versand ist nicht '
            'eingerichtet.',
      'no_recipients' =>
        'Termin abgesagt – niemand hatte zugesagt, daher '
            'kein Push.',
      _ when data?['pushQueued'] == true && recipients is num =>
        'Termin abgesagt, ${recipients == 1 ? 'eine Person wird' : '${recipients.toInt()} Personen werden'} '
            'benachrichtigt.',
      _ => 'Termin abgesagt',
    };
    showDone(
      context,
      outcomeText(
        result.outcome,
        done: done,
        queued: 'Absage vorgemerkt – wird bei Verbindung übertragen.',
      ),
    );
    return true;
  } catch (e) {
    if (context.mounted) showProblem(context, e);
    return false;
  }
}

/// Withdraws the cancellation of [event] after asking; nobody is notified.
Future<bool> uncancelEvent(
  BuildContext context,
  AppController controller,
  TheaterEvent event,
) async {
  final confirmed = await confirmAction(
    context,
    title: 'Absage zurücknehmen?',
    message:
        'Der Termin findet wieder statt und Rückmeldungen sind wieder '
        'möglich. Es geht keine Benachrichtigung raus.',
    confirmLabel: 'Zurücknehmen',
  );
  if (!confirmed || !context.mounted) return false;
  try {
    final outcome = await controller.performAction({
      'action': 'event.uncancel',
      'id': event.id,
      'version': event.version,
    });
    if (context.mounted) {
      showDone(
        context,
        outcomeText(
          outcome,
          done: 'Absage zurückgenommen',
          queued: 'Zurücknahme vorgemerkt – wird bei Verbindung übertragen.',
        ),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) showProblem(context, e);
    return false;
  }
}

/// The confirmation with the optional reason; pops the trimmed reason, or
/// null when not confirmed.
class _CancelDialog extends StatefulWidget {
  const _CancelDialog({required this.notice});
  final String notice;
  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      scrollable: true,
      title: const Text('Termin absagen?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Der Termin bleibt als „Abgesagt“ sichtbar. Rückmeldungen und '
            'Erinnerungen entfallen.',
          ),
          const SizedBox(height: 8),
          Text(widget.notice, key: const ValueKey('event-cancel-notice')),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('event-cancel-reason'),
            controller: _reason,
            maxLength: cancelReasonMaxLength,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Grund (optional)',
              hintText: 'z. B. Saal belegt',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          key: const ValueKey('event-cancel-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(
            context,
            _reason.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
          ),
          child: const Text('Termin absagen'),
        ),
      ],
    );
  }
}
