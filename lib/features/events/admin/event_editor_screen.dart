import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/audience/audience_pickers.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/admin_page.dart';
import '../domain/event_series.dart';
import '../domain/event_types.dart';

/// Matches `changePushWindowDays` on the server.
const changePushWindowDays = 14;

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
        widget.initialDay ?? DateTime.now().add(const Duration(days: 1));
    _start = e?.startsAt ?? DateTime(next.year, next.month, next.day, 19);
    _end = e?.endsAt ?? _start.add(const Duration(hours: 2));
    // Eight weeks; calendar arithmetic, as a Duration would shift at DST.
    _until = DateTime(_start.year, _start.month, _start.day + 56);
    _locked = e?.locked ?? false;
    _kind = e?.kind ?? 'rehearsal';
    _production = e?.productionId;
  }

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
      await widget.controller.performAction({
        'action': 'event.save',
        'id': widget.event?.id,
        'version': widget.event?.version,
        'title': _title.text,
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
      if (mounted) {
        if (push) {
          final what = series == null ? 'Termin' : 'Terminserie';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                widget.controller.pendingCount > 0
                    ? '$what vorgemerkt, Benachrichtigung folgt nach der Übertragung.'
                    : '$what gespeichert, Benachrichtigung wird verschickt.',
              ),
            ),
          );
        }
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final series = widget.event!.inSeries;
    // 'single' or, for a series, 'following'.
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(series ? 'Serientermin löschen?' : 'Termin löschen?'),
        content: Text(
          series
              ? 'Der Termin gehört zu einer Serie. Gelöschte Termine verlieren '
                    'ihre Rückmeldungen.'
              : 'Der Termin und seine Rückmeldungen werden entfernt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          if (series)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'following'),
              child: const Text('Diesen und alle folgenden'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'single'),
            child: Text(series ? 'Nur diesen Termin' : 'Löschen'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'event.delete',
        'id': widget.event!.id,
        'version': widget.event!.version,
        if (choice == 'following') 'series': 'following',
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: widget.event == null ? 'Termin anlegen' : 'Termin bearbeiten',
    children: (context) => [
      TextField(
        controller: _title,
        decoration: const InputDecoration(labelText: 'Titel'),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _description,
        minLines: 3,
        maxLines: 8,
        maxLength: 5000,
        decoration: const InputDecoration(labelText: 'Beschreibung'),
      ),
      const SizedBox(height: 20),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.calendar_month),
              title: const Text('Beginn'),
              subtitle: Text(
                DateFormat('EEEE, d. MMMM yyyy · HH:mm', 'de').format(_start),
              ),
              onTap: () => _pick(true),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Ende'),
              subtitle: Text(
                DateFormat('d. MMMM yyyy · HH:mm', 'de').format(_end),
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
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: series.problem == null
                          ? null
                          : Theme.of(context).colorScheme.error,
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
      const SizedBox(height: 20),
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
      Text(
        'Eingeladen: ${widget.controller.audienceLabel(_roleIds, _personIds, _productionIds)}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<String>(
        key: const ValueKey('event-kind'),
        initialValue: _kind,
        decoration: const InputDecoration(labelText: 'Art des Termins'),
        items: eventTypes.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (s) => setState(() => _kind = s!),
      ),
      const SizedBox(height: 14),
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
                          'Geht an: ${widget.controller.audienceLabel(_roleIds, _personIds, _productionIds)}'
                    // Changes only reach people who already answered.
                    : 'Geht an alle, die schon zu- oder abgesagt haben '
                          '(${widget.controller.audienceLabel(_roleIds, _personIds, _productionIds)})'
              : 'Push ist noch nicht eingerichtet.',
        ),
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy || _series?.problem != null ? null : _save,
        child: Text(
          _series == null ? 'Termin speichern' : 'Terminserie speichern',
        ),
      ),
      if (widget.event != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: TextButton(
            onPressed: _busy ? null : _delete,
            child: const Text('Termin löschen'),
          ),
        ),
    ],
  );
}
