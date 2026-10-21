import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/platform/pwa_install_card.dart';
import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../accounts/ui/accounts_admin_screen.dart';
import '../../events/domain/event_dates.dart';
import '../../events/domain/event_format.dart';
import '../../events/domain/event_types.dart';
import '../../events/ui/event_card.dart';
import '../../events/ui/event_style.dart';
import '../../events/ui/rsvp/rsvp_status_badge.dart';
import '../../messages/ui/message_detail_screen.dart';
import '../../messages/ui/messages_screen.dart';
import '../../polls/ui/poll_detail_screen.dart';
import '../../polls/ui/polls_screen.dart';
import '../../scripts/ui/productions_screen.dart';
import '../../scripts/ui/script_reader_screen.dart';
import '../../slots/ui/slot_format.dart';
import '../../slots/ui/slot_pools_screen.dart';
import '../domain/today_digest.dart';
import 'quick_rsvp.dart';

/// Weekday and date, short enough for one line on the cards.
String _shortDate(DateTime date) => DateFormat('EEE d. MMM', 'de').format(date);

/// The start page, ordered by urgency: things still waiting for the person
/// (an open response, unread messages, an open poll, a slot to choose) come
/// first, answered and informational things follow in compact form.
class TodayScreen extends StatefulWidget {
  const TodayScreen({
    super.key,
    required this.controller,
    required this.onPlan,
    required this.onScripts,
    this.onMessages,
    this.onPolls,
  });
  final AppController controller;
  final VoidCallback onPlan, onScripts;

  /// Switches to the messages tab; without it the list opens as a page.
  final VoidCallback? onMessages;

  /// Switches to the polls in the messages tab; without it the list opens
  /// as a page.
  final VoidCallback? onPolls;

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  /// The next event answered from its large card. It keeps the top slot
  /// while it collapses, instead of jumping below the open items.
  String? _answeredOnTop;

  AppController get controller => widget.controller;

  void _allMessages(BuildContext context) => widget.onMessages != null
      ? widget.onMessages!()
      : openPage(context, MessagesScreen(controller: controller));

  void _allPolls(BuildContext context) => widget.onPolls != null
      ? widget.onPolls!()
      : openPage(context, PollsScreen(controller: controller));

