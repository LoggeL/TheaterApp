part of '../script_reader_screen.dart';

/// Private notes, bookmarks, comments and the actions of a single cue.
extension _ReaderAnnotations on _ScriptReaderScreenState {
  Widget _groupHeader(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
    child: Semantics(
      header: true,
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );

  Future<void> _saveNotes() => _preference('notes', _notes);

  /// Opens the note editor for [cue]. Deleting offers an undo.
  Future<void> _editNote(ScriptCue cue) async {
    final previous = _notes[cue.id];
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          PrivateNoteEditor(initialText: textValue(jsonMap(previous)['text'])),
    );
    if (result == null || !mounted) return;
    _update(() {
      if (result.isEmpty) {
        _notes.remove(cue.id);
      } else {
        _notes[cue.id] = {
          'text': result,
          'revision': _document!.revision,
          'sceneId': cue.sceneId,
          'role': cue.role,
        };
      }
    });
    await _saveNotes();
    if (!mounted || result.isNotEmpty || previous == null) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    showDone(
      context,
      'Notiz gelöscht',
      actionLabel: 'Rückgängig',
      onAction: () => _restoreNote(cue.id, previous),
    );
  }

  void _restoreNote(String cueId, Object? note) {
    if (!mounted) return;
    _update(() => _notes[cueId] = note);
    _saveNotes();
  }

  void _showComments(ScriptCue cue) => openPage(
    context,
    CueCommentsScreen(
      controller: widget.controller,
      document: _document!,
      cue: cue,
      repository: _comments,
    ),
  );

  void _showNotes() {
    // The last deleted note, kept for the undo inside the open sheet.
    MapEntry<String, Object?>? deleted;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) {
          final doc = _document;
          final grouped = groupByScene(doc, _notes.keys);
          void delete(String id) {
            update(() => deleted = MapEntry(id, _notes[id]));
            _update(() => _notes.remove(id));
            _saveNotes();
          }

          Widget noteTile(String id, ScriptCue? cue) {
            final note = jsonMap(_notes[id]);
            final older = doc != null && note['revision'] != doc.revision;
            return ListTile(
              leading: Icon(cue == null ? Icons.link_off : Icons.edit_note),
              title: Text(
                textValue(note['text']),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: cue == null
                  ? const Text('Nicht zugeordnet: andere Fassung')
                  : Text(
                      [
                        if (cue.role.isNotEmpty) cue.role,
                        if (older) 'Aus älterer Fassung',
                      ].join(' · '),
                    ),
              onTap: cue == null
                  ? null
                  : () {
                      Navigator.pop(sheet);
                      _jumpToCue(cue.id);
                    },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cue != null)
                    IconButton(
                      tooltip: 'Notiz bearbeiten',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () {
                        Navigator.pop(sheet);
                        _editNote(cue);
                      },
                    ),
                  IconButton(
                    tooltip: cue == null
                        ? 'Verwaiste Notiz löschen'
                        : 'Notiz löschen',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => delete(id),
                  ),
                ],
              ),
            );
          }

          final current = _currentCue;
          return ReaderSheetFrame(
            title: 'Private Notizen',
            subtitle: 'Nur auf diesem Gerät gespeichert',
            child: ListView(
              shrinkWrap: true,
              children: [
                if (deleted != null)
                  Material(
                    color: Theme.of(sheet).colorScheme.surfaceContainerHighest,
                    child: ListTile(
                      dense: true,
                      title: const Text('Notiz gelöscht'),
                      trailing: TextButton(
                        onPressed: () {
                          final entry = deleted!;
                          update(() => deleted = null);
                          _restoreNote(entry.key, entry.value);
                        },
                        child: const Text('Rückgängig'),
                      ),
                    ),
                  ),
                if (current != null)
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('Notiz an aktueller Textstelle'),
                    onTap: () {
                      Navigator.pop(sheet);
                      _editNote(current);
                    },
                  ),
                for (final group in grouped.groups) ...[
                  _groupHeader(sheet, group.title),
                  for (final cue in group.cues) noteTile(cue.id, cue),
                ],
                if (grouped.orphans.isNotEmpty) ...[
                  _groupHeader(sheet, 'Andere Fassung'),
                  for (final id in grouped.orphans) noteTile(id, null),
                ],
                if (_notes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Noch keine Notizen.'),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showBookmarks() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) {
          final grouped = groupByScene(_document, _bookmarks);
          Widget bookmarkTile(String id, ScriptCue? cue) => ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: Text(
              cue == null
                  ? 'Nicht mehr zugeordnet'
                  : cue.role.isEmpty
                  ? 'Textstelle'
                  : cue.role,
            ),
            subtitle: Text(
              cue?.text ?? 'Die Textstelle fehlt in dieser Fassung.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: 'Lesezeichen entfernen',
              icon: const Icon(Icons.close),
              onPressed: () {
                _toggleBookmark(id);
                update(() {});
              },
            ),
            onTap: cue == null
                ? null
                : () {
                    Navigator.pop(sheet);
                    _jumpToCue(id);
                  },
          );
          return ReaderSheetFrame(
            title: 'Deine Lesezeichen',
            child: ListView(
              shrinkWrap: true,
              children: [
                if (_bookmarks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Noch keine Lesezeichen. Halte eine Textstelle gedrückt, um eines zu setzen.',
                    ),
                  ),
                for (final group in grouped.groups) ...[
                  _groupHeader(sheet, group.title),
                  for (final cue in group.cues) bookmarkTile(cue.id, cue),
                ],
                if (grouped.orphans.isNotEmpty) ...[
                  _groupHeader(sheet, 'Andere Fassung'),
                  for (final id in grouped.orphans) bookmarkTile(id, null),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _showCueActions(ScriptCue cue) {
    final comments = _comments.countFor(cue.id);
    final bookmarked = _bookmarks.contains(cue.id);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: Text(
                  _notes.containsKey(cue.id)
                      ? 'Private Notiz bearbeiten'
                      : 'Private Notiz',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _editNote(cue);
                },
              ),
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: const Text('Kommentare'),
                subtitle: comments == 0
                    ? null
                    : Text(
                        comments == 1 ? '1 Kommentar' : '$comments Kommentare',
                      ),
                onTap: () {
                  Navigator.pop(context);
                  _showComments(cue);
                },
              ),
              ListTile(
                leading: Icon(
                  bookmarked
                      ? Icons.bookmark_remove_outlined
                      : Icons.bookmark_add_outlined,
                ),
                title: Text(
                  bookmarked ? 'Lesezeichen entfernen' : 'Lesezeichen setzen',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _toggleBookmark(cue.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Text kopieren'),
                onTap: () {
                  Clipboard.setData(
                    ClipboardData(
                      text:
                          '${cue.role.isEmpty ? '' : '${cue.role}: '}${cue.text}'
                              .trim(),
                    ),
                  );
                  Navigator.pop(context);
                  _notice('Text kopiert.');
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
