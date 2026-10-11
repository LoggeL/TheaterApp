import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/member_avatar.dart';
import 'widgets/message_audience.dart';

class MessageTargetScreen extends StatefulWidget {
  const MessageTargetScreen({
    super.key,
    required this.controller,
    required this.messageId,
  });
  final AppController controller;
  final String messageId;
  @override
  State<MessageTargetScreen> createState() => _MessageTargetScreenState();
}

class _MessageTargetScreenState extends State<MessageTargetScreen> {
  late final Future<void> _loading = Future.microtask(
    widget.controller.refresh,
  );
  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _loading,
    builder: (context, snapshot) {
      final matches = widget.controller.messages.where(
        (m) => m['id'] == widget.messageId,
      );
      if (matches.isNotEmpty) {
        return MessageDetailScreen(
          controller: widget.controller,
          message: matches.first,
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Mitteilung')),
        body: snapshot.connectionState != ConnectionState.done
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(
                icon: Icons.mail_outline,
                title: 'Mitteilung nicht verfügbar',
                message:
                    'Die Mitteilung wurde entfernt oder ist für dein Konto nicht freigegeben.',
              ),
      );
    },
  );
}

class MessageDetailScreen extends StatefulWidget {
  const MessageDetailScreen({
    super.key,
    required this.controller,
    required this.message,
  });
  final AppController controller;
  final JsonMap message;
  @override
  State<MessageDetailScreen> createState() => _MessageDetailScreenState();
}

class _MessageDetailScreenState extends State<MessageDetailScreen> {
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.message['read'] != true) {
        widget.controller
            .performAction({
              'action': 'message.read',
              'id': widget.message['id'],
            })
            .catchError((Object e) {
              if (mounted) showProblem(context, e);
            });
      }
    });
  }

  /// The latest version from the snapshot, e.g. with fresh read receipts.
  JsonMap get _message =>
      widget.controller.messages
          .where((m) => m['id'] == widget.message['id'])
          .firstOrNull ??
      widget.message;

  Future<void> _remind(int open) async {
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'message.remind',
        'id': widget.message['id'],
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

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mitteilung löschen?'),
        content: const Text(
          'Die Mitteilung verschwindet für alle Empfänger. Das lässt sich nicht rückgängig machen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.controller.performAction({
        'action': 'message.delete',
        'id': widget.message['id'],
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Mitteilung gelöscht.')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller, m = _message, theme = Theme.of(context);
      final admin = c.user?.isAdmin == true, date = dateValue(m['createdAt']);
      final author = c.members
          .where((x) => x.id == intValue(m['authorId']))
          .firstOrNull;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Mitteilung'),
          actions: [
            if (admin)
              IconButton(
                tooltip: 'Mitteilung löschen',
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
              children: [
                Text(
                  textValue(m['title']),
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    MemberAvatar(
                      controller: c,
                      avatarId: author?.avatarId,
                      initials: author?.initials ?? '✉',
                      radius: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            textValue(m['authorName']),
                            style: theme.textTheme.titleSmall,
                          ),
                          if (date != null)
                            Text(
                              DateFormat(
                                'EEEE, d. MMMM y · HH:mm',
                                'de',
                              ).format(date.toLocal()),
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (m['audience'] != 'all') ...[
                  const SizedBox(height: 12),
                  messageAudience(c, m),
                ],
                const Divider(height: 40),
                SelectableText(
                  textValue(m['body']),
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                ),
                if (textValue(m['link']).isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _MessageLink(
                    link: textValue(m['link']),
                    label: textValue(m['linkLabel']),
                  ),
                ],
                if (admin && jsonList(m['recipientIds']).isNotEmpty) ...[
                  const SizedBox(height: 32),
                  _ReadStatus(
                    controller: c,
                    message: m,
                    busy: _busy,
                    onRemind: _remind,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Opens the message's web link outside the app.
class _MessageLink extends StatelessWidget {
  const _MessageLink({required this.link, required this.label});
  final String link, label;
  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(link);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.tonalIcon(
          onPressed: uri == null
              ? null
              : () async {
                  final opened = await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  );
                  if (!opened && context.mounted) {
                    showProblem(
                      context,
                      'Der Link konnte nicht geöffnet werden.',
                    );
                  }
                },
          icon: const Icon(Icons.open_in_new),
          label: Text(label.isEmpty ? 'Link öffnen' : label),
        ),
        const SizedBox(height: 6),
        SelectableText(
          uri?.host.isNotEmpty == true ? uri!.host : link,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _ReadStatus extends StatelessWidget {
  const _ReadStatus({
    required this.controller,
    required this.message,
    required this.busy,
    required this.onRemind,
  });
  final AppController controller;
  final JsonMap message;
  final bool busy;
  final ValueChanged<int> onRemind;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recipients = jsonList(message['recipientIds']).map(intValue).toSet();
    final readers = jsonList(message['readerIds']).map(intValue).toSet();
    String names(bool read) => controller.members
        .where(
          (m) => recipients.contains(m.id) && readers.contains(m.id) == read,
        )
        .map((m) => m.name)
        .join(', ');
    final open = recipients.length - readers.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.visibility_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Lesestatus', style: theme.textTheme.titleMedium),
                ),
                Text(
                  '${readers.length} von ${recipients.length} gelesen',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: recipients.isEmpty
                    ? 0
                    : readers.length / recipients.length,
                minHeight: 8,
              ),
            ),
            if (open > 0) ...[
              const SizedBox(height: 16),
              Text('Noch nicht gelesen', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(names(false), style: theme.textTheme.bodySmall),
            ],
            if (readers.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Gelesen', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(names(true), style: theme.textTheme.bodySmall),
            ],
            if (open > 0 && controller.pushConfigured) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: busy ? null : () => onRemind(open),
                icon: const Icon(Icons.notifications_active_outlined),
                label: Text(
                  open == 1
                      ? '1 Person per Push erinnern'
                      : '$open Personen per Push erinnern',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