  @override
  Widget build(BuildContext context) {
    final digest = TodayDigest.from(controller);
    final now = digest.now;
    final next = digest.next;
    final nextOnTop =
        digest.nextOpen || (next != null && next.id == _answeredOnTop);
    final nextCard = KeyedSubtree(
      key: const ValueKey('today-next-slot'),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.passthrough,
            alignment: Alignment.topCenter,
            children: [...previous, ?current],
          ),
          child: next == null
              ? const Card(
                  child: EmptyState(
                    icon: Icons.event_available_outlined,
                    title: 'Keine anstehenden Termine',
                    message: 'Aktuell stehen keine kommenden Termine an.',
                  ),
                )
              : digest.nextOpen
              ? _NextRehearsal(
                  key: ValueKey('hero-${next.id}'),
                  event: next,
                  controller: controller,
                  now: now,
                  onAnswer: () => setState(() => _answeredOnTop = next.id),
                )
              : _NextCompact(
                  key: ValueKey('compact-${next.id}'),
                  event: next,
                  controller: controller,
                  now: now,
                ),
        ),
      ),
    );
    final pending = _pending(context, digest);
    final install = [
      if (!controller.isDemo) const PwaInstallCard(homeHint: true),
    ];
    final events = _later(digest);
    final rest = [..._script(context, digest), ..._done(context, digest)];
    final header = [
      Text(
        'Hallo, ${controller.user?.firstName ?? 'Ensemble'}.',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 8),
      Text(
        DateFormat('EEEE, d. MMMM', 'de').format(now),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        if (constraints.maxWidth >= 900 && scale <= 1.35) {
          return _desktop(context, header, nextCard, events, [
            ...pending,
            ...install,
            ...rest,
          ]);
        }
        return RefreshIndicator(
          onRefresh: () => refreshWithFeedback(context, controller),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              ...header,
              const SizedBox(height: 26),
              if (nextOnTop) nextCard,
              ...pending,
              ...install,
              if (!nextOnTop) ...[const SizedBox(height: 28), nextCard],
              ...events,
              ...rest,
            ],
          ),
        );
      },
    );
  }

  /// Wide windows: events on the left, everything else on the right, each
  /// column again ordered by urgency.
  Widget _desktop(
    BuildContext context,
    List<Widget> header,
    Widget nextCard,
    List<Widget> events,
    List<Widget> secondary,
  ) {
    return RefreshIndicator(
      onRefresh: () => refreshWithFeedback(context, controller),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(28),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1304),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 6,
                  child: Column(
                    key: const ValueKey('today-primary-column'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ...header,
                      const SizedBox(height: 24),
                      nextCard,
                      ...events,
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  flex: 5,
                  child: Column(
                    key: const ValueKey('today-secondary-column'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: secondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Everything still waiting for the person, most urgent first; one quiet
  /// line when nothing is left.
  List<Widget> _pending(BuildContext context, TodayDigest digest) {
    final unread = digest.unread;
    final poll = digest.pollsToVote.firstOrNull;
    final morePolls = digest.pollsToVote.length - 1;
    final open = digest.openResponses;
    final registrations = digest.registrations;
    if (!digest.hasPending) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Row(
            children: [
              Icon(
                Icons.task_alt,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Alles erledigt – keine offenen Rückmeldungen.'),
              ),
            ],
          ),
        ),
      ];
    }
    return [
      if (unread.isNotEmpty) ...[
        SectionTitle(
          'Neue Mitteilungen',
          trailing: TextButton(
            onPressed: () => _allMessages(context),
            child: const Text('Alle ansehen'),
          ),
        ),
        for (final (i, m) in unread.take(3).indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          _CompactTile(
            key: ValueKey('today-unread-${m['id']}'),
            icon: Icons.chat_bubble_outline,
            title: textValue(m['title']),
            subtitle: textValue(m['body']),
            highlight: true,
            onTap: () => openPage(
              context,
              MessageDetailScreen(controller: controller, message: m),
            ),
          ),
        ],
        if (unread.length > 3)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              '+ ${unread.length - 3} weitere ungelesene',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
      if (open.isNotEmpty) ...[
        const SectionTitle('Offene Rückmeldungen'),
        for (final (i, event) in open.indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          _OpenResponseRow(
            key: ValueKey('today-open-${event.id}'),
            event: event,
            controller: controller,
          ),
        ],
        if (digest.moreOpenResponses > 0)
          _MoreLink(
            '+ ${digest.moreOpenResponses} weitere im Plan',
            onPressed: widget.onPlan,
          ),
      ],
      if (poll != null) ...[
        SectionTitle(
          'Abstimmung',
          trailing: TextButton(
            onPressed: () => _allPolls(context),
            child: const Text('Alle ansehen'),
          ),
        ),
        _PollPreview(
          key: ValueKey('today-poll-${poll.id}'),
          poll: poll,
          controller: controller,
        ),
        if (morePolls > 0)
          _MoreLink(
            morePolls == 1
                ? '+ 1 weitere Abstimmung'
                : '+ $morePolls weitere Abstimmungen',
            onPressed: () => _allPolls(context),
          ),
      ],
      if (digest.slotPools.isNotEmpty) ...[
        const SectionTitle('Terminfinder'),
        for (final (i, pool) in digest.slotPools.indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          _CompactTile(
            icon: Icons.edit_calendar_outlined,
            title: pool.title,
            subtitle: 'Wähle noch ein Zeitfenster · ${slotPoolRange(pool)}',
            highlight: true,
            onTap: () => openSlotPool(context, controller, pool.id),
          ),
        ],
      ],
      if (registrations > 0) ...[
        const SectionTitle('Registrierungen'),
        _CompactTile(
          key: const ValueKey('today-registrations'),
          icon: Icons.how_to_reg_outlined,
          title: registrations == 1
              ? '1 neue Registrierung'
              : '$registrations neue Registrierungen',
          subtitle: 'Prüfen und mit einer Person verknüpfen',
          highlight: true,
          onTap: () => openPage(
            context,
            AccountsAdminScreen(
              controller: controller,
              initialStatus: 'waiting',
            ),
          ),
        ),
      ],
    ];
  }

  /// The events after the next one; hidden while there are none.
  List<Widget> _later(TodayDigest digest) => [
    if (digest.laterEvents.isNotEmpty) ...[
      SectionTitle(
        'Weitere Termine',
        trailing: TextButton(
          onPressed: widget.onPlan,
          child: const Text('Alle Termine'),
        ),
      ),
      for (final event in digest.laterEvents)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: EventCard(event: event, controller: controller),
        ),
    ],
  ];

  List<Widget> _script(BuildContext context, TodayDigest digest) {
    final production = digest.scriptProduction;
    final archive = controller.archivedProductions.isNotEmpty;
    return [
      SectionTitle(
        'Dein Drehbuch',
        trailing: TextButton(
          onPressed: widget.onScripts,
          child: const Text('Alle ansehen'),
        ),
      ),
      if (production != null)
        _ScriptShortcut(
          production: production,
          controller: controller,
          event: digest.scriptEvent,
          sceneId: digest.scriptSceneId,
        )
      else
        Card(
          child: ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('Kein aktuelles Stück'),
            subtitle: Text(
              archive
                  ? 'Ältere Stücke findest du im Drehbucharchiv.'
                  : 'Neue Stücke erscheinen hier, sobald sie bereitstehen.',
            ),
            trailing: archive ? const Icon(Icons.chevron_right) : null,
            onTap: archive
                ? () => openPage(
                    context,
                    ProductionArchiveScreen(controller: controller),
                  )
                : null,
          ),
        ),
    ];
  }

  /// Already handled things, collapsed to one row each.
  List<Widget> _done(BuildContext context, TodayDigest digest) {
    final poll = digest.votedPoll;
    if (poll == null) return const [];
    return [
      const SectionTitle('Erledigt'),
      _CompactTile(
        key: const ValueKey('today-poll-voted'),
        icon: Icons.how_to_vote_outlined,
        title: poll.title,
        subtitle: 'Abstimmung · Du hast abgestimmt',
        onTap: () => openPage(
          context,
          PollDetailScreen(controller: controller, pollId: poll.id),
        ),
      ),
    ];
  }
}

