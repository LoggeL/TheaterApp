import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../../shared/widgets/visible_listenable_builder.dart';
import '../domain/message_selectors.dart';
import 'message_composer_screen.dart';
import 'message_detail_screen.dart';
import 'widgets/message_audience.dart';

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

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({
    super.key,
    required this.controller,
    this.embedded = false,
    this.switcher,
    this.floatingActionButton,
  });
  final AppController controller;

  /// Shown as a main tab below the app bar instead of as its own page.
  final bool embedded;

  /// Shown below the header, e.g. to switch to the polls.
  final Widget? switcher;

  /// Replaces the own compose button, e.g. by the shared one of the tab.
  final Widget? floatingActionButton;
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
  Widget build(BuildContext context) => VisibleListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, admin = c.user?.isAdmin == true;
      final all = c.messages;
      final unread = unreadMessageCount(c);
      final shown = _unreadOnly ? unreadMessages(c).toList() : all;
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
        floatingActionButton:
            widget.floatingActionButton ??
            (admin
                ? FloatingActionButton.extended(
                    tooltip: 'Mitteilung schreiben',
                    onPressed: () =>
                        openPage(context, MessageComposerScreen(controller: c)),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Schreiben'),
                  )
                : null),
        body: RefreshIndicator(
          onRefresh: () => refreshWithFeedback(context, c),
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
                  if (widget.switcher != null) ...[
                    widget.switcher!,
                    const SizedBox(height: 14),
                  ],
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
    final unread = messageUnreadFor(controller.user, m);
    final date = dateValue(m['createdAt']);
    // Admins also see messages to others; those stay in the background.
    final forOthers = !messageAddressedTo(controller.user, m);
    final author = controller.members
        .where((x) => x.id == intValue(m['authorId']))
        .firstOrNull;
    final recipients = jsonList(m['recipientIds']).length;
    final readers = jsonList(m['readerIds']).length;
    final card = Card(
      clipBehavior: Clip.antiAlias,
      color: unread
          ? theme.colorScheme.primaryContainer.withValues(alpha: .35)
          : forOthers
          ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5)
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
                              color: forOthers
                                  ? theme.colorScheme.onSurfaceVariant
                                  : null,
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
                        if (forOthers)
                          StatePill(
                            'Nicht an dich',
                            color: theme.colorScheme.outline,
                          ),
                        if (admin && m['audience'] != 'all')
                          messageAudience(controller, m),
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
    return Semantics(
      label: unread ? 'Ungelesen' : null,
      container: true,
      child: card,
    );
  }
}
