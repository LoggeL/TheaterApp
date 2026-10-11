import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/audience/audience_pickers.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/nudges.dart';
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

  /// Ends voting now, or opens it again: without a deadline or, on servers
  /// with `pollDelete`, with a new one.
  Future<void> _setClosed(Poll poll, bool closed) async {
    DateTime? closesAt;
    if (closed) {
      final confirmed = await confirmDestructive(
        context,
        title: 'Abstimmung beenden?',
        message:
            'Danach kann niemand mehr abstimmen. Du kannst sie später wieder öffnen.',
        confirmLabel: 'Beenden',
      );
      if (!confirmed) return;
    } else if (widget.controller.supports('pollDelete')) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Abstimmung wieder öffnen?'),
          content: const Text(
            'Alle können wieder abstimmen. Ohne Frist läuft sie, bis du sie beendest.',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'open'),
              child: const Text('Ohne Frist'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'deadline'),
              child: const Text('Neue Frist wählen'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'deadline') {
        closesAt = await _pickDeadline();
        if (closesAt == null) return;
      }
    } else {
      final confirmed = await confirmAction(
        context,
        title: 'Abstimmung wieder öffnen?',
        message:
            'Die Frist wird entfernt. Alle können wieder abstimmen, bis du sie beendest.',
        confirmLabel: 'Wieder öffnen',
      );
      if (!confirmed) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final outcome = await widget.controller.performAction({
        'action': 'poll.close',
        'id': poll.id,
        'version': poll.version,
        'closed': closed,
        if (closesAt != null) 'closesAt': closesAt.toUtc().toIso8601String(),
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

  /// A new deadline in the future, or null when the admin cancels.
  Future<DateTime?> _pickDeadline() async {
    final now = widget.controller.now;
    final initial = now.add(const Duration(days: 7));
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 730)),
      initialDate: initial,
      helpText: 'Neue Frist',
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 20, minute: 0),
    );
    if (time == null || !mounted) return null;
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (!picked.isAfter(widget.controller.now)) {
      showProblem(context, 'Die neue Frist muss in der Zukunft liegen.');
      return null;
    }
    return picked;
  }

  Future<void> _delete(Poll poll) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Abstimmung löschen?',
      message:
          'Die Abstimmung und alle Stimmen werden für alle entfernt. Das lässt sich nicht rückgängig machen.',
      confirmLabel: 'Löschen',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final outcome = await widget.controller.performAction({
        'action': 'poll.delete',
        'id': poll.id,
        'version': poll.version,
      });
      if (!mounted) return;
      showDone(
        context,
        outcomeText(
          outcome,
          done: 'Abstimmung gelöscht',
          queued: 'Löschen vorgemerkt – wird bei Verbindung gesendet',
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pushes a reminder to everyone who may vote but has not yet.
  Future<void> _remind(Poll poll, int open) async {
    final confirmed = await confirmAction(
      context,
      title: 'Offene erinnern?',
      message:
          '${open == 1 ? 'Eine Person bekommt' : '$open Personen bekommen'} '
          'eine Push-Erinnerung an diese Abstimmung.',
      confirmLabel: 'Erinnerung senden',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await widget.controller.performActionWithResult({
        'action': 'poll.remindOpen',
        'id': poll.id,
      });
      if (!mounted) return;
      final count = intValue(result.data?['recipients'], open);
      final who = count == 1 ? '1 Person' : '$count Personen';
      showDone(
        context,
        outcomeText(
          result.outcome,
          done: 'Erinnerung an $who gesendet.',
          queued:
              'Erinnerung an $who vorgemerkt – wird bei Verbindung gesendet.',
        ),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "12 von 30 haben abgestimmt" and, while voting runs, the reminder.
  List<Widget> _participation(AppController c, Poll poll, bool closed) {
    final eligible = poll.eligibleCount!,
        voted = poll.eligibleVotes ?? poll.totalVotes;
    final open = eligible - voted;
    final last = poll.lastRemindedAt;
    final theme = Theme.of(context);
    final coolingDown = c.supports('nudges') && remindCoolingDown(last, c.now);
    return [
      const SizedBox(height: 4),
      Text(
        '$voted von $eligible ${voted == 1 ? 'hat' : 'haben'} abgestimmt',
        style: theme.textTheme.bodySmall,
      ),
      if (c.supports('pollRemind') &&
          c.pushConfigured &&
          !closed &&
          open > 0) ...[
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            onPressed: _busy || coolingDown ? null : () => _remind(poll, open),
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('Offene erinnern'),
          ),
        ),
      ],
      if (last != null) ...[
        const SizedBox(height: 4),
        Text(
          lastRemindedLabel(last, poll.remindCount, c.now),
          style: theme.textTheme.bodySmall,
        ),
      ],
    ];
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
              PopupMenuButton<String>(
                tooltip: 'Weitere Aktionen',
                enabled: !_busy,
                onSelected: (value) => switch (value) {
                  'delete' => _delete(poll),
                  _ => _setClosed(poll, value == 'close'),
                },
                itemBuilder: (context) => [
                  closed
                      ? const PopupMenuItem(
                          value: 'reopen',
                          child: ListTile(
                            leading: Icon(Icons.lock_open_outlined),
                            title: Text('Wieder öffnen'),
                          ),
                        )
                      : const PopupMenuItem(
                          value: 'close',
                          child: ListTile(
                            leading: Icon(Icons.stop_circle_outlined),
                            title: Text('Beenden'),
                          ),
                        ),
                  if (c.supports('pollDelete'))
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Löschen'),
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
                  if (admin && poll.eligibleCount != null)
                    ..._participation(c, poll, closed),
                  if (canVote) ...[
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
