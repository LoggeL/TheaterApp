part of '../script_reader_screen.dart';

/// The three-column desktop workspace: scenes, text, cast and focus.
extension _ReaderDesktop on _ScriptReaderScreenState {
  Widget _sideCard(BuildContext context, String title, List<Widget> children) =>
      Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      );

  Widget _buildAdaptiveContent(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (!_desktopReader(context, constraints.maxWidth) || _document == null) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: _buildContent(context),
          ),
        );
      }
      final document = _document!;
      final focus = document.cues
          .where((c) => c.id == _live.focus?.cueId)
          .firstOrNull;
      final sceneNotes = _notes.entries.where(
        (entry) =>
            textValue(jsonMap(entry.value)['sceneId']) == _visibleSceneId,
      );
      return Row(
        key: const ValueKey('reader-desktop-workspace'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 220,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Szenen',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final scene in document.scenes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      key: ValueKey('reader-scene-${scene.id}'),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      title: Text(scene.title),
                      selected: _visibleSceneId == scene.id,
                      selectedColor: readerAccentText(context),
                      selectedTileColor: readerAccent.withValues(alpha: 0.1),
                      onTap: () => _jumpToScene(scene.id),
                    ),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
                  child: _buildContent(context),
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(
            width: 290,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sideCard(context, 'Regie & Besetzung', [
                  for (final role in document.roles)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(role.name),
                      subtitle: Text(
                        role.actor.isEmpty ? 'Noch nicht besetzt' : role.actor,
                      ),
                      trailing: _roles.contains(role.id)
                          ? const Tooltip(
                              message: 'Eigene Rolle',
                              child: Icon(Icons.person, size: 18),
                            )
                          : null,
                    ),
                  TextButton(
                    onPressed: _showRoles,
                    child: const Text('Meine Rollen wählen'),
                  ),
                ]),
                _sideCard(context, 'Private Notizen', [
                  if (sceneNotes.isEmpty)
                    const Text(
                      'Noch keine Notizen zu dieser Szene. Rechtsklick oder langes Drücken auf eine Textstelle fügt eine Notiz hinzu.',
                    ),
                  for (final entry in sceneNotes)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        textValue(jsonMap(entry.value)['text']),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _jumpToCue(entry.key),
                    ),
                  TextButton(
                    onPressed: _showNotes,
                    child: const Text('Alle Notizen öffnen'),
                  ),
                ]),
                _sideCard(context, 'Gemeinsamer Fokus', [
                  Text(
                    focus == null
                        ? 'Keine aktuelle Textstelle geteilt.'
                        : [
                            sceneTitle(document, focus.sceneId),
                            if (focus.role.isNotEmpty) focus.role,
                          ].join(' · '),
                  ),
                  if (focus != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      focus.text,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                    TextButton(
                      onPressed: () => _jumpToCue(focus.id),
                      child: const Text('Zur Textstelle'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _showLive,
                    icon: const Icon(Icons.cell_tower, size: 18),
                    label: Text(
                      _live.directing
                          ? 'Du führst'
                          : _live.following
                          ? 'Du folgst'
                          : 'Sitzung öffnen',
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ],
      );
    },
  );
}
