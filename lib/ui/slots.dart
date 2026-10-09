import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/event_types.dart';
import '../core/models.dart';
import 'admin.dart';
import 'audience.dart';
import 'event_style.dart';
import 'responsive.dart';
import 'theme.dart';

/// One bookable time window of a slot pool.
class TimeSlot {
  const TimeSlot({
    required this.id,
    required this.startsAt,
    required this.endsAt,
    this.capacity = 1,
    this.people = const [],
  });
  final String id;
  final DateTime startsAt, endsAt;
  final int capacity;
  final List<({int personId, String name})> people;
  int get booked => people.length;
  int get free => max(0, capacity - booked);
  bool get full => booked >= capacity;
  bool startedAt(DateTime now) => !startsAt.isAfter(now);
  factory TimeSlot.fromJson(JsonMap json) => TimeSlot(
    id: textValue(json['id']),
    startsAt: dateValue(json['startsAt'])!.toLocal(),
    endsAt: dateValue(json['endsAt'])!.toLocal(),
    capacity: intValue(json['capacity'], 1),
    people: [
      for (final p in jsonList(json['people']).map(jsonMap))
        (personId: intValue(p['personId']), name: textValue(p['name'])),
    ],
  );
}

/// A pool of time slots ("Terminfinder"); each invited person books one.
class SlotPool {
  const SlotPool({
    required this.id,
    required this.title,
    this.description = '',
    this.place = '',
    this.kind = 'other',
    this.roleIds = const [],
    this.personIds = const [],
    this.closed = false,
    this.version = 1,
    this.slots = const [],
    this.myBooking,
  });
  final String id, title, description, place, kind;
  final List<String> roleIds;
  final List<int> personIds;
  final bool closed;
  final int version;
  final List<TimeSlot> slots;
  final String? myBooking;
  TimeSlot? get mySlot => slots.where((s) => s.id == myBooking).firstOrNull;

  /// Whether any slot can still be booked by someone without a slot.
  bool hasFreeSlotAt(DateTime now) =>
      slots.any((s) => !s.startedAt(now) && !s.full);
  bool finishedAt(DateTime now) => slots.every((s) => s.startedAt(now));
  factory SlotPool.fromJson(JsonMap json) => SlotPool(
    id: textValue(json['id']),
    title: textValue(json['title']),
    description: textValue(json['description']),
    place: textValue(json['place']),
    kind: textValue(json['type'], 'other'),
    roleIds: jsonList(json['roleIds']).map((e) => e.toString()).toList(),
    personIds: jsonList(json['personIds']).map(intValue).toList(),
    closed: json['closed'] == true,
    version: intValue(json['version'], 1),
    slots: [
      for (final s in jsonList(json['slots']).map(jsonMap))
        if (dateValue(s['startsAt']) != null && dateValue(s['endsAt']) != null)
          TimeSlot.fromJson(s),
    ]..sort((a, b) => a.startsAt.compareTo(b.startsAt)),
    myBooking: json['myBooking']?.toString(),
  );
}

List<SlotPool> slotPoolsOf(AppController controller) =>
    controller.slotPools.map(SlotPool.fromJson).toList();

/// Only invited people may book; admins see every pool without being invited.
bool invitedToSlotPool(AppController controller, SlotPool pool) {
  final user = controller.user;
  if (user?.personId == null) return false;
  return TheaterMember(
    id: user!.personId!,
    name: user.name,
    roleIds: user.roleIds,
  ).inAudience(pool.roleIds, pool.personIds);
}

/// Open pools in which the signed-in person still has to choose a slot.
int slotPoolsAwaitingChoice(AppController controller) => slotPoolsOf(controller)
    .where(
      (p) =>
          !p.closed &&
          p.myBooking == null &&
          invitedToSlotPool(controller, p) &&
          p.hasFreeSlotAt(controller.now),
    )
    .length;

String slotDay(DateTime day) =>
    '${DateFormat.E('de').format(day).replaceAll('.', '')} '
    '${DateFormat('d.M.', 'de').format(day)}';
