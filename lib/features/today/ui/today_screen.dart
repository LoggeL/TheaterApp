import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/platform/pwa_install_card.dart';
import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../events/domain/event_dates.dart';
import '../../events/domain/event_format.dart';
import '../../events/domain/event_selectors.dart';
import '../../events/domain/event_types.dart';
import '../../events/ui/event_card.dart';
import '../../events/ui/event_style.dart';
import '../../events/ui/rsvp/rsvp_status_badge.dart';
import '../../messages/domain/message_selectors.dart';
import '../../messages/ui/message_detail_screen.dart';
import '../../messages/ui/messages_screen.dart';
import '../../polls/domain/poll_selectors.dart';
import '../../polls/ui/poll_detail_screen.dart';
import '../../polls/ui/polls_screen.dart';
import '../../scripts/ui/script_reader_screen.dart';
import '../../slots/domain/slot_pool.dart';
import '../../slots/ui/slot_format.dart';
import '../../slots/ui/slot_pools_screen.dart';
import 'quick_rsvp.dart';

/// The start page, ordered by urgency: things still waiting for the person
/// (an open response, unread messages, an open poll, a slot to choose) come
/// first, answered and informational things follow in compact form.
class TodayScreen extends StatelessWidget {
  const TodayScreen({
    super.key,
    required this.controller,
    required this.onPlan,
    required this.onScripts,
    this.onMessages,
  });
  final AppController controller;
  final VoidCallback onPlan, onScripts;

  /// Switches to the messages tab; without it the list opens as a page.
  final VoidCallback? onMessages;

  void _allMessages(BuildContext context) => onMessages != null
      ? onMessages!()
      : openPage(context, MessagesScreen(controller: controller));

