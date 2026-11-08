import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../data/calendar_feed.dart';

Future<bool> _openExternally(Uri uri) => launchUrl(
  uri,
  mode: LaunchMode.externalApplication,
  // A webcal address goes to the calendar app; a new tab would stay empty.
  webOnlyWindowName: uri.scheme == 'webcal' ? '_self' : '_blank',
);

/// How the subscription page hands an address to a calendar; tests replace it.
@visibleForTesting
Future<bool> Function(Uri uri) calendarOpener = _openExternally;

/// The personal calendar subscription: add it to Google, Apple Calendar or
/// Outlook, copy it, or replace a link that got into the wrong hands.
class CalendarFeedScreen extends StatefulWidget {
  const CalendarFeedScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<CalendarFeedScreen> createState() => _CalendarFeedScreenState();
}

class _CalendarFeedScreenState extends State<CalendarFeedScreen> {
  late Future<CalendarFeed> _feed = _load();
  bool _busy = false;

  // The FutureBuilder subscribes with the next frame; an error arriving
  // earlier must not count as unhandled.
  Future<CalendarFeed> _load() => loadCalendarFeed(widget.controller)..ignore();

  void _reload() => setState(() {
    _feed = _load();
  });

  Future<void> _open(Uri uri, String problem) async {
    var opened = false;
    try {
      opened = await calendarOpener(uri);
    } catch (_) {
      // Nothing on this device takes the address.
    }
    if (!opened && mounted) showProblem(context, problem);
  }

  Future<void> _copy(CalendarFeed feed) async {
    try {
      await Clipboard.setData(ClipboardData(text: feed.url.toString()));
      if (mounted) showDone(context, 'Link kopiert');
    } catch (_) {
      if (mounted) {
        showProblem(
          context,
          'Kopieren nicht möglich. Markiere den Link und kopiere ihn von Hand.',
        );
      }
    }
  }

