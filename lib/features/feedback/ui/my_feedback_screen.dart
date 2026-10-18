import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../messages/ui/messages_screen.dart' show messageTime;
import '../data/feedback_api.dart';
import '../domain/feedback_ticket.dart';
import 'feedback_pills.dart';
import 'feedback_ticket_screen.dart';

/// The member's own feedback with status and answers of the Theaterleitung.
class MyFeedbackScreen extends StatefulWidget {
  const MyFeedbackScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<MyFeedbackScreen> createState() => _MyFeedbackScreenState();
}

class _MyFeedbackScreenState extends State<MyFeedbackScreen> {
  List<FeedbackTicket>? _tickets;
  Object? _loadError;
  bool _loading = true;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!feedbackTicketsAvailable(controller)) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final tickets = await loadOwnFeedback(controller);
      if (!mounted) return;
      setState(() {
        _tickets = tickets;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_tickets != null) showProblem(context, e);
      setState(() => _loadError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(FeedbackTicket ticket) async {
    await openPage<void>(
      context,
      FeedbackTicketScreen(
        controller: controller,
        ticketId: ticket.id,
        initial: ticket,
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final supported = feedbackTicketsAvailable(controller);
    final tickets = _tickets;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mein Feedback'),
        actions: [
          if (supported)
            IconButton(
              tooltip: 'Aktualisieren',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: pagePadding(context),
          children: [
            const PageHeader(
              'Mein Feedback',
              subtitle:
                  'Was du geschickt hast, mit den Antworten der Theaterleitung.',
            ),
            if (!supported)
              const EmptyState(
                icon: Icons.update,
                title: 'Noch nicht verfügbar',
                message:
                    'Dein Feedback kommt weiterhin an. Antworten und den '
                    'Verlauf zeigt die App, sobald der Server aktualisiert ist.',
              )
            else if (tickets == null && _loadError != null)
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
            else if (tickets == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (tickets.isEmpty)
              const EmptyState(
                icon: Icons.feedback_outlined,
                title: 'Noch kein Feedback',
                message:
                    'Was du unter „Feedback geben“ schickst, erscheint hier '
                    'mit den Antworten der Theaterleitung.',
              )
            else
              for (final ticket in tickets)
                _TicketCard(
                  key: ValueKey('my-feedback-${ticket.id}'),
                  ticket: ticket,
                  now: controller.now,
                  onTap: () => _open(ticket),
                ),
          ],
        ),
      ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({
    super.key,
    required this.ticket,
    required this.now,
    required this.onTap,
  });
  final FeedbackTicket ticket;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = ticket.lastActivityAt;
    final answer = ticket.lastAdminMessage;
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
                  feedbackCategoryPill(context, ticket.category),
                  feedbackStatusPill(ticket, admin: false),
                  if (ticket.unread > 0)
                    StatePill(
                      ticket.unread == 1
                          ? 'Neue Antwort'
                          : '${ticket.unread} neue Antworten',
                      color: StageTheme.violet,
                      icon: Icons.mark_unread_chat_alt_outlined,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                ticket.message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: ticket.unread > 0 ? FontWeight.w600 : null,
                ),
              ),
              if (answer != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Antwort: ${answer.text}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                [
                  if (at != null) messageTime(at, now),
                  ticket.messages.length == 1
                      ? '1 Nachricht'
                      : '${ticket.messages.length} Nachrichten',
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
