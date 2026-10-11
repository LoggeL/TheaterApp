import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/audience/audience_pickers.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../events/domain/event_types.dart';
import '../domain/slot_pool.dart';
import '../ui/slot_format.dart';

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

class _SlotPoolEditorScreenState extends State<SlotPoolEditorScreen> {
  static const durations = [5, 10, 15, 20, 30, 45, 60];
  static const maxSlots = 100;
  late final TextEditingController _title, _description, _place;
  late String _kind;
  late Set<String> _roleIds;
  late Set<int> _personIds;
  late Set<String> _productionIds;
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
    _productionIds = {...?pool?.productionIds};
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
        'productionIds': _productionIds.toList(),
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
