import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../messages/ui/messages_screen.dart' show messageTime;
import '../data/feedback_api.dart';
import '../domain/feedback_ticket.dart';
import 'feedback_category_icon.dart';
import 'feedback_pills.dart';
import 'feedback_ticket_screen.dart';

/// All members' feedback tickets for the admins, filtered by status and
/// kind; new and unanswered ones are marked.
class FeedbackAdminScreen extends StatefulWidget {
  const FeedbackAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<FeedbackAdminScreen> createState() => _FeedbackAdminScreenState();
}

class _FeedbackAdminScreenState extends State<FeedbackAdminScreen> {
  // The last loaded list stays visible while a reload runs.
  List<FeedbackTicket>? _entries;
  Object? _loadError;
  bool _loading = true;
  FeedbackStatus? _status = FeedbackStatus.open;
  String? _category;

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

  Future<void> _open(FeedbackTicket ticket) async {
    await openPage<void>(
      context,
      FeedbackTicketScreen(
        controller: widget.controller,
        ticketId: ticket.id,
        admin: true,
        initial: ticket,
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final ofKind = [
      for (final e in entries ?? const <FeedbackTicket>[])
        if (_category == null || e.category == _category) e,
    ];
    int count(FeedbackStatus status) =>
        ofKind.where((e) => e.status == status).length;
    final fresh = ofKind.where((e) => e.isNew).length;
    final shown = [
      for (final e in ofKind)
        if (_status == null || e.status == _status) e,
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
          if (fresh > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                fresh == 1
                    ? '1 neues Feedback ist noch unbeantwortet.'
                    : '$fresh neue Feedbacks sind noch unbeantwortet.',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (value, label) in [
                (FeedbackStatus.open, 'Offen'),
                (FeedbackStatus.answered, 'Wartet auf Rückmeldung'),
                (FeedbackStatus.closed, 'Geschlossen'),
              ])
                ChoiceChip(
                  label: Text('$label (${count(value)})'),
                  selected: _status == value,
                  onSelected: (_) => setState(() => _status = value),
                ),
              ChoiceChip(
                label: Text('Alle (${ofKind.length})'),
                selected: _status == null,
                onSelected: (_) => setState(() => _status = null),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('Alle Arten'),
                selected: _category == null,
                onSelected: (_) => setState(() => _category = null),
              ),
              for (final category in feedbackCategories)
                FilterChip(
                  avatar: Icon(feedbackCategoryIcon(category), size: 18),
                  label: Text(feedbackCategoryLabel(category)),
                  selected: _category == category,
                  onSelected: (_) => setState(
                    () => _category = _category == category ? null : category,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (shown.isEmpty)
            EmptyState(
              icon: Icons.feedback_outlined,
              title: entries.isEmpty
                  ? 'Noch kein Feedback'
                  : _status == FeedbackStatus.open
                  ? 'Alles beantwortet'
                  : 'Nichts in dieser Ansicht',
              message: entries.isEmpty
                  ? 'Was Mitglieder unter „Mein Bereich“ › „Feedback geben“ '
                        'senden, erscheint hier.'
                  : _status == FeedbackStatus.open
                  ? 'Kein Feedback wartet auf eine Antwort.'
                  : 'Wähle oben eine andere Ansicht.',
            ),
          for (final entry in shown)
            _FeedbackCard(
              key: ValueKey('feedback-${entry.id}'),
              controller: widget.controller,
              entry: entry,
              onTap: () => _open(entry),
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
    required this.onTap,
  });
  final AppController controller;
  final FeedbackTicket entry;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = entry.lastActivityAt;
    final answer = entry.lastAdminMessage;
    final waiting = entry.status == FeedbackStatus.open;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  feedbackCategoryPill(context, entry.category),
                  feedbackStatusPill(entry, admin: true),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                entry.message,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: waiting ? FontWeight.w600 : null,
                ),
              ),
              if (entry.messages.length > 1 && !entry.messages.last.fromAdmin)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Zuletzt: ${entry.messages.last.text}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                [
                  entry.authorName.isEmpty ? 'Unbekannt' : entry.authorName,
                  if (date != null) messageTime(date, controller.now),
                ].join(' · '),
                style: theme.textTheme.titleSmall,
              ),
              Text(
                [
                  entry.messages.length == 1
                      ? '1 Nachricht'
                      : '${entry.messages.length} Nachrichten',
                  if (answer != null)
                    'Antwort von ${answer.authorName.isEmpty ? 'Theaterleitung' : answer.authorName}',
                  if (entry.appVersion.isNotEmpty)
                    'Version ${entry.appVersion}',
                  if (entry.platform.isNotEmpty)
                    feedbackPlatformLabel(entry.platform),
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
