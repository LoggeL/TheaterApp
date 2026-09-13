import 'responsive.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import 'admin.dart';
import 'theme.dart';

class PollsScreen extends StatelessWidget {
  const PollsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Abstimmungen'),
        actions: [
          if (controller.user?.isAdmin == true)
            IconButton(
              tooltip: 'Abstimmung erstellen',
              icon: const Icon(Icons.add),
              onPressed: () =>
                  openPage(context, PollEditorScreen(controller: controller)),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          padding: pagePadding(context),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (controller.polls.isEmpty)
              const EmptyState(
                icon: Icons.poll_outlined,
                title: 'Noch keine Abstimmungen',
                message: 'Offene Fragen an euer Ensemble erscheinen hier.',
              ),
            for (final closed in [false, true]) ...[
              if (controller.polls.any((p) => p.isClosed == closed))
                SectionTitle(closed ? 'Abgeschlossen' : 'Offen'),
              for (final p in controller.polls.where(
                (p) => p.isClosed == closed,
              ))
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(20),
                      title: Text(
                        p.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${p.totalVotes} Stimmen${p.selectedOptionId != null ? ' · Du hast abgestimmt' : ''}${p.closesAt == null ? '' : '\nBis ${DateFormat('d. MMMM · HH:mm', 'de').format(p.closesAt!.toLocal())}'}',
                        ),
                      ),
                      leading: Icon(
                        closed
                            ? Icons.check_circle_outline
                            : Icons.poll_outlined,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openPage(
                        context,
                        PollDetailScreen(controller: controller, pollId: p.id),
                      ),
                    ),
                  ),
                ),
            ],
            if (controller.user?.isAdmin == true)
              FilledButton.icon(
                onPressed: () =>
                    openPage(context, PollEditorScreen(controller: controller)),
                icon: const Icon(Icons.add),
                label: const Text('Abstimmung erstellen'),
              ),
          ],
        ),
      ),
    ),
  );
}

class PollDetailScreen extends StatefulWidget {
  const PollDetailScreen({
    super.key,
    required this.controller,
    required this.pollId,
  });
  final AppController controller;
  final String pollId;
  @override
  State<PollDetailScreen> createState() => _PollDetailScreenState();
}

class _PollDetailScreenState extends State<PollDetailScreen> {
  bool _busy = false;
  Future<void> _vote(String id) async {
    setState(() => _busy = true);
    try {
      await widget.controller.vote(widget.pollId, id);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final poll = widget.controller.polls
          .where((p) => p.id == widget.pollId)
          .firstOrNull;
      return Scaffold(
        appBar: AppBar(title: const Text('Abstimmung')),
        body: poll == null
            ? const Center(child: Text('Abstimmung nicht verfügbar.'))
            : ListView(
                padding: pagePadding(context),
                children: [
                  Text(
                    poll.title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  if (poll.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: SelectableText(poll.description),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    poll.isClosed
                        ? 'Abgeschlossen · ${poll.totalVotes} Stimmen'
                        : '${poll.totalVotes} Stimmen${poll.closesAt == null ? '' : ' · Bis ${DateFormat('d. MMMM · HH:mm', 'de').format(poll.closesAt!.toLocal())}'}',
                  ),
                  const SizedBox(height: 24),
                  for (final option in poll.options)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Card(
                        color: option.id == poll.selectedOptionId
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                        child: InkWell(
                          onTap: _busy || poll.isClosed
                              ? null
                              : () => _vote(option.id),
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      option.id == poll.selectedOptionId
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_off,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(child: Text(option.label)),
                                    const SizedBox(width: 12),
                                    Text('${option.votes}'),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                LinearProgressIndicator(
                                  value: poll.totalVotes == 0
                                      ? 0
                                      : option.votes / poll.totalVotes,
                                  borderRadius: BorderRadius.circular(8),
                                  minHeight: 5,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_busy) const LinearProgressIndicator(),
                  if (widget.controller.pendingCount > 0)
                    const Text(
                      'Deine Stimme wird synchronisiert, sobald eine Verbindung besteht.',
                    ),
                  if (widget.controller.user?.isAdmin == true) ...[
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: () => openPage(
                        context,
                        PollEditorScreen(
                          controller: widget.controller,
                          poll: poll,
                        ),
                      ),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Bearbeiten'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              try {
                                await widget.controller.performAction({
                                  'action': 'poll.close',
                                  'id': poll.id,
                                  'version': poll.version,
                                  'closed': !poll.isClosed,
                                });
                              } catch (e) {
                                if (context.mounted) showProblem(context, e);
                              }
                            },
                      child: Text(
                        poll.isClosed ? 'Wieder öffnen' : 'Abstimmung beenden',
                      ),
                    ),
                  ],
                ],
              ),
      );
    },
  );
}

