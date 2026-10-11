import 'package:flutter/material.dart';

import '../../../../core/app_controller.dart';
import '../../../../core/models.dart';
import '../../../../shared/feedback.dart';

Future<void> declineEvent(
  BuildContext context,
  AppController controller,
  TheaterEvent event,
) async {
  final reason = TextEditingController(text: event.declineReason);
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        4,
        24,
        MediaQuery.viewInsetsOf(ctx).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dieses Mal ohne dich.',
            style: Theme.of(ctx).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Ein kurzer Grund hilft bei der Probenplanung. Die Angabe ist freiwillig.',
          ),
          const SizedBox(height: 18),
          TextField(
            controller: reason,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Absagegrund (optional)',
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx, reason.text.trim()),
              child: const Text('Absagen'),
            ),
          ),
        ],
      ),
    ),
  );
  if (result != null && context.mounted) {
    await runAction(
      context,
      () => controller.respond(event.id, 'no', reason: result),
    );
  }
  // Let the closing sheet finish using its controller before disposal.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  reason.dispose();
}

/// The result of [pickLateArrival]; [arrival] null means "time still open".
class LateArrival {
  const LateArrival(this.arrival);
  final DateTime? arrival;
}

/// Asks for the expected arrival time. Resolves to null when cancelled or
/// when the event has no start time.
Future<LateArrival?> pickLateArrival(
  BuildContext context,
  TheaterEvent event, {
  DateTime? initial,
}) async {
  final start = event.startsAt;
  if (start == null) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(
      initial ?? start.add(const Duration(minutes: 30)),
    ),
  );
  if (time == null) return null;
  var arrival = DateTime(
    start.year,
    start.month,
    start.day,
    time.hour,
    time.minute,
  );
  if (!arrival.isAfter(start) &&
      event.endsAt != null &&
      dateOnly(event.endsAt!) != dateOnly(start)) {
    arrival = arrival.add(const Duration(days: 1));
  }
  return LateArrival(arrival);
}
