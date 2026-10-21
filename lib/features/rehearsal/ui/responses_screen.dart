import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/account_permissions.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/nudges.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../events/domain/event_format.dart';
import '../../events/domain/rsvp_status.dart';
import '../../events/ui/event_style.dart';
import '../data/event_details_api.dart';
import '../domain/implicit_attendance.dart';
import 'attendance_screen.dart';
import 'scene_planner_screen.dart';

String memberResponseLabel(AppController c, TheaterEvent event, int memberId) {
  final eventId = event.id;
  final status = textValue(
    jsonMap(c.memberAttendanceByEvent[eventId])[memberId.toString()],
    'open',
  );
  // Auto-accepted events: nobody owes an answer. Without an own one the
  // person attends implicitly, or counts as declined because an absence
  // covers the day (as in effectiveResponses).
  if (event.autoAccept && !hasResponse(status)) {
    return implicitAttendees(c, event).contains(memberId)
        ? 'Eingeplant'
        : RsvpStatus.fromWire('no').label;
  }
  final arrival = dateValue(
    jsonMap(c.arrivalsByEvent[eventId])[memberId.toString()],
  );
  return status == 'late'
      ? 'Später · ${arrival == null ? 'Uhrzeit offen' : DateFormat.Hm('de').format(arrival.toLocal())}'
      : RsvpStatus.fromWire(status).label;
}

/// How the implicit attendees of an auto-accepted [event] are reminded: the
/// server pushes "Du bist eingeplant" two days ahead, or right away for
/// events created or moved later, but never below two hours before the start.
/// Null when no such push goes out (other events, locked, no push set up).
String? plannedReminderNote(AppController c, TheaterEvent event) {
  final start = event.startsAt;
  if (!event.autoAccept ||
      event.locked ||
      start == null ||
      !c.pushConfigured ||
      !c.canRespondTo(event)) {
    return null;
  }
  final until = start.difference(c.now);
  if (until > const Duration(hours: 48)) {
    return 'Eingeplante werden zwei Tage vorher automatisch erinnert.';
  }
  return until > const Duration(hours: 2)
      ? 'Eingeplante wurden automatisch erinnert.'
      : null;
}

/// Who is coming to an event, who is not and who still has to answer.
class ResponsesAdminScreen extends StatefulWidget {
  const ResponsesAdminScreen({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  State<ResponsesAdminScreen> createState() => _ResponsesAdminScreenState();
}

const _responseOrder = ['yes', 'late', 'no', 'open'];

String _responseCountLabel(String status) => RsvpStatus.fromWire(status).label;

IconData _responseIcon(String status) => switch (status) {
  'yes' => Icons.thumb_up_alt,
  'late' => Icons.schedule,
  'no' => Icons.thumb_down_alt,
  _ => Icons.help_outline,
};

class _ResponsesAdminScreenState extends State<ResponsesAdminScreen> {
  String? _filter;
  final Set<String> _collapsed = {};
  bool _busy = false;

  /// Reasons, absences and the invitees from the server; null until loaded
  /// and in the demo, offline or on failure (the snapshot view stays).
  EventDetails? _details;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.controller.isDemo) return;
    try {
      final details = await EventDetailsApi(
        widget.controller,
      ).load(widget.event.id);
      if (mounted) setState(() => _details = details);
    } catch (_) {
      // Keep showing what the snapshot knows.
    }
  }

  Future<void> _refresh() async {
    await Future.wait([
      refreshWithFeedback(context, widget.controller),
      _load(),
    ]);
  }

  TheaterEvent get _event =>
      widget.controller.events
          .where((e) => e.id == widget.event.id)
          .firstOrNull ??
      widget.event;

