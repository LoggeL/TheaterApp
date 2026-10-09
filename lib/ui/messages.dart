import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/identity.dart';
import 'admin.dart';
import 'audience.dart';
import 'profile.dart';
import 'theme.dart';

/// Short, relative time of a message or push, e.g. "Heute, 18:30".
String messageTime(DateTime date, DateTime now) {
  final local = date.toLocal(), today = DateUtils.dateOnly(now.toLocal());
  final days = today.difference(DateUtils.dateOnly(local)).inDays;
  final time = DateFormat('HH:mm', 'de').format(local);
  if (days == 0) return 'Heute, $time';
  if (days == 1) return 'Gestern, $time';
  if (days > 1 && days < 7) {
    return '${DateFormat('EEEE', 'de').format(local)}, $time';
  }
  return DateFormat(
    local.year == today.year ? 'd. MMMM' : 'd. MMMM y',
    'de',
  ).format(local);
}

/// Who a message or push goes to: everyone, or roles, production ensembles
/// and single people combined.
class Recipients {
  const Recipients({
    this.everyone = true,
    this.roleIds = const {},
    this.personIds = const {},
    this.productionIds = const {},
  });
  final bool everyone;
  final Set<String> roleIds, productionIds;
  final Set<int> personIds;

  bool get chosen =>
      everyone ||
      roleIds.isNotEmpty ||
      personIds.isNotEmpty ||
      productionIds.isNotEmpty;

  Recipients copyWith({
    bool? everyone,
    Set<String>? roleIds,
    Set<int>? personIds,
    Set<String>? productionIds,
  }) => Recipients(
    everyone: everyone ?? this.everyone,
    roleIds: roleIds ?? this.roleIds,
    personIds: personIds ?? this.personIds,
    productionIds: productionIds ?? this.productionIds,
  );

  List<TheaterMember> members(AppController controller) => controller
      .recipientsOf(roleIds, personIds, productionIds, everyone: everyone);

  JsonMap toJson() => {
    'audience': everyone ? 'all' : 'selected',
    'roleIds': everyone ? <String>[] : roleIds.toList(),
    'recipientPersonIds': everyone ? <int>[] : personIds.toList(),
    'productionIds': everyone ? <String>[] : productionIds.toList(),
  };
}

