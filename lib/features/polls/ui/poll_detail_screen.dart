import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/audience/audience_pickers.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../domain/poll_selectors.dart';
import 'poll_editor_screen.dart';
import 'widgets/poll_updates.dart';

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
      final outcome = await widget.controller.vote(widget.pollId, id);
      if (mounted) {
        showDone(
          context,
          outcomeText(
            outcome,
            done: 'Stimme gespeichert',
            queued: 'Stimme vorgemerkt – wird bei Verbindung gesendet',
          ),
        );
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ends voting now, or opens it again without a deadline.
  Future<void> _setClosed(Poll poll, bool closed) async {
    final confirmed = closed
        ? await confirmDestructive(
            context,
            title: 'Abstimmung beenden?',
            message:
                'Danach kann niemand mehr abstimmen. Du kannst sie später wieder öffnen.',
            confirmLabel: 'Beenden',
          )
        : await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Abstimmung wieder öffnen?'),
                  content: const Text(
                    'Die Frist wird entfernt. Alle können wieder abstimmen, bis du sie beendest.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Abbrechen'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Wieder öffnen'),
                    ),
                  ],
                ),
              ) ==
              true;
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final outcome = await widget.controller.performAction({
        'action': 'poll.close',
        'id': poll.id,
        'version': poll.version,
        'closed': closed,
      });
      if (mounted) {
        showDone(
          context,
          outcomeText(
            outcome,
            done: closed ? 'Abstimmung beendet' : 'Abstimmung wieder geöffnet',
            queued: closed
                ? 'Beenden vorgemerkt – wird bei Verbindung gesendet'
                : 'Wiedereröffnung vorgemerkt – wird bei Verbindung gesendet',
          ),
        );
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PollUpdates(
    controller: widget.controller,
    builder: (context, _) {
      final c = widget.controller, theme = Theme.of(context);
      final poll = c.polls.where((p) => p.id == widget.pollId).firstOrNull;
      final admin = c.user?.isAdmin == true;
      final closed = poll?.isClosedAt(c.now) ?? true;
      final canVote = poll != null && !closed && pollAddressesUser(c, poll);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Abstimmung'),
          actions: [
            if (admin && poll != null) ...[
              IconButton(
                tooltip: 'Abstimmung bearbeiten',
                onPressed: () => openPage(
                  context,
                  PollEditorScreen(controller: c, poll: poll),
                ),
                icon: const Icon(Icons.edit_outlined),
              ),
              PopupMenuButton<bool>(
                tooltip: 'Weitere Aktionen',
                enabled: !_busy,
                onSelected: (value) => _setClosed(poll, value),
                itemBuilder: (context) => [
                  closed
                      ? const PopupMenuItem(
                          value: false,
                          child: ListTile(
                            leading: Icon(Icons.lock_open_outlined),
                            title: Text('Wieder öffnen'),
                          ),
                        )
                      : const PopupMenuItem(
                          value: true,
                          child: ListTile(
                            leading: Icon(Icons.stop_circle_outlined),
                            title: Text('Beenden'),
                          ),
                        ),
                ],
              ),
            ],
          ],
        ),
        body: poll == null
            ? const EmptyState(
                icon: Icons.poll_outlined,
                title: 'Abstimmung nicht verfügbar',
                message:
                    'Die Abstimmung wurde entfernt oder ist für dein Konto nicht freigegeben.',
              )
            : ListView(
                padding: pagePadding(context),
                children: [
                  Text(poll.title, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        poll.anonymous
                            ? Icons.visibility_off_outlined
                            : Icons.people_outline,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(poll.privacyLabel),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    poll.anonymous
                        ? 'Die Antworten werden ohne Namen angezeigt.'
                        : 'Alle Mitglieder sehen, wer welche Antwort gewählt hat.',
                  ),
                  if (poll.hasAudience) ...[
                    const SizedBox(height: 8),
                    AudienceBadge(
                      controller: c,
                      roleIds: poll.roleIds,
                      personIds: poll.personIds,
                      productionIds: poll.productionIds,
                    ),
                  ],
                  if (poll.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: SelectableText(poll.description),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    closed
                        ? 'Abgeschlossen · ${poll.voteCountLabel}'
                        : '${poll.voteCountLabel}${poll.closesAt == null ? '' : ' · Bis ${DateFormat('d. MMMM · HH:mm', 'de').format(poll.closesAt!.toLocal())}'}',
                  ),
                  if (canVote) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Du kannst deine Stimme bis zum Ende ändern.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ] else if (!closed) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Diese Abstimmung richtet sich nicht an dich.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 24),
                  for (final option in poll.options)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _OptionCard(
                        poll: poll,
                        option: option,
                        onTap: _busy || !canVote
                            ? null
                            : () => _vote(option.id),
                      ),
                    ),
                  if (_busy) const LinearProgressIndicator(),
                  if (c.outbox.any(
                    (action) =>
                        !action.failed &&
                        action.payload['action'] == 'poll.vote' &&
                        action.payload['pollId'] == poll.id,
                  ))
                    const Text(
                      'Deine Stimme wird synchronisiert, sobald eine Verbindung besteht.',
                    ),
                ],
              ),
      );
    },
  );
}

/// One answer with its share of the votes, announced as a radio button.
class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.poll, required this.option, this.onTap});
  final Poll poll;
  final PollOption option;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final selected = option.id == poll.selectedOptionId;
    final votes = option.votes == 1 ? '1 Stimme' : '${option.votes} Stimmen';
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: onTap != null,
      button: true,
      label: '${option.label}, $votes',
      excludeSemantics: true,
      onTap: onTap,
      child: Card(
        color: selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(option.label)),
                    const SizedBox(width: 12),
                    Text(votes),
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
                if (!poll.anonymous && option.voters.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final voter in option.voters)
                        Chip(label: Text(voter.name)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
