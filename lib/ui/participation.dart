import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/identity.dart';
import '../core/models.dart';
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
                Text(
                  since == null
                      ? 'Verbindliche Termine der letzten sechs Monate.'
                      : 'Verbindliche Termine seit ${DateFormat('d. MMMM yyyy', 'de').format(since.toLocal())}. Gesellige Termine zählen nicht mit.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                if (!widget.ensemble)
                  _SummaryCard(jsonMap(data['own']))
                else if (people.isEmpty)
                  const EmptyState(
                    icon: Icons.groups_outlined,
                    title: 'Keine aktiven Personen',
                    message: 'Aktive Personen im Ensemble erscheinen hier.',
                  )
                else ...[
                  _SummaryCard(_total(people), title: 'Ensemble gesamt'),
                  const SectionTitle('Personen'),
                  for (final p in people)
                    Card(
                      child: ListTile(
                        title: Text(textValue(p['name'])),
                        subtitle: Text(participationLine(p)),
                      ),
                    ),
                ],
                const SizedBox(height: 20),
                Text(
                  widget.ensemble
                      ? 'Absagen zählen nie negativ. „Ohne Absage gefehlt“ zählt nur Termine, zu denen die Person schon ein App-Konto hatte. Jedes Mitglied sieht unter „Mein Bereich“ die eigenen Zahlen.'
                      : 'Absagen zählen nicht negativ – rechtzeitig absagen ist genau richtig, eine Begründung ist nicht nötig. Die Theaterleitung sieht dieselben Zahlen, es gibt keine Rangliste.',
                  style: Theme.of(context).textTheme.bodySmall,
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

class _SummaryCard extends StatelessWidget {
  const _SummaryCard(this.counts, {this.title});
  final JsonMap counts;
  final String? title;
  @override
  Widget build(BuildContext context) {
    int n(String key) => intValue(counts[key]);
    final rows = <(String, String)>[
      ('Termine', '${n('events')}'),
      if (n('answerable') > 0)
        ('Rückmeldung gegeben', '${n('answered')} von ${n('answerable')}'),
      if (n('recorded') > 0) ...[
        ('Dabei gewesen', '${n('attended')} von ${n('recorded')} erfassten'),
        ('Trotz Zusage gefehlt', '${n('missedAfterCommitment')}'),
        ('Ohne Absage gefehlt', '${n('missedUnannounced')}'),
      ],
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Text(title!, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
            ],
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(label)),
                    Text(
                      value,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            if (n('recorded') == 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Für diesen Zeitraum wurde noch keine Anwesenheit erfasst.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
