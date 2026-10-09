import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/event_types.dart';
import '../core/models.dart';
import 'event_style.dart';
import 'events.dart';
import 'messages.dart';
import 'polls.dart';
import 'pwa_install.dart';
import 'reader.dart';
import 'theme.dart';

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
      : Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MessagesScreen(controller: controller),
          ),
        );

  void _latestMessage(BuildContext context) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => MessageDetailScreen(
        controller: controller,
        message: controller.messages.first,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final upcoming =
        controller.events
            .where(
              (e) =>
                  e.startsAt == null || (e.endsAt ?? e.startsAt!).isAfter(now),
            )
            .toList()
          ..sort(
            (a, b) => (a.startsAt ?? DateTime(9999)).compareTo(
              b.startsAt ?? DateTime(9999),
            ),
          );
    final next = upcoming.isEmpty ? null : upcoming.first;
    final unanswered = upcoming
        .where((e) => e.response == 'open' && controller.canRespondTo(e))
        .length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        if (constraints.maxWidth >= 900 && scale <= 1.35) {
          return _desktop(context, now, upcoming, next, unanswered);
        }
        return RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Text(
                'Hallo, ${controller.user?.firstName ?? 'Ensemble'}.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),
              Text(
                DateFormat('EEEE, d. MMMM', 'de').format(now),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 26),
              if (!controller.isDemo) const PwaInstallCard(homeHint: true),
              if (next != null)
                _NextRehearsal(event: next, controller: controller)
              else
                const Card(
                  child: EmptyState(
                    icon: Icons.event_available_outlined,
                    title: 'Keine anstehenden Termine',
                    message: 'Aktuell stehen keine kommenden Termine an.',
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _QuickTile(
                      icon: Icons.mark_email_unread_outlined,
                      value: '$unanswered',
                      label: 'Rückmeldungen offen',
                      onTap: onPlan,
                      highlight: unanswered > 0,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _QuickTile(
                      icon: Icons.auto_stories_outlined,
                      value: '${controller.activeProductions.length}',
                      label: 'Drehbücher für dich',
                      onTap: onScripts,
                    ),
                  ),
                ],
              ),
              if (controller.polls.any((p) => !p.isClosed)) ...[
                const SectionTitle('Abstimmungen'),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.poll_outlined),
                    title: Text(
                      controller.polls.firstWhere((p) => !p.isClosed).title,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PollsScreen(controller: controller),
                      ),
                    ),
                  ),
                ),
              ],
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
              SectionTitle(
                'Als Nächstes',
                trailing: TextButton(
                  onPressed: onPlan,
                  child: const Text('Zum Plan'),
                ),
              ),
              ...upcoming
                  .skip(1)
                  .take(3)
                  .map(
                    (event) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: EventCard(event: event, controller: controller),
                    ),
                  ),
              if (upcoming.length <= 1)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'Weitere Termine erscheinen hier, sobald sie geplant sind.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              if (controller.messages.isNotEmpty) ...[
                SectionTitle(
                  'Mitteilungen',
                  trailing: TextButton(
                    onPressed: () => _allMessages(context),
                    child: const Text('Alle ansehen'),
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(textValue(controller.messages.first['title'])),
                    subtitle: Text(
                      textValue(controller.messages.first['body']),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _latestMessage(context),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _desktop(
    BuildContext context,
    DateTime now,
    List<TheaterEvent> upcoming,
    TheaterEvent? next,
    int unanswered,
  ) {
    final poll = controller.polls.where((p) => !p.isClosed).firstOrNull;
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
                      Text(
                        'Hallo, ${controller.user?.firstName ?? 'Ensemble'}.',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        DateFormat('EEEE, d. MMMM', 'de').format(now),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),
                      if (next != null)
                        _NextRehearsal(event: next, controller: controller)
                      else
                        const Card(
                          child: EmptyState(
                            icon: Icons.event_available_outlined,
                            title: 'Keine anstehenden Termine',
                            message:
                                'Aktuell stehen keine kommenden Termine an.',
                          ),
                        ),
                      SectionTitle(
                        'Als Nächstes',
                        trailing: TextButton(
                          onPressed: onPlan,
                          child: const Text('Zum Plan'),
                        ),
                      ),
                      for (final event in upcoming.skip(1).take(3))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: EventCard(
                            event: event,
                            controller: controller,
                          ),
                        ),
                      if (upcoming.length <= 1)
                        const Text(
                          'Weitere Termine erscheinen hier, sobald sie geplant sind.',
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  flex: 5,
                  child: Column(
                    key: const ValueKey('today-secondary-column'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                      const SizedBox(height: 16),
                      _QuickTile(
                        icon: Icons.mark_email_unread_outlined,
                        value: '$unanswered',
                        label: 'Rückmeldungen offen',
                        onTap: onPlan,
                        highlight: unanswered > 0,
                      ),
                      if (poll != null) ...[
                        SectionTitle(
                          'Abstimmung',
                          trailing: TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    PollsScreen(controller: controller),
                              ),
                            ),
                            child: const Text('Alle ansehen'),
                          ),
                        ),
                        _PollPreview(poll: poll, controller: controller),
                      ],
                      if (controller.messages.isNotEmpty) ...[
                        SectionTitle(
                          'Mitteilungen',
                          trailing: TextButton(
                            onPressed: () => _allMessages(context),
                            child: const Text('Alle ansehen'),
                          ),
                        ),
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.chat_bubble_outline),
                            title: Text(
                              textValue(controller.messages.first['title']),
                            ),
                            subtitle: Text(
                              textValue(controller.messages.first['body']),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _latestMessage(context),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    PollDetailScreen(controller: controller, pollId: poll.id),
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

class _NextRehearsal extends StatelessWidget {
  const _NextRehearsal({required this.event, required this.controller});
  final TheaterEvent event;
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final marker = eventMarker(event, DateTime.now());
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
          if (event.needsResponse && controller.canRespondTo(event))
            _QuickRsvp(event: event, controller: controller)
          else
            RsvpStatusBadge(
              status: event.response,
              expectedArrivalAt: event.expectedArrivalAt,
              locked: responsesClosed(controller, event),
              onDark: true,
              emphasizeOpen: !event.fromSlotPool,
            ),
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

/// Answers a still open event right on the start page.
class _QuickRsvp extends StatefulWidget {
  const _QuickRsvp({required this.event, required this.controller});
  final TheaterEvent event;
  final AppController controller;
  @override
  State<_QuickRsvp> createState() => _QuickRsvpState();
}

class _QuickRsvpState extends State<_QuickRsvp> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _late() async {
    final start = widget.event.startsAt;
    final time = start == null
        ? null
        : await showTimePicker(
            context: context,
            helpText: 'Voraussichtlich da ab',
            initialTime: TimeOfDay.fromDateTime(
              start.add(const Duration(minutes: 30)),
            ),
          );
    if ((start != null && time == null) || !mounted) return;
    await _run(
      () => widget.controller.respond(
        widget.event.id,
        'late',
        expectedArrivalAt: start == null
            ? null
            : DateTime(
                start.year,
                start.month,
                start.day,
                time!.hour,
                time.minute,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final options = [
      _RsvpOption(
        icon: Icons.thumb_up_alt_outlined,
        label: 'Bin dabei',
        primary: true,
        onTap: _busy
            ? null
            : () =>
                  _run(() => widget.controller.respond(widget.event.id, 'yes')),
      ),
      _RsvpOption(
        icon: Icons.schedule,
        label: 'Komme später',
        onTap: _busy ? null : _late,
      ),
      _RsvpOption(
        icon: Icons.thumb_down_alt_outlined,
        label: 'Kann nicht',
        onTap: _busy || !widget.controller.canDecline(widget.event)
            ? null
            : () => declineEvent(context, widget.controller, widget.event),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Bist du dabei?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            // Three equal tiles side by side; stacked when space is tight.
            final stacked =
                constraints.maxWidth < 260 ||
                MediaQuery.textScalerOf(context).scale(14) > 20;
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, o) in options.indexed) ...[
                    if (i > 0) const SizedBox(height: 8),
                    o,
                  ],
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, o) in options.indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: o.vertical()),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// One answer on the dark next-event card.
class _RsvpOption extends StatelessWidget {
  const _RsvpOption({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.column = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary, column;

  _RsvpOption vertical() => _RsvpOption(
    icon: icon,
    label: label,
    onTap: onTap,
    primary: primary,
    column: true,
  );

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final foreground = primary ? StageTheme.ink : Colors.white;
    final content = [
      Icon(icon, size: column ? 22 : 18, color: foreground),
      SizedBox(width: column ? 0 : 10, height: column ? 6 : 0),
      Flexible(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: foreground,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    ];
    return Semantics(
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : .45,
        child: Material(
          color: primary ? Colors.white : Colors.white.withValues(alpha: .06),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: primary
                ? BorderSide.none
                : BorderSide(color: Colors.white.withValues(alpha: .28)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: column ? 14 : 13,
              ),
              child: column
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: content,
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: content,
                    ),
            ),
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

class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.icon,
    required this.value,
    required this.label,
    required this.onTap,
    this.highlight = false,
  });
  final IconData icon;
  final String value, label;
  final VoidCallback onTap;
  final bool highlight;
  @override
  Widget build(BuildContext context) => Card(
    color: highlight
        ? Color.alphaBlend(
            Theme.of(context).colorScheme.primary.withValues(alpha: .09),
            Theme.of(context).cardTheme.color ??
                Theme.of(context).colorScheme.surfaceContainerLow,
          )
        : null,
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const Spacer(),
                Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: highlight
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ScriptShortcut extends StatelessWidget {
  const _ScriptShortcut({required this.production, required this.controller});
  final Production production;
  final AppController controller;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ScriptReaderScreen(
            controller: controller,
            productionId: production.id,
          ),
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
