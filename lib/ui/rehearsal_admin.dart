import 'profile.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/scene_planning.dart';
import '../data/api_client.dart';
import 'admin.dart';
import 'event_style.dart';
import 'events.dart';
import 'reader.dart';
import 'theme.dart';

String memberResponseLabel(AppController c, String eventId, int memberId) {
  final status = textValue(
    jsonMap(c.memberAttendanceByEvent[eventId])[memberId.toString()],
    'open',
  );
  final arrival = dateValue(
    jsonMap(c.arrivalsByEvent[eventId])[memberId.toString()],
  );
  return status == 'late'
      ? 'Später · ${arrival == null ? 'Uhrzeit offen' : DateFormat.Hm('de').format(arrival.toLocal())}'
      : statusText(status);
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

String _responseCountLabel(String status) => switch (status) {
  'yes' => 'Dabei',
  'late' => 'Später',
  'no' => 'Nicht dabei',
  _ => 'Offen',
};

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

  TheaterEvent get _event =>
      widget.controller.events
          .where((e) => e.id == widget.event.id)
          .firstOrNull ??
      widget.event;

  Future<void> _remind(int open) async {
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'event.remindOpen',
        'eventId': widget.event.id,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              open == 1
                  ? 'Erinnerung an 1 Person vorgemerkt.'
                  : 'Erinnerung an $open Personen vorgemerkt.',
            ),
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
    title: 'Rückmeldungen',
    children: (context) {
      final controller = widget.controller, event = _event;
      final responses = jsonMap(controller.memberAttendanceByEvent[event.id]);
      final arrivals = jsonMap(controller.arrivalsByEvent[event.id]);
      final groups = {for (final s in _responseOrder) s: <TheaterMember>[]};
      for (final m in controller.members.where(
        (m) =>
            m.active &&
            m.inAudience(
              event.roleIds,
              event.personIds,
              controller.ensemblesOf(event.productionIds),
            ),
      )) {
        final status = textValue(responses[m.id.toString()], 'open');
        groups[hasResponse(status) ? status : 'open']!.add(m);
      }
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
      final visible = _filter == null
          ? _responseOrder.where((s) => s == 'open' || counts[s]! > 0)
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
          filter: _filter,
          onFilter: (status) => setState(() {
            _filter = _filter == status ? null : status;
            _collapsed.remove(status);
          }),
          remindable:
              open > 0 &&
                  controller.pushConfigured &&
                  controller.canRespondTo(event)
              ? open
              : 0,
          busy: _busy,
          onRemind: _remind,
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
  });
  final Map<String, int> counts;
  final String? filter;
  final ValueChanged<String> onFilter;

  /// People without an answer who can be reminded now; 0 hides the button.
  final int remindable;
  final bool busy;
  final ValueChanged<int> onRemind;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final total = counts.values.fold(0, (sum, n) => sum + n);
    final answered = total - counts['open']!;
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
                    for (final status in _responseOrder)
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
                for (final status in _responseOrder)
                  '${counts[status]} ${_responseCountLabel(status)}',
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
                            for (final status in _responseOrder.where(
                              (s) => counts[s]! > 0,
                            ))
                              Expanded(
                                flex: counts[status]!,
                                child: Container(
                                  margin: const EdgeInsetsDirectional.only(
                                    end: 2,
                                  ),
                                  color: responseColor(status, dark: dark)
                                      .withValues(
                                        alpha: status == 'open' ? .35 : 1,
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
                  : '$answered von $total haben sich zurückgemeldet',
              style: theme.textTheme.bodyMedium,
            ),
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
                  onPressed: busy ? null : () => onRemind(remindable),
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('Offene erinnern'),
                ),
              ),
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
  });
  final AppController controller;
  final String status;
  final List<TheaterMember> people;
  final bool expanded;
  final VoidCallback onToggle;
  final String? Function(TheaterMember)? detail;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = responseColor(
      status,
      dark: theme.brightness == Brightness.dark,
    );
    final title = status == 'open' ? 'Fehlt noch' : _responseCountLabel(status);
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
  });
  final AppController controller;
  final TheaterMember member;
  final Color color;
  final String? detail;
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AttendanceEditorScreen extends StatefulWidget {
  const AttendanceEditorScreen({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  State<AttendanceEditorScreen> createState() => _AttendanceEditorScreenState();
}

class _AttendanceEditorScreenState extends State<AttendanceEditorScreen> {
  final Map<int, bool?> _changes = {};
  final Map<int, int> _versions = {};
  String _search = '';
  bool _busy = false;
  bool? present(int id) => _changes.containsKey(id)
      ? _changes[id]
      : jsonMap(widget.controller.checkinsByEvent[widget.event.id])[id
                .toString()]
            as bool?;
  Future<void> _save({bool openScenes = false}) async {
    setState(() => _busy = true);
    try {
      if (_changes.isNotEmpty) {
        await widget.controller.performAction({
          'action': 'checkin.save',
          'eventId': widget.event.id,
          'members': [
            for (final item in _changes.entries)
              {
                'id': item.key,
                'present': item.value,
                'version': _versions[item.key] ?? 0,
              },
          ],
        });
      }
      if (mounted) {
        setState(() {
          _changes.clear();
          _versions.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.pendingCount > 0
                  ? 'Auf diesem Gerät vorgemerkt.'
                  : 'Anwesenheit gespeichert.',
            ),
          ),
        );
        if (openScenes) {
          openPage(
            context,
            ScenePlannerScreen(
              controller: widget.controller,
              event:
                  widget.controller.events
                      .where((e) => e.id == widget.event.id)
                      .firstOrNull ??
                  widget.event,
            ),
          );
        }
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
    title: 'Anwesenheit',
    children: (context) {
      final members = widget.controller.members
          .where(
            (m) =>
                m.active &&
                m.inAudience(
                  widget.event.roleIds,
                  widget.event.personIds,
                  widget.controller.ensemblesOf(widget.event.productionIds),
                ),
          )
          .toList();
      final here = members.where((m) => present(m.id) == true).length,
          away = members.where((m) => present(m.id) == false).length;
      return [
        Text('${widget.event.title} · ${eventDate(widget.event)}'),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Vor Ort', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  '$here da · $away fehlt · ${members.length - here - away} nicht erfasst',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Mitglied suchen',
          ),
          onChanged: (s) => setState(() => _search = s),
        ),
        const SizedBox(height: 16),
        for (final m in members.where(
          (m) => m.name.toLowerCase().contains(_search.toLowerCase()),
        ))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    MemberAvatar(
                      controller: widget.controller,
                      avatarId: m.avatarId,
                      initials: m.initials,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            memberResponseLabel(
                              widget.controller,
                              widget.event.id,
                              m.id,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: present(m.id) == true
                          ? 'here'
                          : present(m.id) == false
                          ? 'away'
                          : 'unknown',
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 'here', child: Text('Da')),
                        DropdownMenuItem(value: 'away', child: Text('Fehlt')),
                        DropdownMenuItem(
                          value: 'unknown',
                          child: Text('Nicht erfasst'),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _versions.putIfAbsent(
                                m.id,
                                () => intValue(
                                  widget
                                      .controller
                                      .checkinVersions['${widget.event.id}:${m.id}'],
                                ),
                              );
                              _changes[m.id] = v == 'unknown'
                                  ? null
                                  : v == 'here';
                            }),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy || _changes.isEmpty ? null : _save,
          child: Text(
            _changes.isEmpty
                ? 'Anwesenheit gespeichert'
                : 'Änderungen speichern',
          ),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _save(openScenes: true),
          icon: const Icon(Icons.playlist_add_check),
          label: Text(
            _changes.isEmpty
                ? 'Spielbare Szenen ansehen'
                : 'Speichern und Szenen ansehen',
          ),
        ),
      ];
    },
  );
}