String slotTime(TimeSlot slot) =>
    '${DateFormat.Hm('de').format(slot.startsAt)}–'
    '${DateFormat.Hm('de').format(slot.endsAt)}';
String slotLabel(TimeSlot slot) =>
    '${slotDay(slot.startsAt)}, ${slotTime(slot)}';

/// First to last slot, e.g. "Sa 18.10., 10:00–12:00".
String slotPoolRange(SlotPool pool) {
  if (pool.slots.isEmpty) return 'Noch keine Zeitfenster';
  final first = pool.slots.first.startsAt;
  final last = pool.slots.map((s) => s.endsAt).reduce((a, b) {
    return a.isAfter(b) ? a : b;
  });
  if (DateUtils.isSameDay(first, last)) {
    return '${slotDay(first)}, ${DateFormat.Hm('de').format(first)}–'
        '${DateFormat.Hm('de').format(last)}';
  }
  return '${slotDay(first)} – ${slotDay(last)}';
}

void openSlotPool(BuildContext context, AppController controller, String id) =>
    openPage(context, SlotPoolScreen(controller: controller, poolId: id));

class SlotPoolsScreen extends StatelessWidget {
  const SlotPoolsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final admin = controller.user?.isAdmin == true;
      final now = controller.now;
      final pools = slotPoolsOf(controller);
      bool done(SlotPool p) => p.closed || p.finishedAt(now);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Terminfinder'),
          actions: [
            if (admin && !controller.isDemo)
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
                  message: admin
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
              if (admin && !controller.isDemo) ...[
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
                    if (controller.user?.isAdmin == true) ...[
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
                        'Eingeladen: ${_controller.audienceLabel(pool.roleIds, pool.personIds)}',
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
        .where((m) => m.active && m.inAudience(pool.roleIds, pool.personIds))
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

class SlotPoolEditorScreen extends StatefulWidget {
  const SlotPoolEditorScreen({super.key, required this.controller, this.pool});
  final AppController controller;

  /// Raw snapshot entry of the pool to edit; null creates a new pool.
  final JsonMap? pool;
  @override
  State<SlotPoolEditorScreen> createState() => _SlotPoolEditorScreenState();
}

class _DraftSlot {
  _DraftSlot(this.start, this.end, this.capacity, {this.id, this.booked = 0});
  final String? id;
  final DateTime start, end;
  final int capacity, booked;
}

/// Gapless windows of [minutes] from [from] until [to]; a shorter rest is
/// dropped.
List<(DateTime, DateTime)> slotWindows(
  DateTime from,
  DateTime to,
  int minutes,
) {
  final windows = <(DateTime, DateTime)>[];
  var start = from;
  while (true) {
    final end = start.add(Duration(minutes: minutes));
    if (end.isAfter(to)) break;
    windows.add((start, end));
    start = end;
  }
  return windows;
}

class _SlotPoolEditorScreenState extends State<SlotPoolEditorScreen> {
  static const durations = [5, 10, 15, 20, 30, 45, 60];
  static const maxSlots = 100;
  late final TextEditingController _title, _description, _place;
  late String _kind;
  late Set<String> _roleIds;
  late Set<int> _personIds;
  late List<_DraftSlot> _slots;
  late DateTime _day;
  TimeOfDay _from = const TimeOfDay(hour: 10, minute: 0),
      _to = const TimeOfDay(hour: 12, minute: 0);
  int _minutes = 15, _capacity = 1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final json = widget.pool;
    final pool = json == null ? null : SlotPool.fromJson(json);
    _title = TextEditingController(text: pool?.title);
    _description = TextEditingController(text: pool?.description);
    _place = TextEditingController(text: pool?.place ?? 'Kolpingheim');
    _kind = eventTypes.containsKey(pool?.kind) ? pool!.kind : 'other';
    _roleIds = {...?pool?.roleIds};
    _personIds = {...?pool?.personIds};
    _slots = [
      for (final s in pool?.slots ?? const <TimeSlot>[])
        _DraftSlot(
          s.startsAt,
          s.endsAt,
          s.capacity,
          id: s.id,
          booked: s.booked,
        ),
    ];
    final next = widget.controller.now.add(const Duration(days: 1));
    _day = DateUtils.dateOnly(
      _slots.isEmpty ? next : _slots.last.start.add(const Duration(days: 1)),
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _place.dispose();
    super.dispose();
  }

  DateTime _at(TimeOfDay t) =>
      DateTime(_day.year, _day.month, _day.day, t.hour, t.minute);
  List<(DateTime, DateTime)> get _windows =>
      slotWindows(_at(_from), _at(_to), _minutes);

  Future<void> _pickDay() async {
    final now = widget.controller.now;
    final day = await showDatePicker(
      context: context,
      initialDate: _day.isBefore(DateUtils.dateOnly(now)) ? now : _day,
      firstDate: DateUtils.dateOnly(now),
      lastDate: DateTime(2100),
    );
    if (day != null && mounted) setState(() => _day = day);
  }

  Future<void> _pickTime(bool from) async {
    final time = await showTimePicker(
      context: context,
      initialTime: from ? _from : _to,
      helpText: from ? 'Von' : 'Bis',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null || !mounted) return;
    setState(() => from ? _from = time : _to = time);
  }

  void _add() {
    final windows = _windows;
    if (windows.isEmpty) {
      showProblem(
        context,
        '„Bis“ muss mindestens $_minutes Minuten nach „Von“ liegen.',
      );
      return;
    }
    if (!windows.first.$1.isAfter(widget.controller.now)) {
      showProblem(context, 'Die Zeitfenster müssen in der Zukunft liegen.');
      return;
    }
    final fresh = windows
        .where((w) => !_slots.any((s) => s.start.isAtSameMomentAs(w.$1)))
        .toList();
    if (_slots.length + fresh.length > maxSlots) {
      showProblem(
        context,
        'Ein Terminfinder kann höchstens $maxSlots Zeitfenster haben.',
      );
      return;
    }
    setState(() {
      _slots = [
        ..._slots,
        for (final w in fresh) _DraftSlot(w.$1, w.$2, _capacity),
      ]..sort((a, b) => a.start.compareTo(b.start));
    });
    final skipped = windows.length - fresh.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${fresh.length == 1 ? '1 Zeitfenster' : '${fresh.length} Zeitfenster'} hinzugefügt'
          '${skipped == 0 ? '.' : ' · $skipped schon vorhanden.'}',
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      showProblem(context, 'Bitte einen Titel eingeben.');
      return;
    }
    if (_slots.isEmpty) {
      showProblem(context, 'Bitte mindestens ein Zeitfenster hinzufügen.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'slotPool.save',
        'id': widget.pool?['id'],
        'version': widget.pool?['version'],
        'title': _title.text,
        'description': _description.text,
        'place': _place.text,
        'type': _kind,
        'roleIds': _roleIds.toList(),
        'personIds': _personIds.toList(),
        'slots': [
          for (final s in _slots)
            {
              if (s.id != null) 'id': s.id,
              'startsAt': s.start.toUtc().toIso8601String(),
              'endsAt': s.end.toUtc().toIso8601String(),
              'capacity': s.capacity,
            },
        ],
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final windows = _windows;
    return AdminPage(
      controller: widget.controller,
      title: widget.pool == null
          ? 'Terminfinder anlegen'
          : 'Terminfinder bearbeiten',
      children: (context) => [
        TextField(
          controller: _title,
          maxLength: 200,
          decoration: const InputDecoration(
            labelText: 'Titel',
            hintText: 'z. B. Fototermin',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _description,
          minLines: 2,
          maxLines: 6,
          maxLength: 3000,
          decoration: const InputDecoration(labelText: 'Beschreibung'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _place,
          decoration: const InputDecoration(labelText: 'Ort'),
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(
          key: const ValueKey('slot-pool-kind'),
          initialValue: _kind,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Art des Termins'),
          items: eventTypes.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (s) => setState(() => _kind = s!),
        ),
        const SizedBox(height: 20),
        AudiencePicker(
          controller: widget.controller,
          label: 'Eingeladene Rollen',
          allowEveryone: _personIds.isEmpty,
          selected: _roleIds,
          onChanged: (value) => setState(() => _roleIds = value),
        ),
        const SizedBox(height: 16),
        PersonPicker(
          controller: widget.controller,
          selected: _personIds,
          onChanged: (value) => setState(() => _personIds = value),
        ),
        const SizedBox(height: 8),
        Text(
          'Eingeladen: ${widget.controller.audienceLabel(_roleIds, _personIds)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SectionTitle('Zeitfenster erzeugen'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.calendar_month),
                title: const Text('Datum'),
                subtitle: Text(
                  DateFormat('EEEE, d. MMMM yyyy', 'de').format(_day),
                ),
                onTap: _busy ? null : _pickDay,
              ),
              const Divider(),
              ListTile(
                key: const ValueKey('slot-from'),
                leading: const Icon(Icons.schedule),
                title: const Text('Von'),
                subtitle: Text('${_from.format24()} Uhr'),
                onTap: _busy ? null : () => _pickTime(true),
              ),
              const Divider(),
              ListTile(
                key: const ValueKey('slot-to'),
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('Bis'),
                subtitle: Text('${_to.format24()} Uhr'),
                onTap: _busy ? null : () => _pickTime(false),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          key: const ValueKey('slot-minutes'),
          initialValue: _minutes,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Dauer je Slot'),
          items: [
            for (final m in durations)
              DropdownMenuItem(value: m, child: Text('$m Minuten')),
          ],
          onChanged: (v) => setState(() => _minutes = v!),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          key: const ValueKey('slot-capacity'),
          initialValue: _capacity,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Plätze je Slot'),
          items: [
            for (var i = 1; i <= 50; i++)
              DropdownMenuItem(
                value: i,
                child: Text(i == 1 ? '1 Platz' : '$i Plätze'),
              ),
          ],
          onChanged: (v) => setState(() => _capacity = v!),
        ),
        const SizedBox(height: 10),
        Text(
          windows.isEmpty
              ? 'Mit diesen Angaben entsteht noch kein Zeitfenster.'
              : 'Ergibt ${windows.length == 1 ? '1 Zeitfenster' : '${windows.length} Zeitfenster'} '
                    'von ${DateFormat.Hm('de').format(windows.first.$1)} '
                    'bis ${DateFormat.Hm('de').format(windows.last.$2)} Uhr.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _add,
          icon: const Icon(Icons.add),
          label: const Text('Slots hinzufügen'),
        ),
        SectionTitle(
          _slots.isEmpty ? 'Zeitfenster' : 'Zeitfenster (${_slots.length})',
        ),
        if (_slots.isEmpty)
          Text(
            'Lege oben Datum und Uhrzeit fest und füge die Zeitfenster hinzu. '
            'Mehrere Tage kannst du nacheinander hinzufügen.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < _slots.length; i++) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    title: Text(
                      '${slotDay(_slots[i].start)}, '
                      '${DateFormat.Hm('de').format(_slots[i].start)}–'
                      '${DateFormat.Hm('de').format(_slots[i].end)}',
                    ),
                    subtitle: Text(
                      _slots[i].booked > 0
                          ? '${_slots[i].booked} von ${_slots[i].capacity} gebucht'
                          : _slots[i].capacity == 1
                          ? '1 Platz'
                          : '${_slots[i].capacity} Plätze',
                    ),
                    trailing: _slots[i].booked > 0
                        ? const Tooltip(
                            message: 'Gebuchte Zeitfenster bleiben erhalten',
                            child: Icon(Icons.lock_outline),
                          )
                        : IconButton(
                            tooltip: 'Zeitfenster entfernen',
                            onPressed: _busy
                                ? null
                                : () => setState(() => _slots.removeAt(i)),
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_busy ? 'Wird gespeichert …' : 'Speichern'),
        ),
      ],
    );
  }
}

extension on TimeOfDay {
  String format24() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