  /// Asks before the push goes out, naming who will get it.
  Future<void> _remind(List<TheaterMember> people) async {
    final open = people.length;
    const shown = 8;
    final names = [
      ...people.take(shown).map((m) => m.name),
      if (open > shown) 'und ${open - shown} weitere',
    ].join(', ');
    final confirmed = await confirmAction(
      context,
      title: 'Offene erinnern?',
      message:
          '${open == 1 ? 'Eine Person bekommt' : '$open Personen bekommen'} '
          'eine Push-Erinnerung an diesen Termin: $names.',
      confirmLabel: 'Erinnerung senden',
      scrollable: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.controller.performActionWithResult({
        'action': 'event.remindOpen',
        'eventId': widget.event.id,
      });
      unawaited(_load());
      if (mounted) {
        final count = intValue(result.data?['recipients'], open);
        final who = count == 1 ? '1 Person' : '$count Personen';
        showDone(
          context,
          outcomeText(
            result.outcome,
            done: 'Erinnerung an $who gesendet.',
            queued:
                'Erinnerung an $who vorgemerkt – wird bei Verbindung gesendet.',
          ),
        );
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    permission: eventsPermission,
    title: 'Rückmeldungen',
    onRefresh: _refresh,
    children: (context) {
      final controller = widget.controller, event = _event;
      final details = _details;
      final responses = jsonMap(controller.memberAttendanceByEvent[event.id]);
      final arrivals = jsonMap(controller.arrivalsByEvent[event.id]);
      final groups = {for (final s in _responseOrder) s: <TheaterMember>[]};
      final invited = details?.invitedIds;
      // Auto-accepted events: who has not answered attends implicitly, unless
      // an absence covers the day (then they count as declined).
      final implicit = implicitAttendees(controller, event), autoIds = <int>{};
      for (final m in controller.members.where(
        (m) =>
            m.active &&
            (invited?.contains(m.id) ??
                m.inAudience(
                  event.roleIds,
                  event.personIds,
                  controller.ensemblesOf(event.productionIds),
                )),
      )) {
        // The snapshot stays the source of the statuses: it is refreshed far
        // more often than the details, which could show a stale answer.
        final status = textValue(responses[m.id.toString()], 'open');
        if (hasResponse(status)) {
          groups[status]!.add(m);
        } else if (!event.autoAccept) {
          groups['open']!.add(m);
        } else if (implicit.contains(m.id)) {
          groups['yes']!.add(m);
          autoIds.add(m.id);
        } else {
          groups['no']!.add(m);
        }
      }
      final now = controller.now;
      final lastReminded = details?.lastRemindedAt ?? event.lastRemindedAt;
      final remindCount = details?.lastRemindedAt != null
          ? details!.remindCount
          : event.remindCount;
      DateTime? arrival(TheaterMember m) =>
          dateValue(arrivals[m.id.toString()])?.toLocal();
      int byName(TheaterMember a, TheaterMember b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase());
      for (final people in groups.values) {
        people.sort(byName);
      }
      // Late arrivals in the order they will turn up, unknown times last.
      groups['late']!.sort((a, b) {
        final x = arrival(a), y = arrival(b);
        if (x == null || y == null) {
          return x == y ? byName(a, b) : (x == null ? 1 : -1);
        }
        final order = x.compareTo(y);
        return order == 0 ? byName(a, b) : order;
      });
      final counts = {for (final e in groups.entries) e.key: e.value.length};
      final open = counts['open']!;
      // Nobody owes an answer on auto-accepted events: no "open" group.
      final order = event.autoAccept
          ? _responseOrder.where((s) => s != 'open').toList()
          : _responseOrder;
      final visible = _filter == null
          ? order.where((s) => s == 'open' || counts[s]! > 0)
          : [_filter!];
      final theme = Theme.of(context);
      return [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: EventKindPill(event.kind),
        ),
        const SizedBox(height: 10),
        Text(event.title, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 6),
        Text('${eventDate(event)} · ${eventTime(event)}'),
        const SizedBox(height: 20),
        _ResponseSummary(
          counts: counts,
          order: order,
          implicit: event.autoAccept ? autoIds.length : null,
          filter: _filter,
          onFilter: (status) => setState(() {
            _filter = _filter == status ? null : status;
            _collapsed.remove(status);
          }),
          remindable:
              !event.autoAccept &&
                  open > 0 &&
                  controller.pushConfigured &&
                  controller.canRespondTo(event)
              ? open
              : 0,
          autoReminder: plannedReminderNote(controller, event),
          busy:
              _busy ||
              (controller.supports('nudges') &&
                  remindCoolingDown(lastReminded, now)),
          lastReminded: lastReminded == null
              ? null
              : lastRemindedLabel(lastReminded, remindCount, now),
          onRemind: () => _remind(groups['open']!),
        ),
        if (_filter != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() => _filter = null),
                icon: const Icon(Icons.close),
                label: const Text('Alle zeigen'),
              ),
            ),
          ),
        if (counts.values.every((n) => n == 0))
          const EmptyState(
            icon: Icons.groups_outlined,
            title: 'Niemand eingeladen',
            message: 'Für diesen Termin ist noch kein Publikum ausgewählt.',
          )
        else
          for (final status in visible) ...[
            const SizedBox(height: 14),
            _ResponseSection(
              key: ValueKey('responses-$status'),
              controller: controller,
              status: status,
              people: groups[status]!,
              expanded: !_collapsed.contains(status),
              onToggle: () => setState(
                () => _collapsed.contains(status)
                    ? _collapsed.remove(status)
                    : _collapsed.add(status),
              ),
              detail: status == 'late'
                  ? (m) {
                      final at = arrival(m);
                      return at == null
                          ? 'Uhrzeit offen'
                          : 'ab ${DateFormat.Hm('de').format(at)} Uhr';
                    }
                  : null,
              reason: status == 'no' ? (m) => details?.reasons[m.id] : null,
              absent: details?.absentIds ?? const {},
              automatic: autoIds,
            ),
          ],
        const SectionTitle('Weiter planen'),
        OutlinedButton.icon(
          onPressed: () => openPage(
            context,
            ScenePlannerScreen(controller: controller, event: event),
          ),
          icon: const Icon(Icons.auto_stories_outlined),
          label: const Text('Szenen planen'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => openPage(
            context,
            AttendanceEditorScreen(controller: controller, event: event),
          ),
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Anwesenheit erfassen'),
        ),
      ];
    },
  );
}

