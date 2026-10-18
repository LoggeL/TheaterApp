import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../data/api_client.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../messages/ui/messages_screen.dart' show messageTime;
import '../data/feedback_api.dart';
import '../domain/feedback_entry.dart';
import 'feedback_category_icon.dart';

/// The members' feedback for the admins, newest first, to be marked as done.
class FeedbackAdminScreen extends StatefulWidget {
  const FeedbackAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<FeedbackAdminScreen> createState() => _FeedbackAdminScreenState();
}

class _FeedbackAdminScreenState extends State<FeedbackAdminScreen> {
  // The last loaded list stays visible while a reload runs.
  List<FeedbackEntry>? _entries;
  Object? _loadError;
  bool _loading = true;
  String _filter = 'new';
  final _updating = <String>{};

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _load() {
    setState(() => _loading = true);
    return _fetch();
  }

  /// Loads the list; a failure keeps the previous entries and is reported.
  Future<void> _fetch() async {
    try {
      final entries = await loadFeedback(widget.controller);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_entries != null) showProblem(context, e);
      setState(() => _loadError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setDone(FeedbackEntry entry, bool done) async {
    if (!mounted) return;
    setState(() => _updating.add(entry.id));
    try {
      final updated = await setFeedbackDone(
        widget.controller,
        entry,
        done: done,
      );
      if (!mounted) return;
      setState(() {
        _entries = [
          for (final e in _entries ?? const <FeedbackEntry>[])
            e.id == updated.id ? updated : e,
        ];
      });
      showDone(
        context,
        done ? 'Als erledigt markiert.' : 'Wieder als offen markiert.',
        actionLabel: 'Rückgängig',
        onAction: () => _setDone(updated, !done),
      );
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException &&
          (e.statusCode == 409 || e.code == 'version_conflict')) {
        showProblem(
          context,
          'Dieses Feedback wurde inzwischen geändert. Die Liste wurde neu geladen.',
        );
        await _load();
      } else {
        showProblem(context, e);
      }
    } finally {
      if (mounted) setState(() => _updating.remove(entry.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final open = entries?.where((e) => !e.done).length ?? 0;
    final done = (entries?.length ?? 0) - open;
    final shown = [
      for (final e in entries ?? const <FeedbackEntry>[])
        if (_filter == 'all' || e.done == (_filter == 'done')) e,
    ];
    return AdminPage(
      controller: widget.controller,
      title: 'Feedback',
      onRefresh: _load,
      actions: [
        IconButton(
          tooltip: 'Aktualisieren',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      children: (context) => [
        if (entries == null && _loadError != null)
          EmptyState(
            icon: Icons.error_outline,
            title: 'Feedback nicht geladen',
            message: userMessage(_loadError!),
            action: OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut versuchen'),
            ),
          )
        else if (entries == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (value, label) in [
                ('new', 'Offen ($open)'),
                ('done', 'Erledigt ($done)'),
                ('all', 'Alle (${entries.length})'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _filter == value,
                  onSelected: (_) => setState(() => _filter = value),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (shown.isEmpty)
            EmptyState(
              icon: Icons.feedback_outlined,
              title: entries.isEmpty
                  ? 'Noch kein Feedback'
                  : _filter == 'new'
                  ? 'Alles erledigt'
                  : 'Nichts in dieser Ansicht',
              message: entries.isEmpty
                  ? 'Was Mitglieder unter „Mein Bereich“ › „Feedback geben“ '
                        'senden, erscheint hier.'
                  : _filter == 'new'
                  ? 'Es gibt kein offenes Feedback. Bearbeitetes findest du unter „Erledigt“.'
                  : 'Wähle oben eine andere Ansicht.',
            ),
          for (final entry in shown)
            _FeedbackCard(
              key: ValueKey('feedback-${entry.id}'),
              controller: widget.controller,
              entry: entry,
              busy: _updating.contains(entry.id),
              onToggle: () => _setDone(entry, !entry.done),
            ),
        ],
      ],
    );
  }
}

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({
    super.key,
    required this.controller,
    required this.entry,
    required this.busy,
    required this.onToggle,
  });
  final AppController controller;
  final FeedbackEntry entry;
  final bool busy;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = entry.createdAt;
    final categoryColor = switch (entry.category) {
      'bug' => theme.colorScheme.error,
      'idea' => StageTheme.violet,
      _ => theme.colorScheme.outline,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                StatePill(
                  feedbackCategoryLabel(entry.category),
                  color: categoryColor,
                  icon: feedbackCategoryIcon(entry.category),
                ),
                entry.done
                    ? const StatePill('Erledigt', color: StageTheme.green)
                    : const StatePill('Offen', color: StageTheme.orange),
              ],
            ),
            const SizedBox(height: 10),
            SelectableText(entry.message, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 10),
            Text(
              [
                entry.authorName.isEmpty ? 'Unbekannt' : entry.authorName,
                if (date != null) messageTime(date, controller.now),
              ].join(' · '),
              style: theme.textTheme.titleSmall,
            ),
            if (entry.appVersion.isNotEmpty || entry.platform.isNotEmpty)
              Text(
                [
                  if (entry.appVersion.isNotEmpty)
                    'Version ${entry.appVersion}',
                  if (entry.platform.isNotEmpty)
                    feedbackPlatformLabel(entry.platform),
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: busy ? null : onToggle,
                icon: Icon(entry.done ? Icons.undo : Icons.check, size: 18),
                label: Text(
                  entry.done ? 'Wieder öffnen' : 'Als erledigt markieren',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