class ScenePlannerScreen extends StatefulWidget {
  const ScenePlannerScreen({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  State<ScenePlannerScreen> createState() => _ScenePlannerScreenState();
}

class _ScenePlannerScreenState extends State<ScenePlannerScreen> {
  String? _production;
  bool _useCheckins = true, _loading = false, _saving = false;
  bool _conflict = false;
  late int _version;
  final Set<String> _failedSaves = {};
  late DateTime _at;
  final Set<String> _selected = {};
  @override
  void initState() {
    super.initState();
    final event =
        widget.controller.events
            .where((e) => e.id == widget.event.id)
            .firstOrNull ??
        widget.event;
    _version = event.version;
    _production =
        event.productionId ?? widget.controller.productions.firstOrNull?.id;
    _at = event.startsAt ?? DateTime.now();
    _selected.addAll(event.sceneIds);
    if (_production != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await widget.controller.loadScript(_production!);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final previous = widget.controller.outbox.map((a) => a.id).toSet();
    setState(() => _saving = true);
    try {
      await widget.controller.performAction({
        'action': 'event.script',
        'eventId': widget.event.id,
        'version': _version,
        'productionId': _production,
        'sceneIds': _selected.toList(),
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        if (e is ApiException && e.statusCode == 409) {
          setState(() {
            _conflict = true;
            _failedSaves.addAll(
              widget.controller.outbox
                  .where((a) => a.failed && !previous.contains(a.id))
                  .map((a) => a.id),
            );
          });
        }
        showProblem(context, e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resolveConflict({required bool keepDraft}) async {
    setState(() => _saving = true);
    try {
      await widget.controller.refresh();
      if (widget.controller.isOffline) {
        throw const ApiException(
          'Der aktuelle Stand ist offline nicht verfügbar. Dein Entwurf bleibt erhalten.',
        );
      }
      if (widget.controller.error != null) {
        throw const ApiException(
          'Der aktuelle Stand konnte nicht geladen werden. Dein Entwurf bleibt erhalten.',
        );
      }
      final latest = widget.controller.events
          .where((e) => e.id == widget.event.id)
          .firstOrNull;
      if (latest == null) {
        throw const ApiException('Der Termin ist nicht mehr verfügbar.');
      }
      for (final id in _failedSaves) {
        await widget.controller.discardAction(id);
      }
      if (!mounted) return;
      setState(() {
        _version = latest.version;
        _conflict = false;
        _failedSaves.clear();
        if (!keepDraft) {
          _production =
              latest.productionId ??
              widget.controller.productions.firstOrNull?.id;
          _selected
            ..clear()
            ..addAll(latest.sceneIds);
        }
      });
      if (_production != null) await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              keepDraft
                  ? 'Aktueller Stand geladen. Prüfe deinen Entwurf und speichere erneut.'
                  : 'Aktuelle Szenenauswahl übernommen.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Szenen planen',
    children: (context) {
      final doc = widget.controller.scripts[_production];
      final production = widget.controller.productionRecords
          .where((p) => p['id'] == _production)
          .firstOrNull;
      final currentEvent = widget.controller.events
          .where((e) => e.id == widget.event.id)
          .firstOrNull;
      return [
        DropdownButtonFormField<String>(
          key: ValueKey(_production),
          initialValue: _production,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Produktion'),
          items: [
            for (final p in widget.controller.productions)
              DropdownMenuItem(
                value: p.id,
                child: Text(p.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _saving || _loading
              ? null
              : (v) {
                  setState(() {
                    _production = v;
                    _selected.clear();
                  });
                  if (v != null) _load();
                },
        ),
        const SizedBox(height: 24),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Vor Ort')),
            ButtonSegment(value: false, label: Text('Zusagen')),
          ],
          selected: {_useCheckins},
          onSelectionChanged: (v) => setState(() => _useCheckins = v.single),
        ),
        const SizedBox(height: 12),
        Text(
          _useCheckins
              ? 'Grundlage: erfasste Anwesenheit'
              : 'Grundlage: Rückmeldungen',
        ),
        if (!_useCheckins)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: Text(
              'Planen ab ${DateFormat('EEE, dd.MM. · HH:mm', 'de').format(_at)}',
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final time = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(_at),
              );
              if (time != null && mounted) {
                setState(
                  () => _at = scenePlanningTime(
                    startsAt: widget.event.startsAt ?? _at,
                    endsAt: widget.event.endsAt,
                    hour: time.hour,
                    minute: time.minute,
                  ),
                );
              }
            },
          ),
        const SizedBox(height: 22),
        if (_loading) const LinearProgressIndicator(),
        if (!_loading && doc == null)
          EmptyState(
            icon: Icons.menu_book_outlined,
            title: 'Noch kein Drehbuch',
            message:
                widget.controller.error ??
                'Bitte zuerst ein Drehbuch zur Produktion übernehmen.',
          ),
        if (doc != null)
          for (final scene in doc.scenes)
            Builder(
              builder: (context) {
                final state = evaluateScene(
                  scene: scene,
                  casting: jsonMap(production?['casting']),
                  checkins: jsonMap(
                    widget.controller.checkinsByEvent[widget.event.id],
                  ),
                  responses: jsonMap(
                    widget.controller.memberAttendanceByEvent[widget.event.id],
                  ),
                  arrivals: jsonMap(
                    widget.controller.arrivalsByEvent[widget.event.id],
                  ),
                  useCheckins: _useCheckins,
                  at: _at,
                );
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: CheckboxListTile(
                      value: _selected.contains(scene.id),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('Szene ${scene.id} · ${scene.title}'),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.details.isEmpty
                                  ? scene.roles.join(' · ')
                                  : state.details.join('\n'),
                            ),
                            const SizedBox(height: 8),
                            StatePill(
                              state.playable
                                  ? 'Spielbar'
                                  : state.status == 'unknown'
                                  ? 'Ungeklärt'
                                  : 'Unvollständig',
                              color: state.playable
                                  ? StageTheme.green
                                  : state.status == 'unknown'
                                  ? const Color(0xFFA25B06)
                                  : StageTheme.orange,
                            ),
                          ],
                        ),
                      ),
                      onChanged: _saving
                          ? null
                          : (v) => setState(() {
                              if (v == true) {
                                _selected.add(scene.id);
                              } else {
                                _selected.remove(scene.id);
                              }
                            }),
                    ),
                  ),
                );
              },
            ),
        const SizedBox(height: 20),
        Text('${_selected.length} Szenen ausgewählt'),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _selected.isEmpty || _production == null
              ? null
              : () => openPage(
                  context,
                  ScriptReaderScreen(
                    controller: widget.controller,
                    productionId: _production!,
                    initialSceneId: _selected.first,
                  ),
                ),
          icon: const Icon(Icons.auto_stories_outlined),
          label: const Text('Ausgewählte Szene öffnen'),
        ),
        const SizedBox(height: 16),
        if (_conflict) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Szenenauswahl prüfen',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Die Zuordnung wurde inzwischen geändert oder abgelehnt. Dein Entwurf bleibt erhalten. Lade den aktuellen Stand, bevor du erneut speicherst.',
                  ),
                  if (currentEvent != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      currentEvent.sceneIds.isEmpty
                          ? 'Aktuell gespeichert: keine Szenen ausgewählt.'
                          : 'Aktuell gespeichert: Szenen ${currentEvent.sceneIds.join(', ')}.',
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => _resolveConflict(keepDraft: true),
                    child: const Text('Entwurf behalten und Stand prüfen'),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _resolveConflict(keepDraft: false),
                    child: const Text('Aktuelle Auswahl übernehmen'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        FilledButton(
          onPressed: _saving || _loading || _conflict || _production == null
              ? null
              : _save,
          child: const Text('Für diese Probe speichern'),
        ),
      ];
    },
  );
}
