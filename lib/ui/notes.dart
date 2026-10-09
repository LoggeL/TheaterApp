import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import 'admin.dart';
import 'audience.dart';
import 'theme.dart';

List<String> _noteRoleIds(JsonMap note) => [
  for (final id in jsonList(note['roleIds'])) id.toString(),
];
List<int> _notePersonIds(JsonMap note) =>
    jsonList(note['personIds']).map(intValue).toList();

class NotesScreen extends StatelessWidget {
  const NotesScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final admin = controller.user?.isAdmin == true;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Notizen'),
          actions: [
            if (admin && !controller.isDemo)
              IconButton(
                tooltip: 'Notiz anlegen',
                onPressed: () =>
                    openPage(context, NoteEditorScreen(controller: controller)),
                icon: const Icon(Icons.note_add_outlined),
              ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            padding: const EdgeInsets.all(22),
            children: [
              if (controller.notes.isEmpty)
                EmptyState(
                  icon: Icons.sticky_note_2_outlined,
                  title: 'Noch keine Notizen',
                  message: admin
                      ? 'Lege Notizen an und gib sie für alle oder einzelne Rollen frei.'
                      : 'Freigegebene Notizen der Theaterleitung findest du hier.',
                ),
              for (final n in controller.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(18),
                      leading: Icon(
                        n['published'] == true
                            ? Icons.sticky_note_2_outlined
                            : Icons.edit_note,
                      ),
                      title: Text(textValue(n['title'])),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (textValue(n['body']).isNotEmpty)
                              Text(
                                textValue(n['body']),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (admin) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 10,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (n['published'] != true)
                                    const StatePill(
                                      'Entwurf',
                                      color: StageTheme.orange,
                                    ),
                                  AudienceBadge(
                                    controller: controller,
                                    roleIds: _noteRoleIds(n),
                                    personIds: _notePersonIds(n),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openPage(
                        context,
                        NoteDetailScreen(
                          controller: controller,
                          noteId: textValue(n['id']),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class NoteDetailScreen extends StatelessWidget {
  const NoteDetailScreen({
    super.key,
    required this.controller,
    required this.noteId,
  });
  final AppController controller;
  final String noteId;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final note = controller.notes.where((n) => n['id'] == noteId).firstOrNull;
      final admin = controller.user?.isAdmin == true;
      final date = dateValue(note?['updatedAt']);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Notiz'),
          actions: [
            if (admin && note != null && !controller.isDemo)
              IconButton(
                tooltip: 'Bearbeiten',
                onPressed: () => openPage(
                  context,
                  NoteEditorScreen(controller: controller, note: note),
                ),
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ),
        body: note == null
            ? const EmptyState(
                icon: Icons.sticky_note_2_outlined,
                title: 'Notiz nicht verfügbar',
                message:
                    'Die Notiz wurde entfernt oder ist für dein Konto nicht freigegeben.',
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Text(
                        textValue(note['title']),
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${textValue(note['authorName'])}${date == null ? '' : ' · ${DateFormat('d. MMMM · HH:mm', 'de').format(date.toLocal())}'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (admin) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            StatePill(
                              note['published'] == true
                                  ? 'Freigegeben'
                                  : 'Entwurf',
                              color: note['published'] == true
                                  ? StageTheme.green
                                  : StageTheme.orange,
                            ),
                            AudienceBadge(
                              controller: controller,
                              roleIds: _noteRoleIds(note),
                              personIds: _notePersonIds(note),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 28),
                      SelectableText(
                        textValue(note['body']),
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.controller, this.note});
  final AppController controller;
  final JsonMap? note;
  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _title, _body;
  late Set<String> _roleIds;
  late Set<int> _personIds;
  late bool _published;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    final n = widget.note;
    _title = TextEditingController(text: textValue(n?['title']));
    _body = TextEditingController(text: textValue(n?['body']));
    _roleIds = n == null ? {} : _noteRoleIds(n).toSet();
    _personIds = n == null ? {} : _notePersonIds(n).toSet();
    _published = n?['published'] == true;
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      showProblem(context, 'Bitte einen Titel eingeben.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'note.save',
        'id': widget.note?['id'],
        'version': widget.note?['version'],
        'title': _title.text,
        'body': _body.text,
        'roleIds': _roleIds.toList(),
        'personIds': _personIds.toList(),
        'published': _published,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Notiz löschen?'),
        content: const Text('Die Notiz wird für alle entfernt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'note.delete',
        'id': widget.note!['id'],
        'version': widget.note!['version'],
      });
      if (mounted) {
        Navigator.of(context)
          ..pop()
          ..pop();
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
    title: widget.note == null ? 'Notiz anlegen' : 'Notiz bearbeiten',
    children: (context) => [
      TextField(
        controller: _title,
        maxLength: 200,
        decoration: const InputDecoration(labelText: 'Titel'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _body,
        minLines: 7,
        maxLines: 20,
        maxLength: 20000,
        decoration: const InputDecoration(
          labelText: 'Notiz',
          alignLabelWithHint: true,
        ),
      ),
      const SizedBox(height: 12),
      AudiencePicker(
        controller: widget.controller,
        allowEveryone: _personIds.isEmpty,
        selected: _roleIds,
        onChanged: (value) => setState(() => _roleIds = value),
      ),
      const SizedBox(height: 16),
      PersonPicker(
        controller: widget.controller,
        selected: _personIds,
        onChanged: (value) => setState(() => _personIds = value),
      ),
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _published,
        onChanged: _busy ? null : (v) => setState(() => _published = v),
        title: const Text('Freigeben'),
        subtitle: Text(
          _published
              ? 'Sichtbar für ${widget.controller.audienceLabel(_roleIds, _personIds)}.'
              : 'Entwurf · nur für Admins sichtbar.',
        ),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _busy ? null : _save,
        icon: const Icon(Icons.save_outlined),
        label: const Text('Speichern'),
      ),
      if (widget.note != null) ...[
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: _busy ? null : _delete,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Notiz löschen'),
        ),
      ],
    ],
  );
}
