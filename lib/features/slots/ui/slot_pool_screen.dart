import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/nudges.dart';
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

  /// Sends [action]; [done] or, given the server's reply, [doneWith] names
  /// the result.
  Future<bool> _run(
    JsonMap action, {
    String? done,
    String? Function(JsonMap? data)? doneWith,
  }) async {
    setState(() => _busy = true);
    try {
      final result = await _controller.performActionWithResult(action);
      final text = doneWith?.call(result.data) ?? done;
      if (mounted && text != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(text)));
      }
      return true;
    } catch (e) {
      if (mounted) showProblem(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _book(SlotPool pool, TimeSlot slot) => _run({
    'action': 'slot.book',
    'poolId': pool.id,
    'slotId': slot.id,
  }, done: 'Gebucht: ${slotLabel(slot)}');

  Future<void> _cancel(SlotPool pool, TimeSlot slot) async {
    if (!await confirmDestructive(
      context,
      title: 'Zeitfenster freigeben?',
      message:
          'Dein Zeitfenster ${slotLabel(slot)} wird für andere frei. '
          'Der Termin verschwindet aus deinem Kalender.',
      confirmLabel: 'Freigeben',
    )) {
      return;
    }
    await _run({
      'action': 'slot.cancel',
      'poolId': pool.id,
    }, done: 'Zeitfenster freigegeben.');
  }

  /// " · benachrichtigt" once the server queued a push for the person.
  static String _notified(JsonMap? data) =>
      data?['pushQueued'] == true ? ' · benachrichtigt' : '';

  Future<void> _assign(SlotPool pool, TimeSlot slot) async {
    final personId = await _pickPerson(pool, slot);
    if (personId == null || !mounted) return;
    final name = _controller.members
        .where((m) => m.id == personId)
        .firstOrNull
        ?.name;
    await _run(
      {
        'action': 'slot.assign',
        'poolId': pool.id,
        'personId': personId,
        'slotId': slot.id,
      },
      doneWith: (data) => data?['pushQueued'] == true && name != null
          ? '$name eingetragen: ${slotLabel(slot)}${_notified(data)}'
          : null,
    );
  }

  /// The assign flow started from a person: choose the slot for them.
  Future<void> _assignPerson(SlotPool pool, TheaterMember member) async {
    final now = _controller.now;
    final slots = pool.slots
        .where((s) => !s.startedAt(now) && !s.full)
        .toList();
    final slot = await showModalBottomSheet<TimeSlot>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(
                  'Zeitfenster für ${member.name}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (slots.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Kein Zeitfenster mehr frei.'),
                ),
              for (final s in slots)
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: Text(slotLabel(s)),
                  subtitle: Text(
                    s.free == 1 ? '1 Platz frei' : '${s.free} Plätze frei',
                  ),
                  onTap: () => Navigator.pop(context, s),
                ),
            ],
          ),
        ),
      ),
    );
    if (slot == null || !mounted) return;
    await _run(
      {
        'action': 'slot.assign',
        'poolId': pool.id,
        'personId': member.id,
        'slotId': slot.id,
      },
      doneWith: (data) =>
          '${member.name} eingetragen: ${slotLabel(slot)}${_notified(data)}',
    );
  }

  /// Pushes a reminder to the invitees who have not booked yet.
  Future<void> _remindOpen(SlotPool pool, int open) async {
    if (!await confirmAction(
      context,
      title: 'Offene erinnern?',
      message:
          '${open == 1 ? 'Eine Person ohne Zeitfenster bekommt' : '$open Personen ohne Zeitfenster bekommen'} '
          'eine Push-Erinnerung an diesen Terminfinder.',
      confirmLabel: 'Erinnerung senden',
    )) {
      return;
    }
    await _run(
      {'action': 'slotPool.remindOpen', 'id': pool.id},
      doneWith: (data) {
        final count = intValue(data?['recipients'], open);
        return 'Erinnerung an ${count == 1 ? '1 Person' : '$count Personen'} gesendet.';
      },
    );
  }

  Future<void> _remove(
    SlotPool pool,
    TimeSlot slot,
    ({int personId, String name}) person,
  ) async {
    if (!await confirmDestructive(
      context,
      title: '${person.name} entfernen?',
      message:
          '${person.name} wird aus dem Zeitfenster ${slotLabel(slot)} entfernt '
          'und kann danach selbst neu buchen.',
      confirmLabel: 'Entfernen',
    )) {
      return;
    }
    await _run(
      {
        'action': 'slot.assign',
        'poolId': pool.id,
        'personId': person.personId,
        'slotId': null,
      },
      doneWith: (data) => data?['pushQueued'] == true
          ? '${person.name} entfernt · benachrichtigt'
          : null,
    );
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
        if (!await confirmDestructive(
          context,
          title: 'Terminfinder löschen?',
          message:
              'Der Terminfinder, alle Buchungen und die daraus erzeugten '
              'Termine werden für alle entfernt.',
          confirmLabel: 'Löschen',
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
      // Admins and holders of the right "Termine verwalten" run the pool.
      final admin = _controller.user?.canManageEvents == true;
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
        !admin
            ? 'Du kannst hier kein Zeitfenster buchen.'
            : _controller.user?.isAdmin == true
            ? 'Als Admin kannst du Personen über „Person zuweisen“ eintragen.'
            : 'Weil du Termine verwaltest, kannst du Personen über „Person zuweisen“ eintragen.',
      ),
    };
    final tone = StageTheme.accentText(color, Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: tone, size: 28),
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
    final now = _controller.now, last = pool.lastRemindedAt;
    final remindable =
        _controller.supports('slotNotices') &&
        _controller.pushConfigured &&
        !pool.closed &&
        pool.hasFreeSlotAt(now) &&
        missing.isNotEmpty;
    final coolingDown =
        _controller.supports('nudges') && remindCoolingDown(last, now);
    final card = Card(
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
          if (missing.isEmpty)
            const Text('Alle Eingeladenen haben ein Zeitfenster.')
          else ...[
            Text(
              'Tippe auf eine Person, um ihr ein Zeitfenster zuzuweisen.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in missing)
                  ActionChip(
                    avatar: const Icon(Icons.person_add_alt, size: 18),
                    label: Text(m.name),
                    tooltip: '${m.name} ein Zeitfenster zuweisen',
                    onPressed: _busy ? null : () => _assignPerson(pool, m),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          card,
          if (remindable) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: _busy || coolingDown
                  ? null
                  : () => _remindOpen(pool, missing.length),
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text('Offene erinnern (${missing.length})'),
            ),
          ],
          if (last != null) ...[
            const SizedBox(height: 6),
            Text(
              lastRemindedLabel(last, pool.remindCount, now),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
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
                        : StageTheme.greenTone.of(theme.brightness),
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
