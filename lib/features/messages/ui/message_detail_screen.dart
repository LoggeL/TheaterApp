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
  // Listens to the controller so a message that arrives with a later sync
  // still replaces the placeholder.
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => FutureBuilder<void>(
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
    ),
  );
}

/// Messages already reminded about, per controller and thus per app session,
/// so nobody gets the same reminder twice.
final _reminded = Expando<Set<String>>('reminded messages');

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
            .then<void>(
              (_) {},
              onError: (Object e) {
                if (mounted) showProblem(context, e);
              },
            );
      }
    });
  }

  /// The latest version from the snapshot, e.g. with fresh read receipts.
  JsonMap get _message =>
      widget.controller.messages
          .where((m) => m['id'] == widget.message['id'])
          .firstOrNull ??
      widget.message;

  Set<String> get _remindedHere => _reminded[widget.controller] ??= <String>{};

  Future<void> _remind(int open, List<String> names) async {
    final people = open == 1 ? '1 Person' : '$open Personen';
    final confirmed = await confirmAction(
      context,
      title: '$people per Push erinnern?',
      message: names.isEmpty
          ? 'Alle, die die Mitteilung noch nicht gelesen haben, erhalten einen Push.'
          : 'Noch nicht gelesen ${names.length == 1 ? 'hat' : 'haben'}: ${names.join(', ')}.',
      confirmLabel: 'Erinnern',
      scrollable: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final outcome = await widget.controller.performAction({
        'action': 'message.remind',
        'id': widget.message['id'],
      });
      _remindedHere.add(textValue(widget.message['id']));
      if (mounted) {
        showDone(
          context,
          outcomeText(
            outcome,
            done: 'Erinnerung an $people gesendet.',
            queued: 'Erinnerung an $people vorgemerkt.',
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
    final confirmed = await confirmDestructive(
      context,
      title: 'Mitteilung löschen?',
      message:
          'Die Mitteilung verschwindet für alle Empfänger. Das lässt sich nicht rückgängig machen.',
      confirmLabel: 'Löschen',
    );
    if (!confirmed || !mounted) return;
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
                    reminded: _remindedHere.contains(textValue(m['id'])),
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
    required this.reminded,
    required this.onRemind,
  });
  final AppController controller;
  final JsonMap message;
  final bool busy;

  /// Already reminded in this session; the button stays disabled.
  final bool reminded;
  final void Function(int open, List<String> names) onRemind;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recipients = jsonList(message['recipientIds']).map(intValue).toSet();
    final readers = jsonList(message['readerIds']).map(intValue).toSet();
    List<String> names(bool read) => controller.members
        .where(
          (m) => recipients.contains(m.id) && readers.contains(m.id) == read,
        )
        .map((m) => m.name)
        .toList();
    final unreadNames = names(false), readNames = names(true);
    final open = recipients.length - readers.length;
    Widget chips(List<String> names) => Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final name in names)
          Chip(label: Text(name), visualDensity: VisualDensity.compact),
      ],
    );
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
              Text(
                'Noch nicht gelesen (${unreadNames.length})',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              chips(unreadNames),
            ],
            if (readers.isNotEmpty)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 4),
                  expandedAlignment: Alignment.centerLeft,
                  title: Text(
                    'Gelesen (${readNames.length})',
                    style: theme.textTheme.labelLarge,
                  ),
                  children: [chips(readNames)],
                ),
              ),
            if (open > 0 && controller.pushConfigured) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: busy || reminded
                    ? null
                    : () => onRemind(open, unreadNames),
                icon: Icon(
                  reminded ? Icons.check : Icons.notifications_active_outlined,
                ),
                label: Text(
                  reminded
                      ? 'Erinnerung gesendet'
                      : open == 1
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
