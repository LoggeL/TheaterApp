import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../events/ui/event_style.dart';
import '../admin/slot_pool_editor_screen.dart';
import '../domain/slot_pool.dart';
import 'slot_format.dart';

class SlotPoolScreen extends StatefulWidget {
  const SlotPoolScreen({
    super.key,
    required this.controller,
    required this.poolId,
  });
  final AppController controller;
  final String poolId;
  @override
  State<SlotPoolScreen> createState() => _SlotPoolScreenState();
}

class _SlotPoolScreenState extends State<SlotPoolScreen> {
  bool _busy = false;
  AppController get _controller => widget.controller;

  Future<bool> _run(JsonMap action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await _controller.performAction(action);
      if (mounted && done != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(done)));
      }
      return true;
    } catch (e) {
      if (mounted) showProblem(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(
    String title,
    String message,
    String confirm, {
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(ctx).colorScheme.error,
                      foregroundColor: Theme.of(ctx).colorScheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirm),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _book(SlotPool pool, TimeSlot slot) => _run({
    'action': 'slot.book',
    'poolId': pool.id,
    'slotId': slot.id,
  }, done: 'Gebucht: ${slotLabel(slot)}');

  Future<void> _cancel(SlotPool pool, TimeSlot slot) async {
    if (!await _confirm(
      'Zeitfenster freigeben?',
      'Dein Zeitfenster ${slotLabel(slot)} wird für andere frei. '
          'Der Termin verschwindet aus deinem Kalender.',
      'Freigeben',
    )) {
      return;
    }
    await _run({
      'action': 'slot.cancel',
      'poolId': pool.id,
    }, done: 'Zeitfenster freigegeben.');
  }

  Future<void> _assign(SlotPool pool, TimeSlot slot) async {
    final personId = await _pickPerson(pool, slot);
    if (personId == null || !mounted) return;
    await _run({
      'action': 'slot.assign',
      'poolId': pool.id,
      'personId': personId,
      'slotId': slot.id,
    });
  }

  Future<void> _remove(
    SlotPool pool,
    TimeSlot slot,
    ({int personId, String name}) person,
  ) async {
    if (!await _confirm(
      '${person.name} entfernen?',
      '${person.name} wird aus dem Zeitfenster ${slotLabel(slot)} entfernt '
          'und kann danach selbst neu buchen.',
      'Entfernen',
    )) {
      return;
    }
    await _run({
      'action': 'slot.assign',
      'poolId': pool.id,
      'personId': person.personId,
      'slotId': null,
    });
  }

  Future<void> _menu(SlotPool pool, String choice) async {
    switch (choice) {
      case 'edit':
        openPage(
          context,
          SlotPoolEditorScreen(
            controller: _controller,
            pool: _controller.slotPools
                .where((p) => p['id'] == pool.id)
                .firstOrNull,
          ),
        );
      case 'close':
        await _run(
          {
            'action': 'slotPool.close',
            'id': pool.id,
            'version': pool.version,
            'closed': !pool.closed,
          },
          done: pool.closed
              ? 'Buchung wieder geöffnet.'
              : 'Buchung geschlossen.',
        );
      case 'delete':
        if (!await _confirm(
          'Terminfinder löschen?',
          'Der Terminfinder, alle Buchungen und die daraus erzeugten Termine '
              'werden für alle entfernt.',
          'Löschen',
          destructive: true,
        )) {
          return;
        }
        final ok = await _run({
          'action': 'slotPool.delete',
          'id': pool.id,
          'version': pool.version,
        });
        if (ok && mounted) Navigator.pop(context);
    }
  }

  Future<int?> _pickPerson(SlotPool pool, TimeSlot slot) {
    var query = '';
    final bookedIn = {
      for (final s in pool.slots)
        for (final p in s.people) p.personId: s,
    };
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final people = _controller.members
              .where(
                (m) =>
                    m.active &&
                    bookedIn[m.id]?.id != slot.id &&
                    '${m.name} ${widget.controller.roleNames(m.roleIds)}'
                        .toLowerCase()
                        .contains(query.toLowerCase()),
              )
              .toList();
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .7,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      'Person für ${slotLabel(slot)}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Person suchen',
                      ),
                      onChanged: (v) => setSheetState(() => query = v),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        if (people.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('Keine passende Person gefunden.'),
                          ),
                        for (final m in people)
                          ListTile(
                            leading: const Icon(Icons.person_outline),
                            title: Text(m.name),
                            subtitle: Text(
                              [
                                if (m.roleIds.isNotEmpty)
                                  widget.controller.roleNames(m.roleIds),
                                if (bookedIn[m.id] != null)
                                  'Wird umgebucht von ${slotTime(bookedIn[m.id]!)}'
                                else if (!m.inAudience(
                                  pool.roleIds,
                                  pool.personIds,
                                  widget.controller.ensemblesOf(
                                    pool.productionIds,
                                  ),
                                ))
                                  'Nicht eingeladen',
                              ].join(' · '),
                            ),
                            onTap: () => Navigator.pop(context, m.id),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final json = _controller.slotPools
          .where((p) => p['id'] == widget.poolId)
          .firstOrNull;
      final admin = _controller.user?.isAdmin == true;
      if (json == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Terminfinder')),
          body: const EmptyState(
            icon: Icons.edit_calendar_outlined,
            title: 'Terminfinder nicht verfügbar',
            message:
                'Der Terminfinder wurde entfernt oder ist für dein Konto nicht freigegeben.',
          ),
        );
      }
      final pool = SlotPool.fromJson(json);
      final now = _controller.now;
      final invited = invitedToSlotPool(_controller, pool);
      final mine = pool.mySlot;
      final mineLocked = mine != null && mine.startedAt(now);
      final days = <DateTime, List<TimeSlot>>{};
      for (final slot in pool.slots) {
        days.putIfAbsent(DateUtils.dateOnly(slot.startsAt), () => []).add(slot);
      }
      final pending = _controller.outbox.any(
        (a) =>
            !a.failed &&
            textValue(a.payload['action']).startsWith('slot.') &&
            a.payload['poolId'] == pool.id,
      );
      return Scaffold(
        appBar: AppBar(
          title: const Text('Terminfinder'),
          actions: [
            if (admin && !_controller.isDemo)
              PopupMenuButton<String>(
                tooltip: 'Terminfinder verwalten',
                enabled: !_busy,
                onSelected: (choice) => _menu(pool, choice),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Bearbeiten'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'close',
                    child: ListTile(
                      leading: Icon(
                        pool.closed
                            ? Icons.lock_open_outlined
                            : Icons.lock_outline,
                      ),
                      title: Text(
                        pool.closed
                            ? 'Buchung wieder öffnen'
                            : 'Buchung schließen',
                      ),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Löschen'),
                    ),
                  ),
                ],
              ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _controller.refresh,
          child: ListView(
            padding: pagePadding(context, top: 16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Text(
                pool.title,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  EventKindPill(pool.kind),
                  if (pool.closed)
                    StatePill(
                      'Geschlossen',
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      icon: Icons.lock_outline,
                    ),
                ],
              ),
              if (pool.description.isNotEmpty) ...[
                const SizedBox(height: 16),
                SelectableText(pool.description),
              ],
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(19),
                  child: Column(
                    children: [
                      _Meta(Icons.calendar_today_outlined, slotPoolRange(pool)),
                      const SizedBox(height: 14),
                      _Meta(
                        Icons.location_on_outlined,
                        pool.place.isEmpty
                            ? 'Ort wird noch bekannt gegeben'
                            : pool.place,
                      ),
                      const SizedBox(height: 14),
                      _Meta(
                        Icons.group_outlined,
                        'Eingeladen: ${_controller.audienceLabel(pool.roleIds, pool.personIds, pool.productionIds)}',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _status(context, pool, invited, admin, now),
              if (pending)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    'Deine Auswahl wird übertragen, sobald eine Verbindung besteht.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
              if (admin) _missing(context, pool),
              if (pool.slots.isEmpty)
                const EmptyState(
                  icon: Icons.schedule,
                  title: 'Keine Zeitfenster',
                  message: 'Für diesen Terminfinder gibt es keine Zeitfenster.',
                ),
              for (final day in days.entries) ...[
                SectionTitle(DateFormat('EEEE, d. MMMM', 'de').format(day.key)),
                for (final slot in day.value)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _SlotCard(
                      slot: slot,
                      mine: slot.id == pool.myBooking,
                      started: slot.startedAt(now),
                      admin: admin,
                      busy: _busy,
                      canBook:
                          invited &&
                          !pool.closed &&
                          !mineLocked &&
                          !slot.startedAt(now) &&
                          !slot.full,
                      hasBooking: mine != null,
                      canCancel: invited && !pool.closed && !mineLocked,
                      onBook: () => _book(pool, slot),
                      onCancel: () => _cancel(pool, slot),
                      onAssign: () => _assign(pool, slot),
                      onRemove: (person) => _remove(pool, slot, person),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _status(
    BuildContext context,
    SlotPool pool,
    bool invited,
    bool admin,
    DateTime now,
  ) {
    final mine = pool.mySlot;
    final (IconData icon, Color color, String title, String text) = switch ((
      invited,
      mine,
    )) {
      (true, final TimeSlot slot) => (
        Icons.event_available_outlined,
        StageTheme.green,
        'Dein Slot: ${slotLabel(slot)}',
        pool.closed || slot.startedAt(now)
            ? 'Der Termin steht in deinem Kalender.'
            : 'Der Termin steht in deinem Kalender. Du kannst umbuchen oder freigeben.',
      ),
      (true, null) when pool.closed => (
        Icons.lock_outline,
        Theme.of(context).colorScheme.onSurfaceVariant,
        'Buchung geschlossen',
        'Die Theaterleitung hat die Buchung geschlossen.',
      ),
      (true, null) when !pool.hasFreeSlotAt(now) => (
        Icons.event_busy_outlined,
        Theme.of(context).colorScheme.onSurfaceVariant,
        'Kein Zeitfenster mehr frei',
        'Bitte melde dich bei der Theaterleitung.',
      ),
      (true, null) => (
        Icons.touch_app_outlined,
        StageTheme.orange,
        'Noch kein Slot gewählt',
        'Wähle unten ein freies Zeitfenster.',
      ),
      _ => (
        Icons.info_outline,
        Theme.of(context).colorScheme.onSurfaceVariant,
        'Du bist nicht eingeladen',
        admin
            ? 'Als Admin kannst du Personen über „Person zuweisen“ eintragen.'
            : 'Du kannst hier kein Zeitfenster buchen.',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(text, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Invited active people without a slot, so admins can follow up.
  Widget _missing(BuildContext context, SlotPool pool) {
    final booked = {
      for (final s in pool.slots)
        for (final p in s.people) p.personId,
    };
    final invited = _controller.members
        .where(
          (m) =>
              m.active &&
              m.inAudience(
                pool.roleIds,
                pool.personIds,
                _controller.ensemblesOf(pool.productionIds),
              ),
        )
        .toList();
    final missing = invited.where((m) => !booked.contains(m.id)).toList();
    if (invited.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: ExpansionTile(
          shape: const Border(),
          leading: const Icon(Icons.groups_outlined),
          title: Text(
            '${invited.length - missing.length} von ${invited.length} '
            'Eingeladenen haben gebucht',
          ),
          subtitle: missing.isEmpty
              ? null
              : Text('Noch ohne Zeitfenster: ${missing.length}'),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              missing.isEmpty
                  ? 'Alle Eingeladenen haben ein Zeitfenster.'
                  : missing.map((m) => m.name).join(', '),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({
    required this.slot,
    required this.mine,
    required this.started,
    required this.admin,
    required this.busy,
    required this.canBook,
    required this.hasBooking,
    required this.canCancel,
    required this.onBook,
    required this.onCancel,
    required this.onAssign,
    required this.onRemove,
  });
  final TimeSlot slot;
  final bool mine, started, admin, busy, canBook, hasBooking, canCancel;
  final VoidCallback onBook, onCancel, onAssign;
  final ValueChanged<({int personId, String name})> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = started
        ? 'vorbei'
        : slot.full
        ? 'voll'
        : '${slot.free} frei';
    final actions = <Widget>[
      if (mine && canCancel && !started)
        OutlinedButton.icon(
          onPressed: busy ? null : onCancel,
          icon: const Icon(Icons.event_busy_outlined),
          label: const Text('Freigeben'),
        )
      else if (!mine && canBook)
        hasBooking
            ? OutlinedButton.icon(
                onPressed: busy ? null : onBook,
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Hierhin umbuchen'),
              )
            : FilledButton.icon(
                onPressed: busy ? null : onBook,
                icon: const Icon(Icons.check),
                label: const Text('Buchen'),
              ),
      if (admin && !started && !slot.full)
        TextButton.icon(
          onPressed: busy ? null : onAssign,
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Person zuweisen'),
        ),
    ];
    final card = Card(
      color: mine
          ? Color.alphaBlend(
              StageTheme.green.withValues(alpha: .1),
              theme.cardTheme.color ?? scheme.surface,
            )
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: mine
            ? BorderSide(
                color: StageTheme.green.withValues(alpha: .6),
                width: 2,
              )
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${slotTime(slot)} Uhr',
                  style: theme.textTheme.titleMedium,
                ),
                if (mine)
                  const StatePill(
                    'Dein Slot',
                    icon: Icons.check_circle_outline,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Occupancy(slot: slot),
                Text(
                  state,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: started || slot.full
                        ? scheme.onSurfaceVariant
                        : StageTheme.green,
                  ),
                ),
              ],
            ),
            if (slot.people.isNotEmpty) ...[
              const SizedBox(height: 10),
              if (admin)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in slot.people)
                      InputChip(
                        label: Text(p.name),
                        onDeleted: busy ? null : () => onRemove(p),
                        deleteButtonTooltipMessage: '${p.name} entfernen',
                      ),
                  ],
                )
              else
                Text(
                  slot.people.map((p) => p.name).join(', '),
                  style: theme.textTheme.bodyMedium,
                ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
    return started && !mine ? Opacity(opacity: .62, child: card) : card;
  }
}

/// Booked and free places as small dots, e.g. ●○ for one of two.
class _Occupancy extends StatelessWidget {
  const _Occupancy({required this.slot});
  final TimeSlot slot;
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final label = '${slot.booked} von ${slot.capacity} Plätzen belegt';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: Text(
          slot.capacity <= 12
              ? '${'●' * min(slot.booked, slot.capacity)}${'○' * slot.free}'
              : '${slot.booked}/${slot.capacity}',
          style: TextStyle(
            color: color,
            fontSize: 14,
            letterSpacing: 2,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 21, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 14),
      Expanded(
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    ],
  );
}
