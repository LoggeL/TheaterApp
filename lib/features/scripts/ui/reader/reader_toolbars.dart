part of '../script_reader_screen.dart';

/// Search, mode toolbar, bottom bar and the banners above the text.
extension _ReaderToolbars on _ScriptReaderScreenState {
  void _setSearching(bool open) {
    _update(() => _searching = open);
    if (open) {
      _searchFocus.requestFocus();
    } else {
      _searchTimer?.cancel();
      _searchController.clear();
      _search('');
    }
  }

  void _search(String query) {
    final needle = query.toLowerCase().trim();
    _update(() {
      _searchResults = needle.isEmpty
          ? []
          : (_document?.cues ?? <ScriptCue>[])
                .where(
                  (cue) =>
                      isReadableCue(cue) &&
                      '${cue.role} ${cue.text}'.toLowerCase().contains(needle),
                )
                .toList();
      _searchResultIndex = 0;
    });
    if (_searchResults.isNotEmpty) _jumpToCue(_searchResults.first.id);
  }

  void _nextSearchResult(int delta) {
    if (_searchResults.isEmpty) return;
    _update(
      () => _searchResultIndex =
          (_searchResultIndex + delta) % _searchResults.length,
    );
    _jumpToCue(_searchResults[_searchResultIndex].id);
  }

  Widget _buildSearch(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocus,
            onChanged: (query) {
              _searchTimer?.cancel();
              _searchTimer = Timer(
                const Duration(milliseconds: 180),
                () => _search(query),
              );
            },
            textInputAction: TextInputAction.search,
            // Enter moves to the next hit and keeps the field focused.
            onEditingComplete: () {},
            onSubmitted: (query) {
              if (_searchTimer?.isActive == true) {
                _searchTimer!.cancel();
                _search(query);
              } else {
                _nextSearchResult(1);
              }
            },
            decoration: InputDecoration(
              hintText: 'Text oder Rolle suchen',
              prefixIcon: const Icon(Icons.search),
              suffixText: _searchController.text.isEmpty
                  ? null
                  : _searchResults.isEmpty
                  ? '0 Treffer'
                  : '${_searchResultIndex + 1}/${_searchResults.length}',
              isDense: true,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Vorheriger Treffer',
          onPressed: _searchResults.isEmpty
              ? null
              : () => _nextSearchResult(-1),
          icon: const Icon(Icons.keyboard_arrow_up),
        ),
        IconButton(
          tooltip: 'Nächster Treffer',
          onPressed: _searchResults.isEmpty ? null : () => _nextSearchResult(1),
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
      ],
    ),
  );

  String get _rolesButtonLabel {
    final label = roleLabel(_roles, _document?.roles ?? const []);
    return label.isEmpty ? 'Meine Rollen' : label;
  }

  Widget _buildToolbar(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_desktopReader(context, constraints.maxWidth)) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mode in ReaderMode.values)
                      Tooltip(
                        message: mode.description,
                        child: ChoiceChip(
                          key: ValueKey('reader-mode-${mode.code}'),
                          label: Text(mode.label),
                          selected: _mode == mode,
                          onSelected: (_) => _changeMode(mode),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              TextButton.icon(
                onPressed: _showRoles,
                icon: const Icon(Icons.person_outline, size: 18),
                label: Text(_rolesButtonLabel),
              ),
            ],
          ),
        );
      }
      return _buildMobileToolbar(context);
    },
  );

  Widget _buildMobileToolbar(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    child: Row(
      children: [
        TextButton.icon(
          onPressed: _showScenes,
          icon: const Icon(Icons.list_rounded, size: 18),
          label: const Text('Szenen'),
        ),
        const Spacer(),
        Flexible(
          child: TextButton(
            onPressed: _showRoles,
            child: Text(_rolesButtonLabel, overflow: TextOverflow.ellipsis),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Lesemodus',
          initialValue: _mode.code,
          onSelected: (code) => _changeMode(ReaderMode.fromCode(code)),
          itemBuilder: (context) => [
            for (final mode in ReaderMode.values)
              CheckedPopupMenuItem(
                value: mode.code,
                checked: _mode == mode,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(mode.label),
                    Text(
                      mode.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_mode.label),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more, size: 18),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  void _jumpOwn(int direction) {
    final cues = _entries
        .where((e) => e.cue != null && _own(e.cue!))
        .map((e) => e.cue!)
        .toList();
    if (cues.isEmpty) {
      if (_hasRoles) {
        _notice('In dieser Ansicht gibt es keine Einsätze deiner Rollen.');
      } else {
        _showRoles();
      }
      return;
    }
    final current = _cueIndices[_firstVisibleCueId] ?? 0;
    final options = cues
        .where(
          (c) => direction > 0
              ? (_cueIndices[c.id] ?? 0) > current
              : (_cueIndices[c.id] ?? 0) < current,
        )
        .toList();
    final cue = options.isEmpty
        ? (direction > 0 ? cues.first : cues.last)
        : (direction > 0 ? options.first : options.last);
    _jumpToCue(cue.id);
  }

  Widget _buildBottomBar(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: .15),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_hasRoles) ...[
            IconButton(
              tooltip: 'Voriger Einsatz',
              onPressed: () => _jumpOwn(-1),
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            IconButton(
              tooltip: 'Nächster Einsatz',
              onPressed: () => _jumpOwn(1),
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ] else
            Flexible(
              child: TextButton.icon(
                onPressed: _showRoles,
                icon: const Icon(Icons.person_search_outlined, size: 20),
                label: const Text(
                  'Rolle wählen',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Lesezeichen öffnen',
            onPressed: _showBookmarks,
            icon: Icon(
              _bookmarks.isEmpty ? Icons.bookmark_border : Icons.bookmark,
              size: 22,
            ),
          ),
          IconButton(
            tooltip: 'Private Notizen',
            onPressed: _showNotes,
            icon: const Icon(Icons.edit_note),
          ),
          IconButton(
            tooltip: 'Leseeinstellungen',
            onPressed: _showSettings,
            icon: const Icon(Icons.text_fields_rounded),
          ),
        ],
      ),
    ),
  );

  Widget _buildLiveBanner(BuildContext context) => Material(
    color: readerAccent.withValues(alpha: 0.12),
    child: ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(
        _live.directing ? Icons.cell_tower : Icons.sync,
        color: readerAccent,
        size: 19,
      ),
      title: Text(
        _live.error ??
            (widget.controller.isDemo
                ? 'Demo-Fokus · nur dieses Gerät'
                : _live.directing
                ? 'Du führst · Text antippen, um den Fokus zu teilen'
                : _live.focus?.cueId == null
                ? 'Warte auf den gemeinsamen Fokus'
                : 'Du folgst dem gemeinsamen Fokus'),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: IconButton(
        tooltip: 'Fokus beenden',
        icon: const Icon(Icons.close, size: 19),
        onPressed: _live.stop,
      ),
    ),
  );

  /// A one-time hint on phones, where the cue actions hide behind a long
  /// press.
  Widget _buildCueHint(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer.withValues(alpha: .5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.touch_app_outlined, size: 20, color: scheme.secondary),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Tipp: Halte eine Textstelle gedrückt – für Notiz, Kommentar, Lesezeichen und Kopieren.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () {
                _update(() => _hintDismissed = true);
                widget.controller
                    .setPreference(ReaderPreferences.hintCueActionsKey, true)
                    .catchError((_) {});
              },
              child: const Text('Verstanden'),
            ),
          ],
        ),
      ),
    );
  }
}