/// Counts per response as tappable filters, the share of each response in
/// the invited audience and, while answers are still possible, the reminder.
class _ResponseSummary extends StatelessWidget {
  const _ResponseSummary({
    required this.counts,
    required this.filter,
    required this.onFilter,
    required this.remindable,
    required this.busy,
    required this.onRemind,
    this.order = _responseOrder,
    this.implicit,
    this.autoReminder,
    this.lastReminded,
  });
  final Map<String, int> counts;

  /// The response groups shown; auto-accepted events have no open group.
  final List<String> order;

  /// On auto-accepted events, how many of the yes count attend implicitly;
  /// null for other events.
  final int? implicit;

  /// The note on the automatic "Du bist eingeplant" reminder, if any.
  final String? autoReminder;
  final String? filter;
  final ValueChanged<String> onFilter;

  /// People without an answer who can be reminded now; 0 hides the button.
  final int remindable;
  final bool busy;
  final VoidCallback onRemind;

  /// "Zuletzt erinnert: …" once anyone reminded the open people.
  final String? lastReminded;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final total = counts.values.fold(0, (sum, n) => sum + n);
    final answered = total - counts['open']!;
    final automatic = implicit ?? 0;
    // The implicit share of the yes bar is drawn lighter.
    final bar = [
      for (final status in order)
        if (status == 'yes') ...[
          ('yes', counts['yes']! - automatic),
          ('auto', automatic),
        ] else
          (status, counts[status]!),
    ].where((x) => x.$2 > 0);
    final attending = counts['yes']! + counts['late']!;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                var columns = (constraints.maxWidth / (110 * scale))
                    .floor()
                    .clamp(1, 4);
                if (columns == 3) columns = 2;
                final width =
                    (constraints.maxWidth - 10 * (columns - 1)) / columns;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final status in order)
                      SizedBox(
                        width: width,
                        child: _ResponseCount(
                          status: status,
                          count: counts[status]!,
                          selected: filter == status,
                          horizontal: columns == 1,
                          onTap: () => onFilter(status),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            Semantics(
              label: [
                for (final status in order)
                  '${counts[status]} ${_responseCountLabel(status)}',
                if (automatic > 0) 'davon $automatic automatisch',
              ].join(', '),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 12,
                  child: total == 0
                      ? ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                        )
                      : Row(
                          children: [
                            for (final (status, count) in bar)
                              Expanded(
                                flex: count,
                                child: Container(
                                  margin: const EdgeInsetsDirectional.only(
                                    end: 2,
                                  ),
                                  color: responseColor(status, dark: dark)
                                      .withValues(
                                        alpha: switch (status) {
                                          'open' => .35,
                                          'auto' => .6,
                                          _ => 1,
                                        },
                                      ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              total == 0
                  ? 'Noch niemand eingeladen'
                  : implicit != null
                  ? [
                      '$attending dabei${automatic > 0 ? ', davon $automatic automatisch' : ''}',
                      if (counts['no']! > 0) '${counts['no']} abgesagt',
                    ].join(' · ')
                  : '$answered von $total haben sich zurückgemeldet',
              style: theme.textTheme.bodyMedium,
            ),
            if (autoReminder != null && total > 0) ...[
              const SizedBox(height: 16),
              Text(autoReminder!, style: theme.textTheme.bodySmall),
            ],
            if (remindable > 0) ...[
              const SizedBox(height: 16),
              Text(
                remindable == 1
                    ? 'Eine Person hat noch nicht geantwortet.'
                    : '$remindable Personen haben noch nicht geantwortet.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  onPressed: busy ? null : onRemind,
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('Offene erinnern'),
                ),
              ),
            ],
            if (lastReminded != null) ...[
              const SizedBox(height: 8),
              Text(lastReminded!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResponseCount extends StatelessWidget {
  const _ResponseCount({
    required this.status,
    required this.count,
    required this.selected,
    required this.horizontal,
    required this.onTap,
  });
  final String status;
  final int count;
  final bool selected, horizontal;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = responseColor(
      status,
      dark: theme.brightness == Brightness.dark,
    );
    final number = Text(
      '$count',
      style: theme.textTheme.headlineMedium?.copyWith(
        color: color,
        fontWeight: FontWeight.w800,
        height: 1.1,
      ),
    );
    final label = Row(
      children: [
        Icon(_responseIcon(status), size: 14, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            _responseCountLabel(status),
            style: theme.textTheme.labelLarge?.copyWith(color: color),
          ),
        ),
      ],
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(
        color: selected ? color : color.withValues(alpha: .18),
        width: selected ? 2 : 1,
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '$count ${_responseCountLabel(status)}',
      excludeSemantics: true,
      child: Material(
        color: color.withValues(alpha: selected ? .16 : .07),
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: horizontal
                ? Row(
                    children: [
                      number,
                      const SizedBox(width: 14),
                      Expanded(child: label),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [number, const SizedBox(height: 4), label],
                  ),
          ),
        ),
      ),
    );
  }
}

/// One response group as a collapsible card of people.
class _ResponseSection extends StatelessWidget {
  const _ResponseSection({
    super.key,
    required this.controller,
    required this.status,
    required this.people,
    required this.expanded,
    required this.onToggle,
    this.detail,
    this.reason,
    this.absent = const {},
    this.automatic = const {},
  });
  final AppController controller;
  final String status;
  final List<TheaterMember> people;

  /// People who attend implicitly (auto-accepted events).
  final Set<int> automatic;
  final bool expanded;
  final VoidCallback onToggle;
  final String? Function(TheaterMember)? detail;

  /// The decline reason of a person, if they gave one.
  final String? Function(TheaterMember)? reason;

  /// People who reported an absence for the event day.
  final Set<int> absent;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = responseColor(
      status,
      dark: theme.brightness == Brightness.dark,
    );
    final title = status == 'open'
        ? 'Noch keine Rückmeldung'
        : _responseCountLabel(status);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: expanded,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
                child: Row(
                  children: [
                    Icon(_responseIcon(status), size: 20, color: color),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(title, style: theme.textTheme.titleMedium),
                    ),
                    const SizedBox(width: 8),
                    StatePill('${people.length}', color: color),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      semanticLabel: expanded ? 'Einklappen' : 'Ausklappen',
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: people.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        status == 'open'
                            ? 'Alle haben sich zurückgemeldet.'
                            : 'Niemand.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        // Two columns on wide screens keep long lists short.
                        final columns = constraints.maxWidth >= 560 ? 2 : 1;
                        final width =
                            (constraints.maxWidth - 16 * (columns - 1)) /
                            columns;
                        return Wrap(
                          spacing: 16,
                          children: [
                            for (final m in people)
                              SizedBox(
                                width: width,
                                child: _ResponsePerson(
                                  controller: controller,
                                  member: m,
                                  detail: detail?.call(m),
                                  reason: reason?.call(m),
                                  absent: absent.contains(m.id),
                                  automatic: automatic.contains(m.id),
                                  color: color,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}

class _ResponsePerson extends StatelessWidget {
  const _ResponsePerson({
    required this.controller,
    required this.member,
    required this.color,
    this.detail,
    this.reason,
    this.absent = false,
    this.automatic = false,
  });
  final AppController controller;
  final TheaterMember member;
  final Color color;
  final String? detail, reason;
  final bool absent, automatic;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roles = controller.roleNames(member.roleIds);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          MemberAvatar(
            controller: controller,
            avatarId: member.avatarId,
            initials: member.initials,
            radius: 18,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.name, style: theme.textTheme.titleSmall),
                if (roles.isNotEmpty)
                  Text(roles, style: theme.textTheme.bodySmall),
                if (detail != null) ...[
                  const SizedBox(height: 6),
                  StatePill(detail!, color: color, icon: Icons.schedule),
                ],
                if (automatic) ...[
                  const SizedBox(height: 6),
                  StatePill(
                    'automatisch',
                    color: color,
                    icon: Icons.event_available_outlined,
                  ),
                ],
                if (reason != null) ...[
                  const SizedBox(height: 4),
                  Text('Grund: $reason', style: theme.textTheme.bodySmall),
                ],
                if (absent) ...[
                  const SizedBox(height: 6),
                  StatePill(
                    'Abwesend gemeldet',
                    color: theme.colorScheme.onSurfaceVariant,
                    icon: Icons.beach_access_outlined,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
