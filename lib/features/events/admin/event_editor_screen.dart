import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/audience/audience_pickers.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../slots/ui/slot_pools_screen.dart';
import '../domain/event_series.dart';
import '../domain/event_types.dart';

/// Matches `changePushWindowDays` on the server.
const changePushWindowDays = 14;

/// How the [EventEditorScreen] was left, if not by going back.
enum EventEditorResult { saved, deleted }

/// Opens the editor for [event]. Events from a slot pool follow their
/// bookings and are edited in the pool instead.
Future<EventEditorResult?> editEvent(
  BuildContext context,
  AppController controller,
  TheaterEvent event,
) async {
  if (event.fromSlotPool) {
    openSlotPool(context, controller, event.slotPoolId!);
    return null;
  }
  return openPage<EventEditorResult>(
    context,
    EventEditorScreen(controller: controller, event: event),
  );
}

class EventEditorScreen extends StatefulWidget {
  const EventEditorScreen({
    super.key,
    required this.controller,
    this.event,
    this.initialDay,
  });
  final AppController controller;
  final TheaterEvent? event;

  /// Day preselected for a new event, e.g. from the calendar.
  final DateTime? initialDay;
  @override
  State<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends State<EventEditorScreen> {
  late final TextEditingController _title, _place, _description;
  late DateTime _start, _end;
  late bool _locked;
  late String _kind;
  String? _production;

  /// The play an event belongs to (scenes, script) follows the chosen
  /// ensemble; without one an existing link is kept, e.g. a premiere for all.
  String? get _linkedProduction {
    if (_productionIds.isEmpty || _productionIds.contains(_production)) {
      return _production;
    }
    return widget.controller.productions
            .where((p) => _productionIds.contains(p.id))
            .firstOrNull
            ?.id ??
        _production;
  }

  late Set<String> _roleIds;
  late Set<int> _personIds;
  late Set<String> _productionIds;
  bool _busy = false;

  /// The title error shows only once the field has been edited.
  bool _titleTouched = false;

  /// Everything the member can change, to detect unsaved input.
  late final String _initialState;

  /// Repetition of a new event; null creates a single event.
  SeriesRhythm? _repeat;
  late DateTime _until;
  SeriesPlan? get _series => widget.event == null && _repeat != null
      ? planSeries(_start, _end, _repeat!, _until)
      : null;

  /// New events notify their invitees by default; edits only on request.
  late bool _push = widget.event == null;

  /// Changes are pushed only for events within the next two weeks (before or
  /// after the change), mirroring the server.
  bool get _changeIsNear {
    final old = widget.event?.startsAt;
    if (old == null) return true;
    final now = widget.controller.now;
    bool near(DateTime at) =>
        at.isAfter(now) &&
        !at.isAfter(now.add(const Duration(days: changePushWindowDays)));
    return near(old) || near(_start);
  }

  bool get _titleMissing => _title.text.trim().isEmpty;
  bool get _endBeforeStart => !_end.isAfter(_start);

  /// What in the form keeps the event from being saved, as one short line;
  /// series problems show beside the series summary instead.
  String? get _formProblem {
    if (_titleMissing) return 'Noch fehlt: Titel';
    if (_endBeforeStart) return 'Das Ende muss nach dem Beginn liegen.';
    return null;
  }

  bool get _valid => _formProblem == null && _series?.problem == null;

  String get _state => [
    _title.text,
    _place.text,
    _description.text,
    _start,
    _end,
    _locked,
    _kind,
    _push,
    _repeat,
    _until,
    (_roleIds.toList()..sort()).join(','),
    (_personIds.toList()..sort()).join(','),
    (_productionIds.toList()..sort()).join(','),
  ].join('\u0000');

  bool get _dirty => _state != _initialState;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _roleIds = {...?e?.roleIds};
    _personIds = {...?e?.personIds};
    _productionIds = {...?e?.productionIds};
    _title = TextEditingController(text: e?.title);
    _description = TextEditingController(text: e?.description);
    _place = TextEditingController(text: e?.place ?? 'Kolpingheim');
    final next =
        widget.initialDay ?? widget.controller.now.add(const Duration(days: 1));
    _start = e?.startsAt ?? DateTime(next.year, next.month, next.day, 19);
    _end = e?.endsAt ?? _start.add(const Duration(hours: 2));
    // Eight weeks; calendar arithmetic, as a Duration would shift at DST.
    _until = DateTime(_start.year, _start.month, _start.day + 56);
    _locked = e?.locked ?? false;
    _kind = e?.kind ?? 'rehearsal';
    _production = e?.productionId;
    _initialState = _state;
    _title.addListener(() {
      if (_title.text != (e?.title ?? '')) _titleTouched = true;
      setState(() {});
    });
    _place.addListener(_changed);
    _description.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _place.dispose();
    super.dispose();
  }