/// Chooses [Recipients] and shows how many people they reach.
class RecipientSelector extends StatelessWidget {
  const RecipientSelector({
    super.key,
    required this.controller,
    required this.value,
    required this.onChanged,
  });
  final AppController controller;
  final Recipients value;
  final ValueChanged<Recipients> onChanged;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reached = value.chosen ? value.members(controller).length : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: true,
              label: Text('Alle'),
              icon: Icon(Icons.groups_outlined),
            ),
            ButtonSegment(
              value: false,
              label: Text('Auswahl'),
              icon: Icon(Icons.tune),
            ),
          ],
          selected: {value.everyone},
          onSelectionChanged: (s) =>
              onChanged(value.copyWith(everyone: s.single)),
        ),
        if (!value.everyone) ...[
          const SizedBox(height: 18),
          AudiencePicker(
            controller: controller,
            label: 'An alle mit diesen Rollen',
            allowEveryone: false,
            selected: value.roleIds,
            onChanged: (ids) => onChanged(value.copyWith(roleIds: ids)),
          ),
          const SizedBox(height: 16),
          ProductionAudiencePicker(
            controller: controller,
            selected: value.productionIds,
            onChanged: (ids) => onChanged(value.copyWith(productionIds: ids)),
          ),
          const SizedBox(height: 16),
          PersonPicker(
            controller: controller,
            selected: value.personIds,
            onChanged: (ids) => onChanged(value.copyWith(personIds: ids)),
          ),
        ],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                value.chosen ? Icons.people_alt_outlined : Icons.info_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  !value.chosen
                      ? 'Bitte Rollen, Stücke und/oder Personen auswählen.'
                      : value.everyone
                      ? 'Erreicht alle $reached aktiven Personen.'
                      : 'Erreicht $reached ${reached == 1 ? 'Person' : 'Personen'}: '
                            '${controller.audienceLabel(value.roleIds, value.personIds, value.productionIds)}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({
    super.key,
    required this.controller,
    this.embedded = false,
  });
  final AppController controller;

  /// Shown as a main tab below the app bar instead of as its own page.
  final bool embedded;
  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  bool _unreadOnly = false;

  Future<void> _readAll() async {
    try {
      await widget.controller.performAction({'action': 'message.readAll'});
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller, admin = c.user?.isAdmin == true;
      final all = c.messages;
      final unread = all.where((m) => m['read'] != true).length;
      final shown = _unreadOnly
          ? all.where((m) => m['read'] != true).toList()
          : all;
      final today = DateUtils.dateOnly(c.now.toLocal());
      String section(JsonMap m) {
        final date = dateValue(m['createdAt'])?.toLocal();
        if (date == null) return 'Früher';
        final days = today.difference(DateUtils.dateOnly(date)).inDays;
        return days <= 0
            ? 'Heute'
            : days < 7
            ? 'Letzte 7 Tage'
            : 'Früher';
      }

      final children = <Widget>[];
      String? current;
      for (final m in shown) {
        final label = section(m);
        if (label != current) {
          current = label;
          children.add(
            Padding(
              padding: EdgeInsets.only(
                top: children.isEmpty ? 4 : 18,
                bottom: 10,
              ),
              child: Eyebrow(label),
            ),
          );
        }
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _MessageCard(controller: c, message: m, admin: admin),
          ),
        );
      }
      final readAll = IconButton(
        tooltip: 'Alle als gelesen markieren',
        onPressed: _readAll,
        icon: const Icon(Icons.done_all),
      );
      return Scaffold(
        appBar: widget.embedded
            ? null
            : AppBar(
                title: const Text('Mitteilungen'),
                actions: [if (unread > 0) readAll],
              ),
        floatingActionButton: admin
            ? FloatingActionButton.extended(
                tooltip: 'Mitteilung schreiben',
                onPressed: () =>
                    openPage(context, MessageComposerScreen(controller: c)),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Schreiben'),
              )
            : null,
        body: RefreshIndicator(
          onRefresh: c.refresh,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  20,
                  widget.embedded ? 20 : 14,
                  20,
                  96,
                ),
                children: [
                  if (widget.embedded)
                    PageHeader(
                      'Mitteilungen.',
                      subtitle: unread == 0
                          ? 'Nachrichten der Theaterleitung'
                          : unread == 1
                          ? '1 ungelesene Mitteilung'
                          : '$unread ungelesene Mitteilungen',
                      trailing: unread > 0 ? readAll : null,
                    ),
                  if (all.isNotEmpty) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<bool>(
                        segments: [
                          const ButtonSegment(
                            value: false,
                            label: Text('Alle'),
                          ),
                          ButtonSegment(
                            value: true,
                            label: Text(
                              unread == 0 ? 'Ungelesen' : 'Ungelesen · $unread',
                            ),
                          ),
                        ],
                        selected: {_unreadOnly},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) =>
                            setState(() => _unreadOnly = s.single),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (all.isEmpty)
                    EmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: 'Noch keine Mitteilungen',
                      message: admin
                          ? 'Schreib dem Ensemble eine Nachricht. Sie bleibt hier zum Nachlesen.'
                          : 'Nachrichten der Theaterleitung findest du hier.',
                    )
                  else if (shown.isEmpty)
                    const EmptyState(
                      icon: Icons.mark_email_read_outlined,
                      title: 'Alles gelesen',
                      message: 'Du bist auf dem neuesten Stand.',
                    ),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.controller,
    required this.message,
    required this.admin,
  });
  final AppController controller;
  final JsonMap message;
  final bool admin;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), m = message;
    final unread = m['read'] != true, date = dateValue(m['createdAt']);
    final author = controller.members
        .where((x) => x.id == intValue(m['authorId']))
        .firstOrNull;
    final recipients = jsonList(m['recipientIds']).length;
    final readers = jsonList(m['readerIds']).length;
    return Card(
      clipBehavior: Clip.antiAlias,
      color: unread
          ? theme.colorScheme.primaryContainer.withValues(alpha: .35)
          : null,
      child: InkWell(
        onTap: () => openPage(
          context,
          MessageDetailScreen(controller: controller, message: m),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Badge(
                isLabelVisible: unread,
                smallSize: 11,
                backgroundColor: StageTheme.orange,
                child: MemberAvatar(
                  controller: controller,
                  avatarId: author?.avatarId,
                  initials: author?.initials ?? '✉',
                  radius: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            textValue(m['title']),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: unread
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (date != null) ...[
                          const SizedBox(width: 10),
                          Text(
                            messageTime(date, controller.now),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: unread
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      textValue(m['body']),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          textValue(m['authorName']),
                          style: theme.textTheme.bodySmall,
                        ),
                        if (textValue(m['link']).isNotEmpty)
                          Icon(
                            Icons.link,
                            size: 16,
                            semanticLabel: 'Mit Link',
                            color: theme.colorScheme.outline,
                          ),
                        if (admin && m['audience'] != 'all')
                          _audience(controller, m),
                        if (admin && recipients > 0)
                          StatePill(
                            'Gelesen $readers/$recipients',
                            icon: Icons.visibility_outlined,
                            color: readers == recipients
                                ? StageTheme.green
                                : StageTheme.violet,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _audience(AppController controller, JsonMap m) => AudienceBadge(
  controller: controller,
  roleIds: [for (final id in jsonList(m['roleIds'])) id.toString()],
  personIds: jsonList(m['recipientPersonIds']).map(intValue).toList(),
  productionIds: [for (final id in jsonList(m['productionIds'])) id.toString()],
);

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
                  _audience(c, m),
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

class MessageComposerScreen extends StatefulWidget {
  const MessageComposerScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<MessageComposerScreen> createState() => _MessageComposerScreenState();
}

class _MessageComposerScreenState extends State<MessageComposerScreen> {
  final _title = TextEditingController(),
      _body = TextEditingController(),
      _link = TextEditingController(),
      _linkLabel = TextEditingController();
  bool _push = true, _busy = false;
  Recipients _to = const Recipients();
  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _link.dispose();
    _linkLabel.dispose();
    super.dispose();
  }

  String? get _linkError {
    final link = _link.text.trim();
    if (link.isEmpty) return null;
    final uri = Uri.tryParse(link);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty &&
            !link.contains(' ')
        ? null
        : 'Bitte einen vollständigen Link mit https:// angeben.';
  }

  bool get _ready =>
      _title.text.trim().isNotEmpty &&
      _body.text.trim().isNotEmpty &&
      _linkError == null &&
      _to.chosen;

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'message.send',
        'title': _title.text,
        'body': _body.text,
        'link': _link.text.trim(),
        'linkLabel': _linkLabel.text.trim(),
        ..._to.toJson(),
        'push': _push && widget.controller.pushConfigured,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.pendingCount > 0
                  ? 'Mitteilung zur Übertragung vorgemerkt.'
                  : 'Mitteilung veröffentlicht.',
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Mitteilung schreiben',
    children: (context) => [
      TextField(
        controller: _title,
        decoration: const InputDecoration(labelText: 'Betreff'),
        maxLength: 250,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _body,
        decoration: const InputDecoration(
          labelText: 'Nachricht',
          alignLabelWithHint: true,
        ),
        minLines: 7,
        maxLines: 18,
        maxLength: 10000,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 4),
      TextField(
        controller: _link,
        decoration: InputDecoration(
          labelText: 'Link (optional)',
          hintText: 'https://…',
          prefixIcon: const Icon(Icons.link),
          errorText: _linkError,
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
        maxLength: 2000,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        onChanged: (_) => setState(() {}),
      ),
      if (_link.text.trim().isNotEmpty) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _linkLabel,
          decoration: const InputDecoration(
            labelText: 'Beschriftung des Links (optional)',
            hintText: 'z. B. Zum Anmeldeformular',
          ),
          maxLength: 80,
          textCapitalization: TextCapitalization.sentences,
        ),
      ],
      const SectionTitle('Empfänger'),
      RecipientSelector(
        controller: widget.controller,
        value: _to,
        onChanged: (value) => setState(() => _to = value),
      ),
      const SizedBox(height: 16),
      SwitchListTile(
        value: _push && widget.controller.pushConfigured,
        onChanged: widget.controller.pushConfigured
            ? (v) => setState(() => _push = v)
            : null,
        title: const Text('Auch als Push benachrichtigen'),
        subtitle: Text(
          widget.controller.pushConfigured
              ? 'Die Mitteilung bleibt zusätzlich im Reiter Mitteilungen zum Nachlesen.'
              : 'Push ist noch nicht eingerichtet.',
        ),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _busy || !_ready ? null : _send,
        icon: const Icon(Icons.send_outlined),
        label: const Text('Mitteilung veröffentlichen'),
      ),
    ],
  );
}

class PushAdminScreen extends StatefulWidget {
  const PushAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<PushAdminScreen> createState() => _PushAdminScreenState();
}

class _PushAdminScreenState extends State<PushAdminScreen> {
  late Future<JsonMap> _data;
  final _title = TextEditingController(), _body = TextEditingController();
  Recipients _to = const Recipients();
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _data = widget.controller.remote('/admin/push');
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _reload() =>
      setState(() => _data = widget.controller.remote('/admin/push'));

  bool get _ready =>
      _title.text.trim().isNotEmpty &&
      _body.text.trim().isNotEmpty &&
      _to.chosen;

  Future<void> _send() async {
    final count = _to.members(widget.controller).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          count == 1
              ? 'Push an 1 Person senden?'
              : 'Push an $count Personen senden?',
        ),
        content: Text('„${_title.text.trim()}“\n${_body.text.trim()}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Senden'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'push.send',
        'title': _title.text,
        'body': _body.text,
        ..._to.toJson(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.pendingCount > 0
                ? 'Push zur Übertragung vorgemerkt.'
                : 'Push an $count ${count == 1 ? 'Person' : 'Personen'} wird versendet.',
          ),
        ),
      );
      _title.clear();
      _body.clear();
      _to = const Recipients();
      _reload();
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    try {
      await widget.controller.performAction({'action': 'push.test'});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Testbenachrichtigung für deine Geräte vorgemerkt.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, theme = Theme.of(context);
    return AdminPage(
      controller: c,
      title: 'Push senden',
      actions: [
        IconButton(
          tooltip: 'Aktualisieren',
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
      children: (context) => [
        const PageHeader(
          'Eigener Push',
          eyebrow: 'Sofort benachrichtigen',
          subtitle:
              'Für kurzfristige Hinweise wie „Probe beginnt 30 Minuten später“. '
              'Ein Push wird nicht gespeichert. Was man nachlesen können soll, gehört in eine Mitteilung.',
        ),
        if (!c.pushConfigured)
          const EmptyState(
            icon: Icons.notifications_off_outlined,
            title: 'Push ist noch nicht eingerichtet',
            message:
                'Sobald der Versand eingerichtet ist, kannst du hier Pushes senden.',
          )
        else ...[
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Titel'),
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _body,
            decoration: const InputDecoration(
              labelText: 'Text',
              alignLabelWithHint: true,
            ),
            minLines: 2,
            maxLines: 5,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          _PushPreview(title: _title.text, body: _body.text),
          const SectionTitle('Empfänger'),
          RecipientSelector(
            controller: c,
            value: _to,
            onChanged: (value) => setState(() => _to = value),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy || !_ready ? null : _send,
                icon: const Icon(Icons.send_outlined),
                label: const Text('Push senden'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    openPage(context, MessageComposerScreen(controller: c)),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Lieber Mitteilung schreiben'),
              ),
            ],
          ),
        ],
        const SectionTitle('Versand'),
        FutureBuilder<JsonMap>(
          future: _data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return EmptyState(
                icon: Icons.error_outline,
                title: 'Versandstatus nicht geladen',
                message: identityError(snapshot.error!),
              );
            }
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final data = snapshot.data!,
                configured = data['configured'] == true;
            final jobs = jsonList(data['jobs']).map(jsonMap).toList()
              ..sort(
                (a, b) => textValue(
                  b['createdAt'],
                ).compareTo(textValue(a['createdAt'])),
              );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatePill(
                          configured
                              ? 'Versand eingerichtet'
                              : 'Einrichtung ausstehend',
                          color: configured
                              ? StageTheme.green
                              : StageTheme.orange,
                        ),
                        Text(
                          '${jsonList(data['devices']).length} registrierte Geräte',
                          style: theme.textTheme.titleSmall,
                        ),
                        TextButton.icon(
                          onPressed: configured ? _test : null,
                          icon: const Icon(Icons.notifications_active_outlined),
                          label: const Text('Test an meine Geräte'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SectionTitle('Letzte Sendungen'),
                if (jobs.isEmpty)
                  const EmptyState(
                    icon: Icons.notifications_none,
                    title: 'Noch nichts gesendet',
                    message: 'Versendete Pushes erscheinen hier.',
                  ),
                for (final job in jobs) _JobTile(controller: c, job: job),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// How the push roughly looks on a phone's lock screen.
class _PushPreview extends StatelessWidget {
  const _PushPreview({required this.title, required this.body});
  final String title, body;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/brand/kolpingtheater-ramsen.png',
              width: 34,
              height: 34,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.theater_comedy, size: 34),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'THEATER-APP · JETZT',
                  style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1),
                ),
                const SizedBox(height: 2),
                Text(
                  title.trim().isEmpty ? 'Titel' : title.trim(),
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  body.trim().isEmpty
                      ? 'Text der Benachrichtigung'
                      : body.trim(),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.controller, required this.job});
  final AppController controller;
  final JsonMap job;
  @override
  Widget build(BuildContext context) {
    final (icon, color, status) = switch (job['status']) {
      'accepted_by_provider' => (
        Icons.check_circle_outline,
        StageTheme.green,
        'Zugestellt an Versanddienst',
      ),
      'no_devices' => (
        Icons.phonelink_off,
        Colors.grey,
        'Kein registriertes Gerät',
      ),
      'failed' => (Icons.error_outline, Colors.red, 'Versand fehlgeschlagen'),
      _ => (Icons.schedule, StageTheme.orange, 'Wartet auf Versand'),
    };
    final date = dateValue(job['createdAt']);
    final recipients = jsonList(job['recipientPersonIds']).length;
    final accepted = intValue(job['accepted']);
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(textValue(job['title'])),
        subtitle: Text(
          [
            if (date != null) messageTime(date, controller.now),
            if (job['manual'] == true) 'Eigener Push',
            status,
            if (recipients > 0)
              recipients == 1 ? 'an 1 Person' : 'an $recipients Personen',
            if (accepted > 0) accepted == 1 ? '1 Gerät' : '$accepted Geräte',
          ].join(' · '),
        ),
      ),
    );
  }
}