  @override
  Widget build(BuildContext context) {
    final now = controller.now;
    final upcoming = upcomingEvents(controller, now);
    final next = upcoming.firstOrNull;
    // Only a still answerable next event keeps the large card with quick
    // answers; otherwise it shrinks to one compact row further down.
    final nextOpen =
        next != null && next.needsResponse && controller.canRespondTo(next);
    final nextCard = next == null
        ? const Card(
            child: EmptyState(
              icon: Icons.event_available_outlined,
              title: 'Keine anstehenden Termine',
              message: 'Aktuell stehen keine kommenden Termine an.',
            ),
          )
        : nextOpen
        ? _NextRehearsal(event: next, controller: controller, now: now)
        : _NextCompact(event: next, controller: controller, now: now);
    final unread = unreadMessages(controller).toList();
    final polls = controller.polls.where((p) => !p.isClosed).toList();
    final pollToVote = pollsToVote(controller);
    final pending = _pending(
      context,
      unread: unread,
      poll: pollToVote.firstOrNull,
      pools: slotPoolsToChoose(controller),
    );
    final events = _upcoming(context, upcoming);
    final rest = [
      ..._script(),
      ..._done(
        context,
        poll: pollToVote.isEmpty ? polls.firstOrNull : null,
        allRead: unread.isEmpty,
      ),
    ];
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
          return _desktop(header, nextCard, events, [...pending, ...rest]);
        }
        return RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              ...header,
              const SizedBox(height: 26),
              if (!controller.isDemo) const PwaInstallCard(homeHint: true),
              if (nextOpen) nextCard,
              ...pending,
              if (!nextOpen) ...[
                if (pending.isNotEmpty) const SizedBox(height: 28),
                nextCard,
              ],
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
    List<Widget> header,
    Widget nextCard,
    List<Widget> events,
    List<Widget> secondary,
  ) {
    return RefreshIndicator(
      onRefresh: controller.refresh,
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

  /// Everything still waiting for the person, most urgent first.
  List<Widget> _pending(
    BuildContext context, {
    required List<JsonMap> unread,
    required Poll? poll,
    required List<SlotPool> pools,
  }) => [
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
    if (poll != null) ...[
      SectionTitle(
        'Abstimmung',
        trailing: TextButton(
          onPressed: () =>
              openPage(context, PollsScreen(controller: controller)),
          child: const Text('Alle ansehen'),
        ),
      ),
      _PollPreview(poll: poll, controller: controller),
    ],
    if (pools.isNotEmpty) ...[
      const SectionTitle('Terminfinder'),
      for (final (i, pool) in pools.indexed) ...[
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
  ];

  /// The events after the next one.
  List<Widget> _upcoming(BuildContext context, List<TheaterEvent> upcoming) => [
    SectionTitle(
      'Als Nächstes',
      trailing: TextButton(onPressed: onPlan, child: const Text('Zum Plan')),
    ),
    for (final event in upcoming.skip(1).take(3))
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: EventCard(event: event, controller: controller),
      ),
    if (upcoming.length <= 1)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          'Weitere Termine erscheinen hier, sobald sie geplant sind.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
  ];

  List<Widget> _script() => [
    SectionTitle(
      'Dein Drehbuch',
      trailing: TextButton(
        onPressed: onScripts,
        child: const Text('Alle ansehen'),
      ),
    ),
    if (controller.activeProductions.isEmpty)
      const Card(
        child: EmptyState(
          icon: Icons.menu_book_outlined,
          title: 'Kein aktuelles Stück',
          message:
              'Aktuelle Produktionen erscheinen hier. Ältere Stücke findest du im Drehbucharchiv.',
        ),
      )
    else
      _ScriptShortcut(
        production: controller.activeProductions.first,
        controller: controller,
      ),
  ];

  /// Already handled things, collapsed to one row each.
  List<Widget> _done(
    BuildContext context, {
    required Poll? poll,
    required bool allRead,
  }) {
    final latest = controller.messages.firstOrNull;
    final tiles = [
      if (poll != null)
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
      if (allRead && latest != null)
        _CompactTile(
          key: const ValueKey('today-messages-read'),
          icon: Icons.mark_chat_read_outlined,
          title: 'Mitteilungen',
          subtitle: 'Alles gelesen · zuletzt „${textValue(latest['title'])}“',
          onTap: () => _allMessages(context),
        ),
    ];
    return [
      if (tiles.isNotEmpty) const SectionTitle('Erledigt'),
      for (final (i, tile) in tiles.indexed) ...[
        if (i > 0) const SizedBox(height: 10),
        tile,
      ],
    ];
  }
}

class _PollPreview extends StatelessWidget {
  const _PollPreview({required this.poll, required this.controller});
  final Poll poll;
  final AppController controller;

  @override
  Widget build(BuildContext context) => Card(
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
          const SizedBox(height: 12),
          for (final option in poll.options.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
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
          if (poll.options.length > 3)
            Text('+ ${poll.options.length - 3} weitere Antworten'),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => openPage(
              context,
              PollDetailScreen(controller: controller, pollId: poll.id),
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

/// The next event while it still waits for an answer, with quick answers.
class _NextRehearsal extends StatelessWidget {
  const _NextRehearsal({
    required this.event,
    required this.controller,
    required this.now,
  });
  final TheaterEvent event;
  final AppController controller;
  final DateTime now;
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
          _HeroMeta(Icons.schedule, eventTime(event)),
          const SizedBox(height: 9),
          _HeroMeta(
            Icons.location_on_outlined,
            event.place.isEmpty ? 'Ort folgt' : event.place,
          ),
          const SizedBox(height: 20),
          QuickRsvp(event: event, controller: controller),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: StageTheme.orange,
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
    required this.event,
    required this.controller,
    required this.now,
  });
  final TheaterEvent event;
  final AppController controller;
  final DateTime now;

  String get _summary => switch (event.response) {
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
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        RsvpStatusBadge(
                          status: event.response,
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

class _ScriptShortcut extends StatelessWidget {
  const _ScriptShortcut({required this.production, required this.controller});
  final Production production;
  final AppController controller;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => openPage(
        context,
        ScriptReaderScreen(controller: controller, productionId: production.id),
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
                  const SizedBox(height: 7),
                  Text(
                    controller.scripts.containsKey(production.id)
                        ? 'Offline bereit · Weiterlesen'
                        : 'Öffnen & offline speichern',
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