  Future<void> _pick(bool start) async {
    final current = start ? _start : _end;
    final d = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !mounted) return;
    setState(() {
      final value = DateTime(d.year, d.month, d.day, time.hour, time.minute);
      if (start) {
        final duration = _end.difference(_start);
        _start = value;
        _end = value.add(duration);
      } else {
        _end = value;
      }
    });
  }

  Future<void> _pickUntil() async {
    final first = DateUtils.dateOnly(_start);
    final last = DateTime(_start.year + 1, _start.month, _start.day);
    final d = await showDatePicker(
      context: context,
      // The start may have moved since the end of the series was picked.
      initialDate: _until.isBefore(first)
          ? first
          : _until.isAfter(last)
          ? last
          : _until,
      firstDate: first,
      lastDate: last,
    );
    if (d != null && mounted) setState(() => _until = d);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final push = _push && widget.controller.pushConfigured && _changeIsNear;
    final series = _series;
    try {
      final outcome = await widget.controller.performAction({
        'action': 'event.save',
        'id': widget.event?.id,
        'version': widget.event?.version,
        'title': _title.text.trim(),
        'description': _description.text,
        'startsAt': _start.toUtc().toIso8601String(),
        'endsAt': _end.toUtc().toIso8601String(),
        'place': _place.text,
        'locked': _locked,
        'type': _kind,
        'productionId': _linkedProduction,
        'roleIds': _roleIds.toList(),
        'personIds': _personIds.toList(),
        'productionIds': _productionIds.toList(),
        'sceneIds': _linkedProduction == widget.event?.productionId
            ? widget.event?.sceneIds ?? []
            : [],
        'push': push,
        if (series != null)
          'repeat': {'every': _repeat!.wire, 'until': seriesUntilValue(_until)},
      });
      if (!mounted) return;
      final what = series == null ? 'Termin' : 'Terminserie';
      showDone(
        context,
        push
            ? outcomeText(
                outcome,
                done: '$what gespeichert, Benachrichtigung wird verschickt.',
                queued:
                    '$what vorgemerkt, Benachrichtigung folgt nach der Übertragung.',
              )
            : outcomeText(
                outcome,
                done: series == null
                    ? 'Termin gespeichert'
                    : 'Terminserie mit ${series.starts.length} Terminen angelegt',
                queued: '$what vorgemerkt – wird bei Verbindung übertragen.',
              ),
      );
      Navigator.pop(context, EventEditorResult.saved);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 'single' or, for a series, 'following'; null when cancelled.
  Future<String?> _confirmDelete() async {
    if (!widget.event!.inSeries) {
      final confirmed = await confirmDestructive(
        context,
        title: 'Termin löschen?',
        message: 'Der Termin und seine Rückmeldungen werden entfernt.',
        confirmLabel: 'Löschen',
      );
      return confirmed ? 'single' : null;
    }
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Serientermin löschen?'),
        content: const Text(
          'Der Termin gehört zu einer Serie. Gelöschte Termine verlieren '
          'ihre Rückmeldungen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, 'following'),
            child: const Text('Diesen und alle folgenden'),
          ),
          // The narrower choice is the safe default.
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'single'),
            child: const Text('Nur diesen Termin'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete() async {
    final choice = await _confirmDelete();
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final outcome = await widget.controller.performAction({
        'action': 'event.delete',
        'id': widget.event!.id,
        'version': widget.event!.version,
        if (choice == 'following') 'series': 'following',
      });
      if (!mounted) return;
      showDone(
        context,
        outcomeText(
          outcome,
          done: choice == 'following' ? 'Termine gelöscht' : 'Termin gelöscht',
          queued: 'Löschen vorgemerkt – wird bei Verbindung übertragen.',
        ),
      );
      Navigator.pop(context, EventEditorResult.deleted);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    final audience = widget.controller.audienceLabel(
      _roleIds,
      _personIds,
      _productionIds,
    );
    return DiscardGuard(
      dirty: _dirty && !_busy,
      child: AdminPage(
        controller: widget.controller,
        title: widget.event == null ? 'Termin anlegen' : 'Termin bearbeiten',
        children: (context) => [
          if (widget.event?.inSeries == true)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                children: [
                  Icon(Icons.repeat, size: 18, color: theme.hintColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Teil einer Serie – Änderungen gelten nur für diesen Termin.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Titel',
              errorText: _titleTouched && _titleMissing
                  ? 'Bitte einen Titel eingeben.'
                  : null,
            ),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            key: const ValueKey('event-kind'),
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Art des Termins'),
            items: eventTypes.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: (s) => setState(() => _kind = s!),
          ),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.calendar_month),
                  title: const Text('Beginn'),
                  subtitle: Text(
                    DateFormat(
                      'EEEE, d. MMMM yyyy · HH:mm',
                      'de',
                    ).format(_start),
                  ),
                  onTap: () => _pick(true),
                ),
                const Divider(),
                ListTile(
                  leading: Icon(
                    Icons.schedule,
                    color: _endBeforeStart ? error : null,
                  ),
                  title: const Text('Ende'),
                  subtitle: Text(
                    _endBeforeStart
                        ? '${DateFormat('d. MMMM yyyy · HH:mm', 'de').format(_end)}'
                              ' – das Ende muss nach dem Beginn liegen'
                        : DateFormat('d. MMMM yyyy · HH:mm', 'de').format(_end),
                    style: _endBeforeStart ? TextStyle(color: error) : null,
                  ),
                  onTap: () => _pick(false),
                ),
                if (widget.event == null) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: DropdownButtonFormField<SeriesRhythm?>(
                      key: const ValueKey('event-repeat'),
                      initialValue: _repeat,
                      decoration: const InputDecoration(
                        labelText: 'Wiederholen',
                        prefixIcon: Icon(Icons.repeat),
                      ),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Nie')),
                        for (final r in SeriesRhythm.values)
                          DropdownMenuItem(value: r, child: Text(r.label)),
                      ],
                      onChanged: (r) => setState(() => _repeat = r),
                    ),
                  ),
                  if (_series case final series?) ...[
                    ListTile(
                      key: const ValueKey('event-repeat-until'),
                      leading: const Icon(Icons.event_repeat),
                      title: const Text('bis'),
                      subtitle: Text(
                        DateFormat('EEEE, d. MMMM yyyy', 'de').format(_until),
                      ),
                      onTap: _pickUntil,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Text(
                        series.problem ?? series.summary,
                        key: const ValueKey('event-repeat-summary'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: series.problem == null ? null : error,
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _place,
            decoration: const InputDecoration(labelText: 'Ort'),
          ),
          const SectionTitle('Eingeladen'),
          AudiencePicker(
            controller: widget.controller,
            label: 'Eingeladene Rollen',
            allowEveryone: _personIds.isEmpty && _productionIds.isEmpty,
            selected: _roleIds,
            onChanged: (value) => setState(() => _roleIds = value),
          ),
          const SizedBox(height: 16),
          ProductionAudiencePicker(
            controller: widget.controller,
            selected: _productionIds,
            onChanged: (value) => setState(() => _productionIds = value),
          ),
          const SizedBox(height: 16),
          PersonPicker(
            controller: widget.controller,
            selected: _personIds,
            onChanged: (value) => setState(() => _personIds = value),
          ),
          const SizedBox(height: 8),
          Text('Eingeladen: $audience', style: theme.textTheme.bodySmall),
          const SizedBox(height: 24),
          TextField(
            controller: _description,
            minLines: 3,
            maxLines: 8,
            maxLength: 5000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Beschreibung'),
          ),
          const SectionTitle('Optionen'),
          SwitchListTile(
            value: _locked,
            onChanged: (v) => setState(() => _locked = v),
            title: const Text('Rückmeldungen geschlossen'),
          ),
          SwitchListTile(
            key: const ValueKey('event-push'),
            value: _push && widget.controller.pushConfigured && _changeIsNear,
            onChanged: widget.controller.pushConfigured && _changeIsNear
                ? (v) => setState(() => _push = v)
                : null,
            title: const Text('Eingeladene per Push benachrichtigen'),
            subtitle: Text(
              !_changeIsNear
                  ? 'Der Termin liegt mehr als $changePushWindowDays Tage in der '
                        'Zukunft. Änderungen werden erst ab $changePushWindowDays '
                        'Tagen vorher gepusht.'
                  : widget.controller.pushConfigured
                  ? widget.event == null
                        ? '${_series == null ? '' : 'Eine Benachrichtigung für die ganze Serie. '}'
                              'Geht an: $audience'
                        // Changes only reach people who already answered.
                        : 'Geht an alle, die schon zu- oder abgesagt haben '
                              '($audience)'
                  : 'Push ist noch nicht eingerichtet.',
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || !_valid ? null : _save,
            child: Text(
              _series == null ? 'Termin speichern' : 'Terminserie speichern',
            ),
          ),
          if (_formProblem case final problem?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                problem,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (widget.event != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: error),
                onPressed: _busy ? null : _delete,
                child: const Text('Termin löschen'),
              ),
            ),
        ],
      ),
    );
  }
}
