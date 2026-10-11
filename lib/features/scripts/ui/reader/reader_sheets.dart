part of '../script_reader_screen.dart';

/// How the roles sheet picks the highlighted roles.
enum _RolePreset { assigned, all, custom }

/// Scenes, roles, reading settings, printing and refreshing the version.
extension _ReaderSheets on _ScriptReaderScreenState {
  void _showScenes() {
    final doc = _document;
    if (doc == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ReaderSheetFrame(
        title: 'Szenen',
        subtitle: doc.scenes.length == 1
            ? '1 Szene'
            : '${doc.scenes.length} Szenen',
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: doc.scenes.length,
          itemBuilder: (context, index) {
            final scene = doc.scenes[index];
            ScriptCue? first;
            var ownCount = 0;
            for (final cue in doc.cues) {
              if (cue.sceneId != scene.id || !isReadableCue(cue)) continue;
              first ??= cue;
              if (_own(cue)) ownCount++;
            }
            final firstCue = first;
            return ListTile(
              selected: ownCount > 0,
              selectedTileColor: readerAccent.withValues(alpha: 0.08),
              selectedColor: readerAccent,
              leading: ExcludeSemantics(
                child: CircleAvatar(
                  backgroundColor: readerAccent.withValues(
                    alpha: ownCount > 0 ? 0.25 : 0.06,
                  ),
                  foregroundColor: readerAccent,
                  child: Text('${index + 1}'),
                ),
              ),
              title: Text(scene.title),
              subtitle: ownCount == 0
                  ? null
                  : Text(
                      ownCount == 1
                          ? '1 eigener Einsatz'
                          : '$ownCount eigene Einsätze',
                    ),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: firstCue == null
                  ? null
                  : () {
                      Navigator.pop(context);
                      _jumpToScene(scene.id);
                    },
            );
          },
        ),
      ),
    );
  }

  Future<void> _showRoles() async {
    final doc = _document;
    if (doc == null) return;
    final assignedIds = assignedRoleIds(
      doc.roles,
      widget.controller.user?.personId,
    );
    final chosen = Set<String>.from(_roles);
    var assigned = _assignedRoles;
    var preset = _assignedRoles && assignedIds.isNotEmpty
        ? _RolePreset.assigned
        : chosen.isEmpty
        ? _RolePreset.all
        : _RolePreset.custom;
    bool matches(String id, ScriptRole role) =>
        id.toUpperCase() == role.id.toUpperCase() ||
        id.toUpperCase() == role.name.toUpperCase();
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) {
          void choosePreset(_RolePreset? value) => update(() {
            if (value == null) return;
            preset = value;
            switch (value) {
              case _RolePreset.assigned:
                assigned = true;
                chosen
                  ..clear()
                  ..addAll(assignedIds);
              case _RolePreset.all:
                assigned = false;
                chosen.clear();
              case _RolePreset.custom:
                assigned = false;
            }
          });
          return ReaderSheetFrame(
            title: 'Rollen auswählen',
            subtitle: 'Deine Rollen werden im Text hervorgehoben.',
            footer: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(sheet, chosen),
                  child: const Text('Übernehmen'),
                ),
              ),
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                RadioGroup<_RolePreset>(
                  groupValue: preset,
                  onChanged: choosePreset,
                  child: Column(
                    children: [
                      RadioListTile(
                        value: _RolePreset.assigned,
                        enabled: assignedIds.isNotEmpty,
                        title: const Text('Mir zugewiesen'),
                        subtitle: Text(
                          assignedIds.isEmpty
                              ? 'Dir ist in diesem Stück noch keine Rolle zugewiesen. Wähle sie unten selbst aus.'
                              : roleNames(assignedIds, doc.roles).join(', '),
                        ),
                      ),
                      const RadioListTile(
                        value: _RolePreset.all,
                        title: Text('Alle ohne Hervorhebung'),
                      ),
                      const RadioListTile(
                        value: _RolePreset.custom,
                        title: Text('Eigene Auswahl'),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                for (final role in doc.roles)
                  CheckboxListTile(
                    value: chosen.any((r) => matches(r, role)),
                    title: Text(role.name),
                    subtitle: role.actor.isEmpty ? null : Text(role.actor),
                    onChanged: (value) => update(() {
                      assigned = false;
                      chosen.removeWhere((r) => matches(r, role));
                      if (value == true) chosen.add(role.id);
                      preset = chosen.isEmpty
                          ? _RolePreset.all
                          : _RolePreset.custom;
                    }),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (result == null || !mounted) return;
    _update(() {
      _roles = result;
      _role = result.firstOrNull ?? '';
      _assignedRoles = assigned;
      _revealed.clear();
      if (!_hasRoles && _mode.needsRoles) _mode = ReaderMode.read;
      _rebuildEntries();
    });
    _preference('roles', result.toList());
    _preference('role', _role);
    _preference('assignedRoles', assigned);
    _preference('mode', _mode.code);
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => ReaderSheetFrame(
          title: 'Leseeinstellungen',
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Schriftgröße · ${(_fontScale * 100).round()} %',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Slider(
                    value: _fontScale,
                    min: .85,
                    max: 1.6,
                    divisions: 15,
                    label: '${(_fontScale * 100).round()} %',
                    onChanged: (v) {
                      _update(() => _fontScale = v);
                      update(() {});
                    },
                    onChangeEnd: (v) => _preference('fontScale', v),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Kontext um eigene Texte · $_contextLines Zeilen',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Slider(
                    value: _contextLines.toDouble(),
                    min: 0,
                    max: 6,
                    divisions: 6,
                    label: '$_contextLines',
                    onChanged: (v) {
                      _update(() {
                        _contextLines = v.round();
                        _rebuildEntries();
                      });
                      update(() {});
                    },
                    onChangeEnd: (v) => _preference('contextLines', v.round()),
                  ),
                  const SizedBox(height: 20),
                  for (final category in cueCategories.entries)
                    Column(
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(category.value.setting),
                          value: _categories.contains(category.key),
                          onChanged: (enabled) {
                            _update(() {
                              if (enabled) {
                                _categories.add(category.key);
                              } else {
                                _categories.remove(category.key);
                              }
                              _showDirections = _categories.contains(
                                'direction',
                              );
                              _showTechnical = _categories.any(
                                (c) => c != 'direction',
                              );
                              _rebuildEntries();
                            });
                            update(() {});
                            _preference('categories', _categories.toList());
                            _preference('showTechnical', _showTechnical);
                            _preference('showDirections', _showDirections);
                          },
                        ),
                        if (_mode == ReaderMode.cues &&
                            _categories.contains(category.key))
                          Row(
                            children: [
                              const Expanded(child: Text('Kontextzeilen')),
                              DropdownButton<int>(
                                value: _categoryContext[category.key] ?? 0,
                                items: [
                                  for (var i = 0; i <= 6; i++)
                                    DropdownMenuItem(
                                      value: i,
                                      child: Text('$i'),
                                    ),
                                ],
                                onChanged: (v) {
                                  _update(() {
                                    _categoryContext[category.key] = v!;
                                    _rebuildEntries();
                                  });
                                  update(() {});
                                  _preference(
                                    'categoryContext',
                                    _categoryContext,
                                  );
                                },
                              ),
                            ],
                          ),
                      ],
                    ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheet),
                      child: const Text('Fertig'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Loads the newest version and says what happened.
  Future<void> _refreshScript() async {
    final before = _document?.revision;
    await _load();
    if (!mounted) return;
    final doc = _document;
    if (doc == null) return;
    final failed =
        _loadError != null || doc.stale || widget.controller.error != null;
    _notice(
      failed
          ? 'Aktualisierung fehlgeschlagen – gespeicherte Fassung bleibt lesbar'
          : doc.revision != before
          ? 'Neue Fassung geladen'
          : 'Du hast bereits die aktuelle Fassung',
    );
  }

  Future<void> _exportPdf() async {
    final doc = _document;
    if (doc == null || _printing) return;
    final full = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => ReaderSheetFrame(
        title: 'Drucken / PDF',
        subtitle: 'Was soll ins PDF?',
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Ganzes Drehbuch'),
              onTap: () => Navigator.pop(sheet, true),
            ),
            ListTile(
              leading: const Icon(Icons.filter_alt_outlined),
              title: const Text('Aktuelle Auswahl'),
              subtitle: const Text('Mit deinen Rollen- und Kategoriefiltern'),
              onTap: () => Navigator.pop(sheet, false),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (full == null || !mounted) return;
    _update(() => _printing = true);
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('PDF wird erstellt …'),
        duration: Duration(minutes: 1),
      ),
    );
    final names = roleNames(_roles, doc.roles);
    try {
      await exportScriptPdf(
        title: _title,
        entries: full
            ? readerEntries(doc, doc.cues.where(isReadableCue))
            : _entries,
        footer: switch (names.length) {
          0 => 'Alle Rollen',
          1 => 'Rolle: ${names.single}',
          _ => 'Rollen: ${names.join(', ')}',
        },
        isOwn: _own,
      );
      messenger.hideCurrentSnackBar();
    } catch (_) {
      messenger.hideCurrentSnackBar();
      _notice(
        'Das PDF konnte nicht erstellt werden. Bitte versuche es erneut.',
      );
    } finally {
      if (mounted) _update(() => _printing = false);
    }
  }
}
