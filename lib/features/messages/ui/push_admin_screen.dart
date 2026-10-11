import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/identity.dart';
import '../../../core/models.dart';
import '../../../shared/audience/recipients.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import 'message_composer_screen.dart';
import 'messages_screen.dart';

class PushAdminScreen extends StatefulWidget {
  const PushAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<PushAdminScreen> createState() => _PushAdminScreenState();
}

class _PushAdminScreenState extends State<PushAdminScreen> {
  late Future<JsonMap> _data;
  final _title = TextEditingController(), _body = TextEditingController();
  Recipients _to = const Recipients();
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _data = widget.controller.remote('/admin/push');
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _reload() =>
      setState(() => _data = widget.controller.remote('/admin/push'));

  bool get _ready =>
      _title.text.trim().isNotEmpty &&
      _body.text.trim().isNotEmpty &&
      _to.chosen;

  Future<void> _send() async {
    final count = _to.members(widget.controller).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          count == 1
              ? 'Push an 1 Person senden?'
              : 'Push an $count Personen senden?',
        ),
        content: Text('„${_title.text.trim()}“\n${_body.text.trim()}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Senden'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'push.send',
        'title': _title.text,
        'body': _body.text,
        ..._to.toJson(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.controller.pendingCount > 0
                ? 'Push zur Übertragung vorgemerkt.'
                : 'Push an $count ${count == 1 ? 'Person' : 'Personen'} wird versendet.',
          ),
        ),
      );
      _title.clear();
      _body.clear();
      _to = const Recipients();
      _reload();
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    try {
      await widget.controller.performAction({'action': 'push.test'});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Testbenachrichtigung für deine Geräte vorgemerkt.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, theme = Theme.of(context);
    return AdminPage(
      controller: c,
      title: 'Push senden',
      actions: [
        IconButton(
          tooltip: 'Aktualisieren',
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
      children: (context) => [
        const PageHeader(
          'Eigener Push',
          eyebrow: 'Sofort benachrichtigen',
          subtitle:
              'Für kurzfristige Hinweise wie „Probe beginnt 30 Minuten später“. '
              'Ein Push wird nicht gespeichert. Was man nachlesen können soll, gehört in eine Mitteilung.',
        ),
        if (!c.pushConfigured)
          const EmptyState(
            icon: Icons.notifications_off_outlined,
            title: 'Push ist noch nicht eingerichtet',
            message:
                'Sobald der Versand eingerichtet ist, kannst du hier Pushes senden.',
          )
        else ...[
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Titel'),
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _body,
            decoration: const InputDecoration(
              labelText: 'Text',
              alignLabelWithHint: true,
            ),
            minLines: 2,
            maxLines: 5,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          _PushPreview(title: _title.text, body: _body.text),
          const SectionTitle('Empfänger'),
          RecipientSelector(
            controller: c,
            value: _to,
            onChanged: (value) => setState(() => _to = value),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy || !_ready ? null : _send,
                icon: const Icon(Icons.send_outlined),
                label: const Text('Push senden'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    openPage(context, MessageComposerScreen(controller: c)),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Lieber Mitteilung schreiben'),
              ),
            ],
          ),
        ],
        const SectionTitle('Versand'),
        FutureBuilder<JsonMap>(
          future: _data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return EmptyState(
                icon: Icons.error_outline,
                title: 'Versandstatus nicht geladen',
                message: identityError(snapshot.error!),
              );
            }
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final data = snapshot.data!,
                configured = data['configured'] == true;
            final jobs = jsonList(data['jobs']).map(jsonMap).toList()
              ..sort(
                (a, b) => textValue(
                  b['createdAt'],
                ).compareTo(textValue(a['createdAt'])),
              );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatePill(
                          configured
                              ? 'Versand eingerichtet'
                              : 'Einrichtung ausstehend',
                          color: configured
                              ? StageTheme.green
                              : StageTheme.orange,
                        ),
                        Text(
                          '${jsonList(data['devices']).length} registrierte Geräte',
                          style: theme.textTheme.titleSmall,
                        ),
                        TextButton.icon(
                          onPressed: configured ? _test : null,
                          icon: const Icon(Icons.notifications_active_outlined),
                          label: const Text('Test an meine Geräte'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SectionTitle('Letzte Sendungen'),
                if (jobs.isEmpty)
                  const EmptyState(
                    icon: Icons.notifications_none,
                    title: 'Noch nichts gesendet',
                    message: 'Versendete Pushes erscheinen hier.',
                  ),
                for (final job in jobs) _JobTile(controller: c, job: job),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// How the push roughly looks on a phone's lock screen.
class _PushPreview extends StatelessWidget {
  const _PushPreview({required this.title, required this.body});
  final String title, body;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/brand/kolpingtheater-ramsen.png',
              width: 34,
              height: 34,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.theater_comedy, size: 34),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'THEATER-APP · JETZT',
                  style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1),
                ),
                const SizedBox(height: 2),
                Text(
                  title.trim().isEmpty ? 'Titel' : title.trim(),
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  body.trim().isEmpty
                      ? 'Text der Benachrichtigung'
                      : body.trim(),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.controller, required this.job});
  final AppController controller;
  final JsonMap job;
  @override
  Widget build(BuildContext context) {
    final (icon, color, status) = switch (job['status']) {
      'accepted_by_provider' => (
        Icons.check_circle_outline,
        StageTheme.green,
        'Zugestellt an Versanddienst',
      ),
      'no_devices' => (
        Icons.phonelink_off,
        Colors.grey,
        'Kein registriertes Gerät',
      ),
      'failed' => (Icons.error_outline, Colors.red, 'Versand fehlgeschlagen'),
      _ => (Icons.schedule, StageTheme.orange, 'Wartet auf Versand'),
    };
    final date = dateValue(job['createdAt']);
    final recipients = jsonList(job['recipientPersonIds']).length;
    final accepted = intValue(job['accepted']);
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(textValue(job['title'])),
        subtitle: Text(
          [
            if (date != null) messageTime(date, controller.now),
            if (job['manual'] == true) 'Eigener Push',
            status,
            if (recipients > 0)
              recipients == 1 ? 'an 1 Person' : 'an $recipients Personen',
            if (accepted > 0) accepted == 1 ? '1 Gerät' : '$accepted Geräte',
          ].join(' · '),
        ),
      ),
    );
  }
}
