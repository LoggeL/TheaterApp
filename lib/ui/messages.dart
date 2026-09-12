import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/identity.dart';
import 'admin.dart';
import 'theme.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Mitteilungen'),
        actions: [
          if (controller.user?.isAdmin == true)
            IconButton(
              tooltip: 'Mitteilung schreiben',
              onPressed: () => openPage(
                context,
                MessageComposerScreen(controller: controller),
              ),
              icon: const Icon(Icons.edit_square),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            if (controller.messages.isEmpty)
              const EmptyState(
                icon: Icons.chat_bubble_outline,
                title: 'Noch keine Mitteilungen',
                message: 'Nachrichten der Theaterleitung findest du hier.',
              ),
            for (final m in controller.messages)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(18),
                    leading: Icon(
                      m['read'] == true
                          ? Icons.mark_email_read_outlined
                          : Icons.mark_email_unread_outlined,
                      color: m['read'] == true ? null : StageTheme.orange,
                    ),
                    title: Text(
                      textValue(m['title']),
                      style: TextStyle(
                        fontWeight: m['read'] == true
                            ? FontWeight.w500
                            : FontWeight.w800,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        textValue(m['body']),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openPage(
                      context,
                      MessageDetailScreen(controller: controller, message: m),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class MessageTargetScreen extends StatefulWidget {
  const MessageTargetScreen({
    super.key,
    required this.controller,
    required this.messageId,
  });
  final AppController controller;
  final String messageId;
  @override
  State<MessageTargetScreen> createState() => _MessageTargetScreenState();
}

class _MessageTargetScreenState extends State<MessageTargetScreen> {
  late final Future<void> _loading = Future.microtask(
    widget.controller.refresh,
  );
  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _loading,
    builder: (context, snapshot) {
      final matches = widget.controller.messages.where(
        (m) => m['id'] == widget.messageId,
      );
      if (matches.isNotEmpty) {
        return MessageDetailScreen(
          controller: widget.controller,
          message: matches.first,
        );
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Mitteilung')),
        body: snapshot.connectionState != ConnectionState.done
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(
                icon: Icons.mail_outline,
                title: 'Mitteilung nicht verfügbar',
                message:
                    'Die Mitteilung wurde entfernt oder ist für dein Konto nicht freigegeben.',
              ),
      );
    },
  );
}

class MessageDetailScreen extends StatefulWidget {
  const MessageDetailScreen({
    super.key,
    required this.controller,
    required this.message,
  });
  final AppController controller;
  final JsonMap message;
  @override
  State<MessageDetailScreen> createState() => _MessageDetailScreenState();
}

class _MessageDetailScreenState extends State<MessageDetailScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.message['read'] != true) {
        widget.controller
            .performAction({
              'action': 'message.read',
              'id': widget.message['id'],
            })
            .catchError((Object e) {
              if (mounted) showProblem(context, e);
            });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message, date = dateValue(widget.message['createdAt']);
    return Scaffold(
      appBar: AppBar(title: const Text('Mitteilung')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                textValue(m['title']),
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 16),
              Text(
                '${textValue(m['authorName'])}${date == null ? '' : ' · ${DateFormat('d. MMMM · HH:mm', 'de').format(date.toLocal())}'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 28),
              SelectableText(
                textValue(m['body']),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MessageComposerScreen extends StatefulWidget {
  const MessageComposerScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<MessageComposerScreen> createState() => _MessageComposerScreenState();
}

class _MessageComposerScreenState extends State<MessageComposerScreen> {
  final _title = TextEditingController(), _body = TextEditingController();
  bool _all = true, _push = true, _busy = false;
  final Set<int> _recipients = {};
  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'message.send',
        'title': _title.text,
        'body': _body.text,
        'audience': _all ? 'all' : 'selected',
        'recipientPersonIds': _recipients.toList(),
        'push': _push && widget.controller.pushConfigured,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.pendingCount > 0
                  ? 'Mitteilung zur Übertragung vorgemerkt.'
                  : 'Mitteilung veröffentlicht.',
            ),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Mitteilung schreiben',
    children: (context) => [
      TextField(
        controller: _title,
        decoration: const InputDecoration(labelText: 'Betreff'),
        maxLength: 250,
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _body,
        decoration: const InputDecoration(
          labelText: 'Nachricht',
          alignLabelWithHint: true,
        ),
        minLines: 7,
        maxLines: 18,
        maxLength: 10000,
      ),
      const SectionTitle('Empfänger'),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('Alle Mitglieder')),
          ButtonSegment(value: false, label: Text('Auswählen')),
        ],
        selected: {_all},
        onSelectionChanged: (s) => setState(() => _all = s.single),
      ),
      if (!_all) ...[
        const SizedBox(height: 16),
        for (final m in widget.controller.members.where((m) => m.active))
          CheckboxListTile(
            value: _recipients.contains(m.id),
            title: Text(m.name),
            subtitle: Text(m.group),
            onChanged: (v) => setState(() {
              if (v == true) {
                _recipients.add(m.id);
              } else {
                _recipients.remove(m.id);
              }
            }),
          ),
      ],
      const SizedBox(height: 20),
      SwitchListTile(
        value: _push && widget.controller.pushConfigured,
        onChanged: widget.controller.pushConfigured
            ? (v) => setState(() => _push = v)
            : null,
        title: const Text('Auch als Push benachrichtigen'),
        subtitle: widget.controller.pushConfigured
            ? null
            : const Text('Push ist noch nicht eingerichtet.'),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _busy ? null : _send,
        icon: const Icon(Icons.send_outlined),
        label: const Text('Mitteilung veröffentlichen'),
      ),
    ],
  );
}

class PushAdminScreen extends StatefulWidget {
  const PushAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<PushAdminScreen> createState() => _PushAdminScreenState();
}

class _PushAdminScreenState extends State<PushAdminScreen> {
  late Future<JsonMap> _data;
  @override
  void initState() {
    super.initState();
    _data = widget.controller.remote('/admin/push');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Push-Versand'),
      actions: [
        IconButton(
          tooltip: 'Aktualisieren',
          onPressed: () =>
              setState(() => _data = widget.controller.remote('/admin/push')),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: FutureBuilder<JsonMap>(
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
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(22),
          children: [
            StatePill(
              data['configured'] == true
                  ? 'Versand eingerichtet'
                  : 'Einrichtung ausstehend',
              color: data['configured'] == true
                  ? StageTheme.green
                  : StageTheme.orange,
            ),
            const SizedBox(height: 20),
            Text(
              '${jsonList(data['devices']).length} registrierte Geräte',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: data['configured'] == true
                  ? () async {
                      try {
                        await widget.controller.performAction({
                          'action': 'push.test',
                        });
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Testbenachrichtigung für deine Geräte vorgemerkt.',
                              ),
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) showProblem(context, e);
                      }
                    }
                  : null,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Test an meine Geräte'),
            ),
            const SectionTitle('Letzte Sendungen'),
            for (final job in jsonList(
              data['jobs'],
            ).map(jsonMap).toList().reversed)
              Card(
                child: ListTile(
                  title: Text(textValue(job['title'])),
                  subtitle: Text(switch (job['status']) {
                    'accepted_by_provider' => 'An Versanddienst übergeben',
                    'no_devices' => 'Kein registriertes Gerät',
                    'failed' => 'Versand fehlgeschlagen',
                    _ => 'Wartet auf Versand',
                  }),
                ),
              ),
          ],
        );
      },
    ),
  );
}
