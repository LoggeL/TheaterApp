import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../data/api_client.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../messages/ui/messages_screen.dart' show messageTime;
import '../data/feedback_api.dart';
import '../domain/feedback_ticket.dart';
import 'feedback_pills.dart';

/// One feedback ticket with its conversation, an answer field and closing.
///
/// [admin] shows the admins' side (any ticket, answers as Theaterleitung);
/// otherwise the author's side of their own ticket.
class FeedbackTicketScreen extends StatefulWidget {
  const FeedbackTicketScreen({
    super.key,
    required this.controller,
    required this.ticketId,
    this.admin = false,
    this.initial,
  });
  final AppController controller;
  final String ticketId;
  final bool admin;

  /// Shown at once while the current state loads.
  final FeedbackTicket? initial;

  @override
  State<FeedbackTicketScreen> createState() => _FeedbackTicketScreenState();
}

class _FeedbackTicketScreenState extends State<FeedbackTicketScreen> {
  final _reply = TextEditingController();
  FeedbackTicket? _ticket;
  Object? _loadError;
  bool _loading = true, _sending = false, _updating = false;

  AppController get controller => widget.controller;
  bool get _tickets => feedbackTicketsAvailable(controller);

  @override
  void initState() {
    super.initState();
    _ticket = widget.initial;
    _load();
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Servers before the tickets have no single-ticket view; the list's copy
    // is all there is.
    if (!_tickets) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      var ticket = widget.admin
          ? await loadAdminTicket(controller, widget.ticketId)
          : await loadOwnTicket(controller, widget.ticketId);
      if (!mounted) return;
      setState(() {
        _ticket = ticket;
        _loadError = null;
      });
      if (!widget.admin && ticket.unread > 0) {
        try {
          ticket = await markOwnFeedbackRead(controller, ticket);
          if (mounted) setState(() => _ticket = ticket);
        } catch (_) {
          // Stays marked as new; the next visit tries again.
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (_ticket != null) showProblem(context, e);
      setState(() => _loadError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _text => _reply.text.trim();

  bool get _canSend =>
      _tickets &&
      !_sending &&
      !controller.isOffline &&
      _text.isNotEmpty &&
      _text.length <= feedbackMaxLength;

  bool _conflict(Object e) =>
      e is ApiException &&
      (e.code == 'version_conflict' || (e.statusCode == 409 && e.code == null));

  Future<void> _send() async {
    final ticket = _ticket;
    if (ticket == null) return;
    setState(() => _sending = true);
    try {
      final updated = widget.admin
          ? await answerFeedback(controller, ticket, _text)
          : await replyToOwnFeedback(controller, ticket, _text);
      if (!mounted) return;
      setState(() {
        _ticket = updated;
        _reply.clear();
      });
      showDone(
        context,
        widget.admin
            ? 'Antwort gesendet.'
            : ticket.closed
            ? 'Nachricht gesendet, das Feedback ist wieder offen.'
            : 'Nachricht gesendet.',
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _setClosed(bool closed) async {
    final ticket = _ticket;
    if (ticket == null) return;
    setState(() => _updating = true);
    try {
      final updated = widget.admin
          ? await setFeedbackClosed(controller, ticket, closed: closed)
          : await closeOwnFeedback(controller, ticket);
      if (!mounted) return;
      setState(() => _ticket = updated);
      showDone(
        context,
        closed ? 'Feedback geschlossen.' : 'Feedback wieder geöffnet.',
      );
    } catch (e) {
      if (!mounted) return;
      if (_conflict(e)) {
        showProblem(
          context,
          'Dieses Feedback wurde inzwischen geändert. Es wurde neu geladen.',
        );
        await _load();
      } else {
        showProblem(context, e);
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => DiscardGuard(
      dirty: !_sending && _text.isNotEmpty,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.admin ? 'Feedback' : 'Mein Feedback'),
          actions: [
            if (_tickets)
              IconButton(
                tooltip: 'Aktualisieren',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        body: _body(context),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    final ticket = _ticket;
    if (ticket == null && _loadError != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Feedback nicht geladen',
        message: userMessage(_loadError!),
        action: OutlinedButton.icon(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Erneut versuchen'),
        ),
      );
    }
    if (ticket == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    final date = ticket.createdAt;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: pagePadding(context, top: 16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              feedbackCategoryPill(context, ticket.category),
              feedbackStatusPill(ticket, admin: widget.admin),
            ],
          ),
          const SizedBox(height: 10),
          if (widget.admin) ...[
            Text(
              [
                ticket.authorName.isEmpty ? 'Unbekannt' : ticket.authorName,
                if (date != null) messageTime(date, controller.now),
              ].join(' · '),
              style: theme.textTheme.titleSmall,
            ),
            if (ticket.appVersion.isNotEmpty || ticket.platform.isNotEmpty)
              Text(
                [
                  if (ticket.appVersion.isNotEmpty)
                    'Version ${ticket.appVersion}',
                  if (ticket.platform.isNotEmpty)
                    feedbackPlatformLabel(ticket.platform),
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
          ] else if (date != null)
            Text(
              'Gesendet ${messageTime(date, controller.now)}',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          for (final message in ticket.messages)
            _Bubble(
              key: ValueKey('feedback-message-${message.id}'),
              message: message,
              own: message.fromAdmin == widget.admin,
              label: _author(ticket, message),
              time: message.at == null
                  ? ''
                  : messageTime(message.at!, controller.now),
            ),
          if (ticket.closed) _closedNote(context, ticket),
          const SizedBox(height: 8),
          ..._compose(context, ticket),
          const SizedBox(height: 20),
          ..._closing(context, ticket),
        ],
      ),
    );
  }

  String _author(FeedbackTicket ticket, FeedbackMessage message) {
    if (!message.fromAdmin) {
      if (!widget.admin) return 'Du';
      return ticket.authorName.isEmpty ? 'Unbekannt' : ticket.authorName;
    }
    // Admins see which of them answered; members see it, too.
    final name = message.authorName;
    if (widget.admin) return name.isEmpty ? 'Theaterleitung' : name;
    return name.isEmpty ? 'Theaterleitung' : 'Theaterleitung · $name';
  }

  Widget _closedNote(BuildContext context, FeedbackTicket ticket) {
    final theme = Theme.of(context);
    final at = ticket.closedAt;
    final by = ticket.closedByAdmin
        ? (ticket.closedByName.isEmpty
              ? 'der Theaterleitung'
              : ticket.closedByName)
        : (widget.admin
              ? (ticket.authorName.isEmpty ? 'dem Mitglied' : ticket.authorName)
              : 'dir');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline, color: StageTheme.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                'Geschlossen von $by',
                if (at != null) messageTime(at, controller.now),
              ].join(' · '),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _compose(BuildContext context, FeedbackTicket ticket) {
    final theme = Theme.of(context);
    if (!_tickets) {
      return [
        Text(
          'Antworten auf Feedback gibt es nach dem nächsten Server-Update.',
          style: theme.textTheme.bodySmall,
        ),
      ];
    }
    return [
      TextField(
        key: const ValueKey('feedback-reply'),
        controller: _reply,
        enabled: !_sending,
        decoration: InputDecoration(
          labelText: widget.admin ? 'Antwort' : 'Deine Nachricht',
          alignLabelWithHint: true,
          hintText: widget.admin
              ? 'Was möchtest du antworten?'
              : 'Eine Rückfrage oder Ergänzung?',
        ),
        minLines: 2,
        maxLines: 8,
        maxLength: feedbackMaxLength,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
      ),
      if (!widget.admin && ticket.closed)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Wenn du noch einmal schreibst, wird dein Feedback wieder geöffnet.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: _canSend ? _send : null,
          icon: _sending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_outlined),
          label: Text(
            _sending
                ? 'Wird gesendet …'
                : widget.admin
                ? 'Antworten'
                : 'Nachricht senden',
          ),
        ),
      ),
      if (widget.admin)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${ticket.authorName.isEmpty ? 'Das Mitglied' : ticket.authorName} '
            'bekommt deine Antwort als Push und sieht deinen Namen.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (controller.isOffline)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Zum Senden wird eine Verbindung zum Server benötigt.',
            style: theme.textTheme.bodySmall,
          ),
        ),
    ];
  }

  List<Widget> _closing(BuildContext context, FeedbackTicket ticket) {
    final theme = Theme.of(context);
    final busy = _updating || controller.isOffline;
    if (ticket.closed) {
      if (!widget.admin) return const [];
      return [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: busy ? null : () => _setClosed(false),
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('Wieder öffnen'),
          ),
        ),
      ];
    }
    // Older servers do not require an answer before closing.
    final canClose = _tickets ? ticket.canClose : true;
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('feedback-close'),
          onPressed: busy || !canClose ? null : () => _setClosed(true),
          icon: const Icon(Icons.check, size: 18),
          label: Text(
            widget.admin ? 'Feedback schließen' : 'Erledigt, schließen',
          ),
        ),
      ),
      if (!canClose)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            widget.admin
                ? 'Schließen geht erst, nachdem die Theaterleitung '
                      'geantwortet hat.'
                : 'Schließen geht, sobald die Theaterleitung geantwortet hat.',
            style: theme.textTheme.bodySmall,
          ),
        ),
    ];
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.message,
    required this.own,
    required this.label,
    required this.time,
  });
  final FeedbackMessage message;

  /// Written from the viewer's side; shown on the right.
  final bool own;
  final String label, time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: own
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [label, if (time.isNotEmpty) time].join(' · '),
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              SelectableText(message.text, style: theme.textTheme.bodyLarge),
            ],
          ),
        ),
      ),
    );
  }
}