  Future<void> _reset() async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Link neu erzeugen?',
      message:
          'Der bisherige Link hört sofort auf zu funktionieren. Kalender, die ihn abonniert haben, bekommen keine Termine mehr. Dort musst du den neuen Link wieder hinzufügen.',
      confirmLabel: 'Neu erzeugen',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final feed = await resetCalendarFeed(widget.controller);
      if (!mounted) return;
      setState(() {
        _feed = Future.value(feed);
      });
      showDone(
        context,
        'Neuer Link erzeugt. Füge ihn in deinem Kalender wieder hinzu.',
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kalender abonnieren')),
    body: FutureBuilder<CalendarFeed>(
      future: _feed,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(22, 40, 22, 32),
            children: [
              EmptyState(
                icon: Icons.cloud_off_outlined,
                title: 'Kalender-Link nicht geladen',
                message: userMessage(snapshot.error!),
                action: OutlinedButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Erneut laden'),
                ),
              ),
            ],
          );
        }
        final feed = snapshot.data;
        if (feed == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return _content(context, feed);
      },
    ),
  );

  Widget _content(BuildContext context, CalendarFeed feed) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    Widget wide(Widget button) =>
        SizedBox(width: double.infinity, child: button);
    return ListView(
      padding: pagePadding(context),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.event_repeat_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Dein persönlicher Kalender',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Mit dem Abo erscheinen deine Termine automatisch in deinem Kalender. Enthalten sind die Termine, zu denen du eingeladen bist, auch wenn du noch nicht zugesagt hast. Termine, für die du abgesagt hast, stehen nicht darin.',
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('Hinzufügen'),
        wide(
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _open(
                    feed.webcal,
                    'Keine Kalender-App hat den Link angenommen. Kopiere ihn und füge ihn in deinem Kalender als Abo hinzu.',
                  ),
            icon: const Icon(Icons.event_repeat_outlined),
            label: const Text('Abo hinzufügen'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 14),
          child: Text(
            'Öffnet Apple Kalender, Outlook oder eine andere Kalender-App auf deinem Gerät.',
            style: small,
          ),
        ),
        wide(
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _open(
                    feed.google,
                    'Google Kalender konnte nicht geöffnet werden. Kopiere den Link und füge ihn dort unter "Weitere Kalender → Per URL" hinzu.',
                  ),
            icon: const Icon(Icons.add_link),
            label: const Text('In Google Kalender hinzufügen'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 14),
          child: Text(
            'Am Computer im Browser hinzufügen. Danach kannst du den Kalender auch in der Google-Kalender-App anzeigen.',
            style: small,
          ),
        ),
        const SectionTitle('Persönlicher Abo-Link'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Füge diese Adresse in deinem Kalender als Abo per URL hinzu.',
                ),
                const SizedBox(height: 10),
                SelectableText(feed.url.toString(), style: small),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _copy(feed),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Link kopieren'),
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('So geht es in deinem Kalender'),
        Card(
          child: Column(
            children: [
              _instructions('iPhone, iPad und Mac', [
                'Tippe auf "Abo hinzufügen" und bestätige das Kalenderabo.',
                'Alternativ: Kopiere den Abo-Link. Wähle in Apple Kalender "Kalenderabonnement hinzufügen" (am Mac "Ablage → Neues Kalenderabonnement") und füge den Link ein.',
              ]),
              const Divider(height: 1),
              _instructions('Android und Google Kalender', [
                'Öffne diese Seite am Computer und klicke auf "In Google Kalender hinzufügen". Bestätige das Abo mit deinem Google-Konto.',
                'Alternativ: Kopiere den Abo-Link. Öffne Google Kalender im Browser, wähle neben "Weitere Kalender" das Plus und dann "Per URL". Füge den Link ein und bestätige mit "Kalender hinzufügen".',
                'Verwende auf dem Handy dasselbe Google-Konto und aktiviere den abonnierten Kalender in der Kalenderliste. In der Google-Kalender-App selbst lässt sich kein neues Abo anlegen.',
              ]),
              const Divider(height: 1),
              _instructions('Outlook', [
                'Kopiere den Abo-Link und öffne den Kalender in Outlook.',
                'Wähle "Kalender hinzufügen → Aus dem Internet abonnieren", füge den Link ein und bestätige. Je nach Outlook-Version heißt die Option "Aus dem Internet" oder "Aus dem Web abonnieren".',
              ]),
              const Divider(height: 1),
              _instructions('Thunderbird und andere Kalender', [
                'Kopiere den Abo-Link und lege einen neuen Kalender an.',
                'Wähle "Im Netzwerk" oder "Per URL" und füge den Link ein. Falls nach dem Format gefragt wird, wähle "iCalendar (ICS)". Für den Abo-Link ist keine zusätzliche Anmeldung nötig.',
              ]),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(
            'Dein Kalender ruft neue Termine, Änderungen und Absagen regelmäßig ab. Das kann einige Stunden oder länger als einen Tag dauern. Den aktuellen Stand siehst du hier in der Theater-App.',
            style: small,
          ),
        ),
        const SectionTitle('Einmalig als Datei'),
        wide(
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _open(
                    feed.download,
                    'Die Kalenderdatei konnte nicht geöffnet werden. Kopiere den Abo-Link und öffne ihn im Browser, um die Datei zu speichern.',
                  ),
            icon: const Icon(Icons.download_outlined),
            label: const Text('Als Datei herunterladen'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text(
            'Speichert deine Termine als ICS-Datei zum Importieren. Das ist eine einmalige Kopie: Spätere Änderungen kommen damit nicht automatisch an.',
            style: small,
          ),
        ),
        const SectionTitle('Datenschutz'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Gib den Link nicht weiter. Wer ihn kennt, sieht deine Termine, auch ohne Anmeldung. Ist er in falsche Hände geraten, erzeuge einen neuen.',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: _busy ? null : _reset,
                    icon: const Icon(Icons.autorenew),
                    label: const Text('Link neu erzeugen'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _instructions(String title, List<String> steps) => ExpansionTile(
    title: Text(title),
    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (index, step) in steps.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('${index + 1}. $step'),
        ),
    ],
  );
}