/// A left-aligned follow-up link below a list, e.g. "+ 2 weitere im Plan".
class _MoreLink extends StatelessWidget {
  const _MoreLink(this.label, {required this.onPressed});
  final String label;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextButton(onPressed: onPressed, child: Text(label)),
    ),
  );
}

/// A further event still waiting for an answer, answerable in place.
class _OpenResponseRow extends StatelessWidget {
  const _OpenResponseRow({
    super.key,
    required this.event,
    required this.controller,
  });
  final TheaterEvent event;
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = event.startsAt;
    return Card(
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.primaryContainer.withValues(alpha: .35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: Icon(eventKindIcon(event.kind)),
              title: Text(
                event.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                [
                  if (start != null) _shortDate(start),
                  eventTime(event),
                  if (event.place.isNotEmpty) event.place,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openEvent(context, controller, event.id),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: QuickRsvp(
                event: event,
                controller: controller,
                dense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An open poll the person can vote in right here.
class _PollPreview extends StatefulWidget {
  const _PollPreview({super.key, required this.poll, required this.controller});
  final Poll poll;
  final AppController controller;
  @override
  State<_PollPreview> createState() => _PollPreviewState();
}

class _PollPreviewState extends State<_PollPreview> {
  /// The option whose vote is being sent.
  String? _sending;

  Future<void> _vote(String optionId) async {
    // A cast vote moves the poll out of the open items, so the confirmation
    // goes through the captured messenger.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = optionId);
    try {
      final outcome = await widget.controller.vote(widget.poll.id, optionId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            outcomeText(
              outcome,
              done: 'Stimme gespeichert',
              queued: 'Stimme vorgemerkt – wird bei Verbindung gesendet',
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        showProblem(context, e);
      } else {
        messenger.showSnackBar(SnackBar(content: Text(userMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final poll = widget.poll;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                Text(poll.privacyLabel),
                Text(
                  poll.closesAt == null
                      ? 'Ohne Frist'
                      : 'Bis ${DateFormat('d. MMMM · HH:mm', 'de').format(poll.closesAt!.toLocal())}',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(poll.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final option in poll.options.take(3))
              Semantics(
                button: true,
                inMutuallyExclusiveGroup: true,
                checked: option.id == poll.selectedOptionId,
                enabled: _sending == null,
                label:
                    '${option.label}, '
                    '${option.votes == 1 ? '1 Stimme' : '${option.votes} Stimmen'}',
                excludeSemantics: true,
                onTap: _sending != null ? null : () => _vote(option.id),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _sending != null ? null : () => _vote(option.id),
                  child: ConstrainedBox(
                    // One tap votes: a full-size target avoids mis-taps.
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 9,
                      ),
                      child: Row(
                        children: [
                          if (_sending == option.id)
                            const SizedBox.square(
                              dimension: 20,
                              child: Padding(
                                padding: EdgeInsets.all(2),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          else
                            Icon(
                              option.id == poll.selectedOptionId
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              size: 20,
                            ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(option.label)),
                          const SizedBox(width: 12),
                          Text('${option.votes}'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (poll.options.length > 3)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('+ ${poll.options.length - 3} weitere Antworten'),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => openPage(
                context,
                PollDetailScreen(
                  controller: widget.controller,
                  pollId: poll.id,
                ),
              ),
              icon: const Icon(Icons.poll_outlined),
              label: Text(
                poll.selectedOptionId == null
                    ? 'Jetzt abstimmen'
                    : 'Stimme ansehen',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The next event while it still waits for an answer, with quick answers.
class _NextRehearsal extends StatelessWidget {
  const _NextRehearsal({
    super.key,
    required this.event,
    required this.controller,
    required this.now,
    this.onAnswer,
  });
  final TheaterEvent event;
  final AppController controller;
  final DateTime now;
  final VoidCallback? onAnswer;
  @override
  Widget build(BuildContext context) {
    final marker = eventMarker(event, now);
    final accent = eventKindColor(event.kind, dark: true);
    return Container(
      padding: const EdgeInsets.all(23),
      decoration: BoxDecoration(
        color: StageTheme.ink,
        borderRadius: BorderRadius.circular(28),
        // The frame also separates the dark card from the dark-mode surface.
        border: Border.all(
          color: marker != null
              ? StageTheme.orange
              : isProminentKind(event.kind)
              ? accent.withValues(alpha: .6)
              : Colors.white.withValues(alpha: .1),
          width: marker != null ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Eyebrow(
                  'Dein nächster Termin',
                  color: Color(0xFFFFB18A),
                ),
              ),
              if (marker != null)
                EventMarker(marker, onDark: true)
              else if (event.startsAt != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    DateFormat('dd.MM.').format(event.startsAt!),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 21),
          Text(
            event.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 27,
              height: 1.16,
              letterSpacing: -.6,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),
          _HeroMeta(
            eventKindIcon(event.kind),
            eventTypeLabel(event.kind),
            iconColor: accent,
          ),
          const SizedBox(height: 9),
          _HeroMeta(
            Icons.schedule,
            event.startsAt == null
                ? eventTime(event)
                : '${_shortDate(event.startsAt!)} · ${eventTime(event)}',
          ),
          const SizedBox(height: 9),
          _HeroMeta(
            Icons.location_on_outlined,
            event.place.isEmpty ? 'Ort folgt' : event.place,
          ),
          const SizedBox(height: 20),
          QuickRsvp(event: event, controller: controller, onAnswer: onAnswer),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: StageTheme.orangeDeep,
                foregroundColor: Colors.white,
              ),
              onPressed: () => openEvent(context, controller, event.id),
              icon: const Icon(Icons.arrow_forward, size: 19),
              label: const Text('Termin ansehen'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The next event once it is answered (or can no longer be answered): one
/// compact, tappable row with the essentials, leaving room for open items.
class _NextCompact extends StatelessWidget {
  const _NextCompact({
    super.key,
    required this.event,
    required this.controller,
    required this.now,
  });
  final TheaterEvent event;
  final AppController controller;
  final DateTime now;

  String get _summary => switch (event.response) {
    _ when event.implicitYes => 'Du bist eingeplant',
    'yes' => 'Du bist dabei',
    'late' => 'Du kommst später',
    'no' => 'Du bist nicht dabei',
    _ when event.fromSlotPool => 'Zeitfenster gebucht',
    _ when !controller.canRespondTo(event) => 'Rückmeldung geschlossen',
    _ => 'Rückmeldung offen',
  };

  @override
  Widget build(BuildContext context) {
    final marker = eventMarker(event, now);
    return Material(
      key: const ValueKey('today-next-compact'),
      color: StageTheme.ink,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(
          color: marker != null
              ? StageTheme.orange
              : Colors.white.withValues(alpha: .1),
          width: marker != null ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: () => openEvent(context, controller, event.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Eyebrow(
                            'Dein nächster Termin',
                            color: Color(0xFFFFB18A),
                          ),
                        ),
                        if (marker != null) EventMarker(marker, onDark: true),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      event.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${eventDate(event)} · ${eventTime(event)}',
                      style: const TextStyle(
                        color: Color(0xFFDAE0D9),
                        fontSize: 13,
                      ),
                    ),
                    if (event.place.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        event.place,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFDAE0D9),
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        RsvpStatusBadge(
                          status: displayResponse(event),
                          expectedArrivalAt: event.expectedArrivalAt,
                          locked: responsesClosed(controller, event),
                          onDark: true,
                        ),
                        Text(
                          _summary,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroMeta extends StatelessWidget {
  const _HeroMeta(this.icon, this.label, {this.iconColor});
  final IconData icon;
  final String label;
  final Color? iconColor;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: iconColor ?? const Color(0xFFBFC8C0), size: 17),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          label,
          style: const TextStyle(color: Color(0xFFDAE0D9), fontSize: 13),
        ),
      ),
    ],
  );
}

/// One compact, tappable row; tinted while it still needs attention.
class _CompactTile extends StatelessWidget {
  const _CompactTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlight = false,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  final bool highlight;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      color: highlight
          ? theme.colorScheme.primaryContainer.withValues(alpha: .35)
          : null,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        leading: Badge(
          isLabelVisible: highlight,
          smallSize: 10,
          backgroundColor: StageTheme.orange,
          child: Icon(icon),
        ),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Opens the most relevant script; for the next rehearsal right at its first
/// planned scene.
class _ScriptShortcut extends StatelessWidget {
  const _ScriptShortcut({
    required this.production,
    required this.controller,
    this.event,
    this.sceneId,
  });
  final Production production;
  final AppController controller;

  /// The next event, when the script was picked for it.
  final TheaterEvent? event;
  final String? sceneId;
  @override
  Widget build(BuildContext context) {
    final offline = controller.scripts.containsKey(production.id);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => openPage(
          context,
          ScriptReaderScreen(
            controller: controller,
            productionId: production.id,
            initialSceneId: sceneId,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFEBE4D9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.auto_stories_outlined,
                  size: 28,
                  color: StageTheme.ink,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      production.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (event != null) ...[
                      const SizedBox(height: 7),
                      Text(
                        sceneId == null
                            ? 'Für „${event!.title}“'
                            : 'Für „${event!.title}“ · ab der ersten Szene',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                    const SizedBox(height: 7),
                    Text(
                      !offline
                          ? 'Öffnen & offline speichern'
                          : sceneId == null
                          ? 'Offline bereit · Weiterlesen'
                          : 'Offline bereit',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
