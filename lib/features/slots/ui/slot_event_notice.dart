import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import 'slot_pools_screen.dart';

/// Shown on events created from a booked slot instead of the response choice.
class SlotEventNotice extends StatelessWidget {
  const SlotEventNotice({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final booked = event.response == 'yes';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.edit_calendar_outlined,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Über den Terminfinder gebucht',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            booked
                ? 'Du bist für dieses Zeitfenster eingetragen. Umbuchen oder '
                      'freigeben kannst du im Terminfinder.'
                : 'Dieser Termin gilt nur für die gebuchten Personen. '
                      'Änderungen laufen über den Terminfinder.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () =>
                openSlotPool(context, controller, event.slotPoolId!),
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Terminfinder öffnen'),
          ),
        ],
      ),
    );
  }
}
