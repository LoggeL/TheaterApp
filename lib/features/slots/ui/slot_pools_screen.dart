import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../admin/slot_pool_editor_screen.dart';
import '../domain/slot_pool.dart';
import 'slot_format.dart';
import 'slot_pool_screen.dart';

void openSlotPool(BuildContext context, AppController controller, String id) =>
    openPage(context, SlotPoolScreen(controller: controller, poolId: id));

class SlotPoolsScreen extends StatelessWidget {
  const SlotPoolsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final manager = controller.user?.canManageEvents == true;
      final now = controller.now;
      final pools = slotPoolsOf(controller);
      bool done(SlotPool p) => p.closed || p.finishedAt(now);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Terminfinder'),
          actions: [
            if (manager && !controller.isDemo)
              IconButton(
                tooltip: 'Terminfinder anlegen',
                icon: const Icon(Icons.add),
                onPressed: () => openPage(
                  context,
                  SlotPoolEditorScreen(controller: controller),
                ),
              ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            padding: pagePadding(context),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (pools.isEmpty)
                EmptyState(
                  icon: Icons.edit_calendar_outlined,
                  title: 'Noch kein Terminfinder',
                  message: manager
                      ? 'Lege Zeitfenster an, z. B. für Fototermine, und lass das Ensemble selbst buchen.'
                      : 'Wenn du Zeitfenster buchen kannst, z. B. für Fototermine, erscheinen sie hier.',
                ),
              for (final finished in [false, true]) ...[
                if (pools.any((p) => done(p) == finished))
                  SectionTitle(finished ? 'Abgeschlossen' : 'Aktuell'),
                for (final p in pools.where((p) => done(p) == finished))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _PoolCard(controller: controller, pool: p),
                  ),
              ],
              if (manager && !controller.isDemo) ...[
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () => openPage(
                    context,
                    SlotPoolEditorScreen(controller: controller),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Terminfinder anlegen'),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _PoolCard extends StatelessWidget {
  const _PoolCard({required this.controller, required this.pool});
  final AppController controller;
  final SlotPool pool;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = controller.now;
    final invited = invitedToSlotPool(controller, pool);
    final mine = pool.mySlot;
    final booked = pool.slots.fold<int>(0, (n, s) => n + s.booked);
    final capacity = pool.slots.fold<int>(0, (n, s) => n + s.capacity);
    final pills = <Widget>[
      if (mine != null)
        StatePill(
          'Dein Slot: ${slotLabel(mine)}',
          icon: Icons.check_circle_outline,
        )
      else if (invited && !pool.closed && pool.hasFreeSlotAt(now))
        const StatePill(
          'Noch kein Slot gewählt',
          color: StageTheme.orange,
          icon: Icons.touch_app_outlined,
        ),
      if (pool.closed)
        StatePill(
          'Geschlossen',
          color: theme.colorScheme.onSurfaceVariant,
          icon: Icons.lock_outline,
        ),
    ];
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => openSlotPool(context, controller, pool.id),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(
                Icons.edit_calendar_outlined,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pool.title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      [
                        slotPoolRange(pool),
                        if (pool.place.isNotEmpty) pool.place,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (controller.user?.canManageEvents == true) ...[
                      const SizedBox(height: 4),
                      Text(
                        '$booked von $capacity Plätzen gebucht',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (pills.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(spacing: 8, runSpacing: 6, children: pills),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
