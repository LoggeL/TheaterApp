import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../shared/audience/audience_pickers.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
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
      await widget.controller.vote(widget.pollId, id);
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
                  if (poll.roleIds.isNotEmpty ||
                      poll.personIds.isNotEmpty ||
                      poll.productionIds.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    AudienceBadge(
                      controller: widget.controller,
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
                    poll.isClosed
                        ? 'Abgeschlossen · ${poll.voteCountLabel}'
                        : '${poll.voteCountLabel}${poll.closesAt == null ? '' : ' · Bis ${DateFormat('d. MMMM · HH:mm', 'de').format(poll.closesAt!.toLocal())}'}',
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
                                if (!poll.anonymous &&
                                    option.voters.isNotEmpty) ...[
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
                    ),
                  if (_busy) const LinearProgressIndicator(),
                  if (widget.controller.outbox.any(
                    (action) =>
                        !action.failed &&
                        action.payload['action'] == 'poll.vote' &&
                        action.payload['pollId'] == poll.id,
                  ))
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