class PollEditorScreen extends StatefulWidget {
  const PollEditorScreen({super.key, required this.controller, this.poll});
  final AppController controller;
  final Poll? poll;
  @override
  State<PollEditorScreen> createState() => _PollEditorScreenState();
}

class _PollEditorScreenState extends State<PollEditorScreen> {
  late final TextEditingController _title, _description;
  late final List<TextEditingController> _options;
  DateTime? _closes;
  bool _busy = false;
  final _form = GlobalKey<FormState>();
  bool get _fixed => (widget.poll?.totalVotes ?? 0) > 0;
  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.poll?.title);
    _description = TextEditingController(text: widget.poll?.description);
    _options =
        widget.poll?.options
            .map((o) => TextEditingController(text: o.label))
            .toList() ??
        [TextEditingController(), TextEditingController()];
    _closes = widget.poll?.closesAt?.toLocal();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'poll.save',
        'id': widget.poll?.id,
        'version': widget.poll?.version,
        'title': _title.text,
        'description': _description.text,
        'options': _options.map((o) => {'label': o.text}).toList(),
        'closesAt': _closes?.toUtc().toIso8601String(),
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
    title: widget.poll == null
        ? 'Abstimmung erstellen'
        : 'Abstimmung bearbeiten',
    children: (context) => [
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _title,
              maxLength: 250,
              decoration: const InputDecoration(labelText: 'Frage'),
              validator: (v) => v == null || v.trim().isEmpty
                  ? 'Bitte eine Frage eingeben.'
                  : null,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _description,
              minLines: 2,
              maxLines: 6,
              maxLength: 3000,
              decoration: const InputDecoration(labelText: 'Beschreibung'),
            ),
            const SectionTitle('Antworten'),
            for (var i = 0; i < _options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _options[i],
                        enabled: !_fixed && !_busy,
                        maxLength: 200,
                        decoration: InputDecoration(
                          labelText: 'Antwort ${i + 1}',
                        ),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Bitte eine Antwort eingeben.'
                            : null,
                      ),
                    ),
                    if (!_fixed && _options.length > 2)
                      IconButton(
                        tooltip: 'Antwort entfernen',
                        onPressed: _busy
                            ? null
                            : () {
                                final removed = _options[i];
                                setState(() => _options.removeAt(i));
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => removed.dispose(),
                                );
                              },
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
              ),
            if (!_fixed && _options.length < 12)
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () =>
                          setState(() => _options.add(TextEditingController())),
                icon: const Icon(Icons.add),
                label: const Text('Antwort hinzufügen'),
              ),
            if (_fixed)
              const Text(
                'Die Antworten bleiben nach der ersten Stimme erhalten.',
              ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Abstimmungsende'),
              subtitle: Text(
                _closes == null
                    ? 'Ohne Frist'
                    : DateFormat('d. MMMM yyyy · HH:mm', 'de').format(_closes!),
              ),
              trailing: _closes == null
                  ? const Icon(Icons.calendar_month)
                  : IconButton(
                      tooltip: 'Frist entfernen',
                      onPressed: () => setState(() => _closes = null),
                      icon: const Icon(Icons.close),
                    ),
              onTap: () async {
                final now = DateTime.now();
                final day = await showDatePicker(
                  context: context,
                  initialDate: _closes?.isAfter(now) == true
                      ? _closes!
                      : now.add(const Duration(days: 7)),
                  firstDate: now,
                  lastDate: DateTime(2100),
                );
                if (day == null || !context.mounted) return;
                final time = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.fromDateTime(
                    _closes ?? DateTime(2026, 1, 1, 20),
                  ),
                );
                if (time != null && mounted) {
                  setState(
                    () => _closes = DateTime(
                      day.year,
                      day.month,
                      day.day,
                      time.hour,
                      time.minute,
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Wird gespeichert …' : 'Speichern'),
            ),
          ],
        ),
      ),
    ],
  );
}
