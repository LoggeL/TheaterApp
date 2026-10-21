import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/account_permissions.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/audience/audience_pickers.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/one_line_segmented_button.dart';
import '../../../shared/widgets/page_header.dart';
import '../../slots/ui/slot_pools_screen.dart';
import '../domain/event_places.dart';
import '../domain/event_series.dart';
import '../domain/event_types.dart';
import 'event_place_field.dart';

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

  /// "Alle gelten als zugesagt": invitees only decline (servers with
  /// `autoAccept`).
  late bool _autoAccept;
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

  /// "Ganze Serie" instead of "Nur dieser Termin" for an occurrence of a
  /// series: the changes reach all its occurrences that have not started yet.
  bool _wholeSeries = false;

  /// "Wiederholen bis" of the whole series; the day of its last occurrence
  /// until changed.
  late DateTime _seriesEnd;
  late final DateTime _lastSeriesDay;

  /// Whether an occurrence can be edited for the whole series (servers with
  /// `seriesManage`).
  bool get _canEditSeries =>
      widget.event?.inSeries == true &&
      widget.controller.supports('seriesManage');

  /// All occurrences of the edited series, by start.
  List<TheaterEvent> get _occurrences {
    final series = widget.event?.seriesId;
    if (series == null) return const [];
    return widget.controller.events
        .where(
          (e) => e.seriesId == series && !e.fromSlotPool && e.startsAt != null,
        )
        .toList()
      ..sort((a, b) => a.startsAt!.compareTo(b.startsAt!));
  }

  /// Occurrences that have not started yet: those a whole-series edit changes.
  List<TheaterEvent> get _upcoming => _occurrences
      .where((e) => e.startsAt!.isAfter(widget.controller.now))
      .toList();

  /// The series rhythm; null when unknown (older series with irregular
  /// dates), which leaves its end as it is.
  SeriesRhythm? get _rhythm => SeriesRhythm.fromWire(
    _occurrences.map((e) => e.seriesEvery).nonNulls.firstOrNull,
  );

  /// What the picked "Wiederholen bis" day adds or removes.
  SeriesEndChange? get _endChange =>
      _wholeSeries && _rhythm != null && _occurrences.isNotEmpty
      ? planSeriesEnd(
          starts: [for (final e in _occurrences) e.startsAt!],
          anchor: widget.event!.startsAt!,
          rhythm: _rhythm,
          until: _seriesEnd,
          now: widget.controller.now,
        )
      : null;
  bool get _extending => _endChange?.added.isNotEmpty ?? false;

  /// On by default. For an edit the server pushes only a new date, time or
  /// place; switched off, nothing is pushed.
  bool _push = true;

  /// Whether an edit changes what attendees must know: date, time or place,
  /// or new dates of a series. Typo fixes in title or description are never
  /// pushed (as on the server).
  bool get _relevantChange => _extending || _relevantTimeOrPlace;
  bool get _relevantTimeOrPlace {
    final old = widget.event;
    return old == null ||
        !(old.startsAt?.isAtSameMomentAs(_start) ?? false) ||
        !(old.endsAt?.isAtSameMomentAs(_end) ?? false) ||
        old.place.trim() != _place.text.trim();
  }

  /// Changes are pushed only for events within the next two weeks (before or
  /// after the change), mirroring the server; new dates of a series always.
  bool get _changeIsNear {
    final old = widget.event?.startsAt;
    if (old == null || _extending) return true;
    final now = widget.controller.now;
    bool near(DateTime at) =>
        at.isAfter(now) &&
        !at.isAfter(now.add(const Duration(days: changePushWindowDays)));
    if (_wholeSeries) return _upcoming.any((e) => near(e.startsAt!));
    return near(old) || near(_start);
  }

  /// Explains the auto-accept switch; switching it off on a saved event warns
  /// that the implicit answers end. Switching it is silent (server).
  String get _autoAcceptHint {
    if (widget.event?.autoAccept == true && !_autoAccept) {
      return 'Wer nicht ausdrücklich zugesagt hat, gilt danach wieder als '
          'offen.';
    }
    return 'Eingeladene sagen nur ab, wenn sie nicht können. Sie werden zwei '
        'Tage vorher erinnert.${_series != null
            ? ' Gilt für alle Termine der Serie.'
            : _wholeSeries
            ? ' Gilt für alle kommenden Termine der Serie.'
            : ''}';
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

  bool get _valid =>
      _formProblem == null &&
      _series?.problem == null &&
      _endChange?.problem == null;

  String get _state => [
    _title.text,
    _place.text,
    _description.text,
    _start,
    _end,
    _locked,
    _autoAccept,
    _kind,
    _push,
    _repeat,
    _until,
    _wholeSeries,
    _seriesEnd,
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
    _lastSeriesDay = DateUtils.dateOnly(
      [
        _start,
        for (final o in _occurrences) o.startsAt!,
      ].reduce((a, b) => a.isAfter(b) ? a : b),
    );
    _seriesEnd = _lastSeriesDay;
    _locked = e?.locked ?? false;
    _autoAccept = e?.autoAccept ?? false;
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
    // For the whole series only the time changes; each date stays.
    final d = _wholeSeries
        ? current
        : await showDatePicker(
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

  /// Switches between "Nur dieser Termin" and "Ganze Serie". The whole
  /// series keeps each occurrence's date, so a date picked for this one alone
  /// goes back to its own (with the picked times).
  void _setWholeSeries(bool whole) => setState(() {
    _wholeSeries = whole;
    _seriesEnd = _lastSeriesDay;
    final s = widget.event!.startsAt, e = widget.event!.endsAt;
    if (!whole || s == null || e == null) return;
    _start = DateTime(s.year, s.month, s.day, _start.hour, _start.minute);
    _end = DateTime(e.year, e.month, e.day, _end.hour, _end.minute);
  });

  /// "Wiederholen bis": from this occurrence (or the last started one) up to
  /// a year after the last occurrence, as the server allows.
  Future<void> _pickSeriesEnd() async {
    final now = widget.controller.now;
    var first = DateUtils.dateOnly(widget.event!.startsAt!);
    for (final o in _occurrences.where((o) => !o.startsAt!.isAfter(now))) {
      final day = DateUtils.dateOnly(o.startsAt!);
      if (day.isAfter(first)) first = day;
    }
    final last = DateTime(
      _lastSeriesDay.year + 1,
      _lastSeriesDay.month,
      _lastSeriesDay.day,
    );
    final d = await showDatePicker(
      context: context,
      initialDate: _seriesEnd.isBefore(first) ? first : _seriesEnd,
      firstDate: first,
      lastDate: last,
    );
    if (d != null && mounted) setState(() => _seriesEnd = d);
  }

  /// Ending a series earlier deletes its later occurrences; asked first.
  Future<bool> _confirmSeriesEnd(List<DateTime> removed) {
    final n = removed.length;
    // Deleting upcoming events always pushes the cancellation (server).
    final notice = widget.controller.pushConfigured
        ? ' Wer eingeladen ist und nicht abgesagt hat, erfährt per Push von '
              'der Absage.'
        : '';
    final day = DateFormat('d. MMMM', 'de').format(_seriesEnd);
    return confirmDestructive(
      context,
      title: 'Serie verkürzen?',
      message: n == 1
          ? 'Der Termin nach dem $day wird mit seinen Rückmeldungen '
                'gelöscht.$notice'
          : 'Die $n Termine nach dem $day werden mit ihren Rückmeldungen '
                'gelöscht.$notice',
      confirmLabel: n == 1 ? 'Termin löschen' : '$n Termine löschen',
    );
  }

  Future<void> _save() async {
    final whole = _wholeSeries, end = _endChange;
    final ending = end != null && end.removed.isNotEmpty;
    if (ending && (!await _confirmSeriesEnd(end.removed) || !mounted)) return;
    setState(() => _busy = true);
    final push =
        _push &&
        widget.controller.pushConfigured &&
        _changeIsNear &&
        _relevantChange;
    final series = _series;
    try {
      final result = await widget.controller.performActionWithResult({
        'action': 'event.save',
        'id': widget.event?.id,
        'version': widget.event?.version,
        'title': _title.text.trim(),
        'description': _description.text,
        'startsAt': _start.toUtc().toIso8601String(),
        'endsAt': _end.toUtc().toIso8601String(),
        'place': _place.text,
        'locked': _locked,
        // Older servers do not know the field; edits there keep it unset.
        if (widget.controller.supports('autoAccept')) 'autoAccept': _autoAccept,
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
        if (whole) 'series': 'all',
        if (whole && (_extending || ending))
          'until': seriesUntilValue(_seriesEnd),
      });
      if (!mounted) return;
      final outcome = result.outcome, data = result.data;
      final what = series != null
          ? 'Terminserie'
          : whole
          ? 'Serie'
          : 'Termin';
      String count(String key, String label) {
        final n = jsonList(data?[key]).length;
        return n == 0 ? '' : '$n $label';
      }

      final details = [
        count('ids', 'geändert'),
        count('added', 'neu'),
        count('removed', 'gelöscht'),
      ].where((x) => x.isNotEmpty).join(', ');
      final saved = whole && details.isNotEmpty
          ? 'Serie gespeichert ($details)'
          : '$what gespeichert';
      // Without a reply (queued, demo, older server) the request decides.
      final skipped = switch (data?['pushSkipped']) {
        'far_future' =>
          ' – kein Push, der Termin liegt mehr als $changePushWindowDays Tage entfernt.',
        'disabled' => ' – kein Push, der Versand ist nicht eingerichtet.',
        'unchanged' => ' – kein Push, Zeit und Ort sind unverändert.',
        _ => ' – ohne Push.',
      };
      showDone(
        context,
        push
            ? outcomeText(
                outcome,
                done: data?['pushQueued'] == false
                    ? '$saved$skipped'
                    : '$saved, Benachrichtigung wird verschickt.',
                queued:
                    '$what vorgemerkt, Benachrichtigung folgt nach der Übertragung.',
              )
            : outcomeText(
                outcome,
                done: series != null
                    ? 'Terminserie mit ${series.starts.length} Terminen angelegt'
                    : saved,
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
    // Deleting an upcoming event always pushes the cancellation (server).
    final notice =
        widget.controller.pushConfigured &&
            (widget.event!.endsAt?.isAfter(widget.controller.now) ?? false)
        ? ' Wer eingeladen ist und nicht abgesagt hat, erfährt per Push von '
              'der Absage.'
        : '';
    if (!widget.event!.inSeries) {
      final confirmed = await confirmDestructive(
        context,
        title: 'Termin löschen?',
        message: 'Der Termin und seine Rückmeldungen werden entfernt.$notice',
        confirmLabel: 'Löschen',
      );
      return confirmed ? 'single' : null;
    }
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Serientermin löschen?'),
        content: Text(
          'Der Termin gehört zu einer Serie. Gelöschte Termine verlieren '
          'ihre Rückmeldungen.$notice',
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

  /// "Nur dieser Termin" or "Ganze Serie", with what the choice means.
  Widget _seriesScope(ThemeData theme) {
    final upcoming = _upcoming.length;
    final String hint;
    if (!_wholeSeries) {
      hint = 'Teil einer Serie – Änderungen gelten nur für diesen Termin.';
    } else if (upcoming == 0) {
      hint =
          'Alle Termine der Serie haben schon begonnen und bleiben, wie sie '
          'sind.${_rhythm == null ? '' : ' Über „Wiederholen bis“ kannst du die Serie verlängern.'}';
    } else {
      hint =
          'Gilt für ${upcoming == 1 ? 'den kommenden Termin' : 'alle $upcoming kommenden Termine'} '
          'der Serie, vergangene bleiben unverändert. Übernommen wird nur, '
          'was du hier änderst: Einzeln angepasste Termine behalten ihre '
          'übrigen Angaben. Jeder Termin behält sein Datum, nur die Uhrzeit '
          'lässt sich ändern.';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OneLineSegmentedButton<bool>(
            key: const ValueKey('event-series-scope'),
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('Nur dieser Termin'),
                icon: Icon(Icons.event_outlined),
              ),
              ButtonSegment(
                value: true,
                label: Text('Ganze Serie'),
                icon: Icon(Icons.repeat),
              ),
            ],
            selected: {_wholeSeries},
            onSelectionChanged: _busy
                ? null
                : (selection) => _setWholeSeries(selection.single),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            key: const ValueKey('event-series-scope-hint'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// The rhythm of the series (read-only) and its end, which extends or
  /// shortens the series; an unknown rhythm only allows editing.
  List<Widget> _seriesEndTiles(ThemeData theme) {
    final rhythm = _rhythm, end = _endChange;
    final starts = [for (final e in _occurrences) e.startsAt!];
    return [
      const Divider(),
      ListTile(
        key: const ValueKey('event-series-rhythm'),
        leading: const Icon(Icons.repeat),
        title: const Text('Wiederholung'),
        subtitle: Text(
          rhythm == null || starts.isEmpty
              ? 'Unregelmäßig – das Serienende lässt sich hier nicht ändern.'
              : seriesRhythmLabel(rhythm, starts),
        ),
      ),
      if (end != null) ...[
        ListTile(
          key: const ValueKey('event-series-until'),
          leading: const Icon(Icons.event_repeat),
          title: const Text('Wiederholen bis'),
          subtitle: Text(
            DateFormat('EEEE, d. MMMM yyyy', 'de').format(_seriesEnd),
          ),
          onTap: _busy ? null : _pickSeriesEnd,
        ),
        if ((end.problem ?? end.summary).isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Text(
              end.problem ?? end.summary,
              key: const ValueKey('event-series-end-summary'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: end.problem == null ? null : theme.colorScheme.error,
              ),
            ),
          ),
      ],
    ];
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
        permission: eventsPermission,
        title: widget.event == null
            ? 'Termin anlegen'
            : _wholeSeries
            ? 'Serie bearbeiten'
            : 'Termin bearbeiten',
        children: (context) => [
          if (_canEditSeries)
            _seriesScope(theme)
          else if (widget.event?.inSeries == true)
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
                  key: const ValueKey('event-start'),
                  leading: const Icon(Icons.calendar_month),
                  title: const Text('Beginn'),
                  subtitle: Text(
                    // Each occurrence keeps its date; only the time changes.
                    _wholeSeries
                        ? '${DateFormat('HH:mm', 'de').format(_start)} Uhr · '
                              'Datum je Termin'
                        : DateFormat(
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
                        ? '${DateFormat(_wholeSeries ? 'HH:mm' : 'd. MMMM yyyy · HH:mm', 'de').format(_end)}'
                              ' – das Ende muss nach dem Beginn liegen'
                        : _wholeSeries
                        ? '${DateFormat('HH:mm', 'de').format(_end)} Uhr'
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
                if (_wholeSeries) ..._seriesEndTiles(theme),
              ],
            ),
          ),
          const SizedBox(height: 20),
          EventPlaceField(
            controller: _place,
            places: knownPlaces(widget.controller.events),
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
          // A play's event for everyone is often meant for its ensemble only.
          if (_roleIds.isEmpty &&
              _personIds.isEmpty &&
              _productionIds.isEmpty &&
              widget.controller.activeProductions.any(
                (p) => p.id == _production,
              ))
            Padding(
              key: const ValueKey('event-audience-everyone-hint'),
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Dieser Termin gilt für alle Mitglieder. Nur fürs '
                      'Ensemble? Dann Ensemble des Stücks wählen.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
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
          if (widget.controller.supports('autoAccept'))
            SwitchListTile(
              key: const ValueKey('event-auto-accept'),
              value: _autoAccept,
              onChanged: (v) => setState(() => _autoAccept = v),
              title: const Text('Alle gelten als zugesagt'),
              subtitle: Text(_autoAcceptHint),
            ),
          SwitchListTile(
            key: const ValueKey('event-push'),
            value: _push && widget.controller.pushConfigured && _changeIsNear,
            onChanged: widget.controller.pushConfigured && _changeIsNear
                ? (v) => setState(() => _push = v)
                : null,
            title: Text(
              widget.event == null || _extending
                  ? 'Eingeladene per Push benachrichtigen'
                  : 'Neue Zeit oder neuen Ort per Push melden',
            ),
            subtitle: Text(
              !_changeIsNear
                  ? '${_wholeSeries ? 'Die kommenden Termine liegen' : 'Der Termin liegt'} '
                        'mehr als $changePushWindowDays Tage in der '
                        'Zukunft. Änderungen werden erst ab $changePushWindowDays '
                        'Tagen vorher gepusht.'
                  : widget.controller.pushConfigured
                  ? widget.event == null
                        ? '${_series == null ? '' : 'Eine Benachrichtigung für die ganze Serie. '}'
                              'Geht an: $audience'
                        // Like a new series: one push for all new dates.
                        : _extending
                        ? 'Eine Benachrichtigung für die neuen Termine'
                              '${_relevantTimeOrPlace ? ', eine weitere für die neue Zeit oder den neuen Ort' : ''}. '
                              'Geht an: $audience'
                        // Changes only reach people who accepted (server).
                        : !_relevantChange
                        ? 'Datum, Uhrzeit und Ort sind unverändert, daher geht '
                              'kein Push raus. Änderungen an Titel oder '
                              'Beschreibung werden nie gepusht.'
                        : _autoAccept
                        ? 'Geht an alle Eingeladenen, die nicht abgesagt '
                              'haben ($audience). Ausgeschaltet geht kein Push '
                              'raus.'
                        : 'Geht an alle, die zugesagt haben ($audience). '
                              'Ausgeschaltet geht kein Push raus.'
                  : 'Push ist noch nicht eingerichtet.',
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || !_valid ? null : _save,
            child: Text(
              _series != null
                  ? 'Terminserie speichern'
                  : _wholeSeries
                  ? 'Serie speichern'
                  : 'Termin speichern',
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
