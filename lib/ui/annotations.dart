import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../core/identity.dart';
import '../core/models.dart';
import 'theme.dart';

class PrivateNoteEditor extends StatefulWidget {
  const PrivateNoteEditor({super.key, required this.initialText});
  final String initialText;
  @override
  State<PrivateNoteEditor> createState() => _PrivateNoteEditorState();
}

class _PrivateNoteEditorState extends State<PrivateNoteEditor> {
  late final TextEditingController _text;
  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          8,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Private Notiz',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text('Nur für dich auf diesem Gerät.'),
            const SizedBox(height: 18),
            TextField(
              controller: _text,
              autofocus: true,
              minLines: 4,
              maxLines: 10,
              maxLength: 3000,
              decoration: const InputDecoration(hintText: 'Deine Notiz'),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => Navigator.pop(context, _text.text.trim()),
              child: const Text('Speichern'),
            ),
            if (widget.initialText.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.pop(context, ''),
                child: const Text('Notiz löschen'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
          ],
        ),
      ),
    ),
  );
}

class CueCommentsScreen extends StatefulWidget {
  const CueCommentsScreen({
    super.key,
    required this.controller,
    required this.document,
    required this.cue,
  });
  final AppController controller;
  final ScriptDocument document;
  final ScriptCue cue;
  @override
  State<CueCommentsScreen> createState() => _CueCommentsScreenState();
}

class _CueCommentsScreenState extends State<CueCommentsScreen> {
  final _text = TextEditingController();
  List<JsonMap> _comments = [];
  String? _error;
  bool _loading = true, _sending = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await widget.controller.remote(
        '/productions/${Uri.encodeComponent(widget.document.productionId)}/comments',
      );
      if (mounted) {
        setState(() {
          _comments = jsonList(
            data['comments'],
          ).map(jsonMap).where((c) => c['cueId'] == widget.cue.id).toList();
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = identityError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await widget.controller.performAction({
        'action': 'comment.save',
        'productionId': widget.document.productionId,
        'revision': widget.document.revision,
        'cueId': widget.cue.id,
        'text': _text.text,
      });
      _text.clear();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = identityError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kommentare')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Szene ${widget.cue.sceneId}${widget.cue.role.isEmpty ? '' : ' · ${widget.cue.role}'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(widget.cue.text, maxLines: 4, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 24),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            for (final c in _comments)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                textValue(c['authorName']),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            if (c['authorId'] ==
                                    widget.controller.user?.personId ||
                                widget.controller.user?.isAdmin == true)
                              IconButton(
                                tooltip: 'Kommentar löschen',
                                onPressed: () async {
                                  try {
                                    await widget.controller.performAction({
                                      'action': 'comment.delete',
                                      'id': c['id'],
                                    });
                                    await _load();
                                  } catch (e) {
                                    if (mounted) {
                                      setState(() => _error = identityError(e));
                                    }
                                  }
                                },
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                ),
                              ),
                          ],
                        ),
                        Text(textValue(c['text'])),
                        if (c['revision'] != widget.document.revision)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: StatePill(
                              'Aus einer älteren Fassung',
                              color: StageTheme.orange,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 3,
              maxLines: 8,
              maxLength: 3000,
              decoration: const InputDecoration(
                labelText: 'Kommentar für das Ensemble',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send_outlined),
              label: const Text('Kommentieren'),
            ),
          ],
        ),
      ),
    ),
  );
}
