import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/identity.dart';
import '../core/models.dart';
import 'profile.dart';
import 'theme.dart';

/// Response and attendance counts of the last six months. Members see their
/// own numbers, admins see everyone alphabetically. Deliberately no ranking,
/// scores or colours: a timely decline is reliable behaviour.
class ParticipationScreen extends StatefulWidget {
  const ParticipationScreen({
    super.key,
    required this.controller,
    this.ensemble = false,
  });
  final AppController controller;

  /// Shows every active person instead of only the signed-in member.
  final bool ensemble;
  @override
  State<ParticipationScreen> createState() => _ParticipationScreenState();
}

class _ParticipationScreenState extends State<ParticipationScreen> {
  late Future<JsonMap> _data = _load();
  Future<JsonMap> _load() => widget.controller.remote('/participation');

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.ensemble ? 'Teilnahme im Ensemble' : 'Meine Teilnahme',
      ),
      actions: [
        IconButton(
          tooltip: 'Aktualisieren',
          onPressed: () => setState(() => _data = _load()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<JsonMap>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.cloud_off_outlined,
            title: 'Übersicht nicht geladen',
            message: identityError(snapshot.error!),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        final since = dateValue(data['since']);
        final people = jsonList(data['people']).map(jsonMap).toList();
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 32),
              children: [
                if (!widget.ensemble)
                  _SummaryCard(jsonMap(data['own']), since: since)
                else if (people.isEmpty)
                  const EmptyState(
                    icon: Icons.groups_outlined,
                    title: 'Keine aktiven Personen',
                    message: 'Aktive Personen im Ensemble erscheinen hier.',
                  )
                else ...[
                  _SummaryCard(
                    _total(people),
                    since: since,
                    title: 'Ensemble gesamt',
                  ),
                  SectionTitle('Personen (${people.length})'),
                  for (final p in people)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _PersonCard(
                        controller: widget.controller,
                        counts: p,
                      ),
                    ),
                ],
                const SizedBox(height: 20),
                _Explanation(
                  widget.ensemble
                      ? 'Absagen zählen nie negativ. „Ohne Absage gefehlt“ zählt nur Termine, zu denen die Person schon ein App-Konto hatte. Jedes Mitglied sieht unter „Mein Bereich“ die eigenen Zahlen.'
                      : 'Absagen zählen nicht negativ – rechtzeitig absagen ist genau richtig, eine Begründung ist nicht nötig. Die Theaterleitung sieht dieselben Zahlen, es gibt keine Rangliste.',
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  JsonMap _total(List<JsonMap> people) => {
    for (final key in [
      'events',
      'answerable',
      'answered',
      'recorded',
      'attended',
      'missedAfterCommitment',
      'missedUnannounced',
    ])
      key: people.fold<int>(0, (sum, p) => sum + intValue(p[key])),
  };
}

/// One compact, neutral line per person for the admin list.
String participationLine(JsonMap p) {
  final parts = <String>[
    if (intValue(p['answerable']) > 0)
      'Rückmeldung ${intValue(p['answered'])} von ${intValue(p['answerable'])}',
    if (intValue(p['recorded']) > 0)
      'dabei ${intValue(p['attended'])} von ${intValue(p['recorded'])}',
    if (intValue(p['missedAfterCommitment']) > 0)
      '${intValue(p['missedAfterCommitment'])}× trotz Zusage gefehlt',
    if (intValue(p['missedUnannounced']) > 0)
      '${intValue(p['missedUnannounced'])}× ohne Absage gefehlt',
  ];
  return parts.isEmpty
      ? '${intValue(p['events'])} Termine, noch nichts erfasst'
      : parts.join(' · ');
}

String _sinceLabel(DateTime? since) => since == null
    ? 'Verbindliche Termine der letzten sechs Monate'
    : 'Verbindliche Termine seit ${DateFormat('d. MMMM yyyy', 'de').format(since.toLocal())}';

/// Two rings and a few neutral facts; the ring colours are the app's own
/// accents, never a traffic light.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard(this.counts, {this.since, this.title});
  final JsonMap counts;
  final DateTime? since;
  final String? title;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    int n(String key) => intValue(counts[key]);
    final recorded = n('recorded') > 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary.withValues(alpha: .08),
              scheme.secondary.withValues(alpha: .06),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Eyebrow(title ?? 'Letzte sechs Monate'),
              const SizedBox(height: 10),
              Text(
                n('events') == 1 ? '1 Termin' : '${n('events')} Termine',
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '${_sinceLabel(since)}. Gesellige Termine zählen nicht mit.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 28,
                runSpacing: 20,
                children: [
                  _Ring(
                    label: 'Rückmeldung gegeben',
                    value: n('answered'),
                    of: n('answerable'),
                    color: scheme.primary,
                  ),
                  _Ring(
                    label: 'Dabei gewesen',
                    value: n('attended'),
                    of: n('recorded'),
                    color: scheme.secondary,
                    empty: 'noch nicht erfasst',
                  ),
                ],
              ),
              if (recorded) ...[
                const SizedBox(height: 22),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _Fact(
                      icon: Icons.event_busy_outlined,
                      label: 'Trotz Zusage gefehlt',
                      value: n('missedAfterCommitment'),
                    ),
                    _Fact(
                      icon: Icons.help_outline,
                      label: 'Ohne Absage gefehlt',
                      value: n('missedUnannounced'),
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 16),
                Text(
                  'Für diesen Zeitraum wurde noch keine Anwesenheit erfasst.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.label,
    required this.value,
    required this.of,
    required this.color,
    this.empty = 'keine offenen Termine',
  });
  final String label, empty;
  final int value, of;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.textScalerOf(context).scale(96).clamp(96.0, 140.0);
    return Semantics(
      container: true,
      label: of == 0 ? '$label: $empty' : '$label: $value von $of',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(end: of == 0 ? 0 : value / of),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => CircularProgressIndicator(
                    value: v,
                    strokeWidth: 9,
                    strokeCap: StrokeCap.round,
                    color: color,
                    backgroundColor: color.withValues(alpha: .14),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        of == 0 ? '–' : '$value',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                      if (of > 0)
                        Text('von $of', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: theme.textTheme.titleSmall),
                if (of == 0) Text(empty, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: muted),
          const SizedBox(width: 8),
          Flexible(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: 10),
          Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// One person in the admin list: avatar, two slim bars and the neutral line.
class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.controller, required this.counts});
  final AppController controller;
  final JsonMap counts;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    int n(String key) => intValue(counts[key]);
    final id = intValue(counts['personId']);
    final member = controller.members.where((m) => m.id == id).firstOrNull;
    final name = textValue(counts['name']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MemberAvatar(
              controller: controller,
              avatarId: member?.avatarId,
              initials: member?.initials.isNotEmpty == true
                  ? member!.initials
                  : name.characters.take(1).toString().toUpperCase(),
              radius: 20,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: theme.textTheme.titleMedium),
                  if (n('answerable') > 0 || n('recorded') > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _Bar(
                            label: 'Rückmeldung',
                            value: n('answered'),
                            of: n('answerable'),
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _Bar(
                            label: 'Dabei',
                            value: n('attended'),
                            of: n('recorded'),
                            color: scheme.secondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    participationLine(counts),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.label,
    required this.value,
    required this.of,
    required this.color,
  });
  final String label;
  final int value, of;
  final Color color;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: of == 0 ? '$label: nicht erfasst' : '$label: $value von $of',
    excludeSemantics: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: of == 0 ? 0 : value / of,
            minHeight: 6,
            color: color,
            backgroundColor: color.withValues(alpha: .14),
          ),
        ),
      ],
    ),
  );
}

class _Explanation extends StatelessWidget {
  const _Explanation(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.favorite_outline,
            size: 18,
            color: theme.colorScheme.secondary,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
