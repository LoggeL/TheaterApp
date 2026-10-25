import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';
import '../data/forms_api.dart';
import '../domain/form_presets.dart';
import 'form_editor_screen.dart';

/// Reusable forms, also used as the message composer's form selector.
class FormsAdminScreen extends StatefulWidget {
  const FormsAdminScreen({
    super.key,
    required this.controller,
    this.selectMode = false,
  });
  final AppController controller;
  final bool selectMode;

  @override
  State<FormsAdminScreen> createState() => _FormsAdminScreenState();
}

class _FormsAdminScreenState extends State<FormsAdminScreen> {
  List<JsonMap> _templates = [];
  bool _loading = true, _showArchived = false, _busy = false;
  bool _sessionEnded = false;
  late final String? _owner;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _owner = widget.controller.user?.id;
    widget.controller.addListener(_sessionChanged);
    _load();
  }

  void _sessionChanged() {
    if (_sessionEnded ||
        (widget.controller.user?.id == _owner &&
            widget.controller.hasAccess &&
            widget.controller.user?.isAdmin == true)) {
      return;
    }
    setState(() {
      _sessionEnded = true;
      _templates = [];
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sessionChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (_sessionEnded || widget.controller.user?.isAdmin != true) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final templates = await FormsApi(widget.controller).templates();
      if (mounted && !_sessionEnded) setState(() => _templates = templates);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([JsonMap? template]) async {
    String? starter;
    if (template == null) {
      starter = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: const Text('Leeres Formular'),
                subtitle: const Text('Eigene Fragen zusammenstellen'),
                onTap: () => Navigator.pop(sheetContext, 'blank'),
              ),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Probenfreizeit'),
                subtitle: const Text(
                  'Anmeldung mit Unterschrift als Startvorlage',
                ),
                onTap: () => Navigator.pop(sheetContext, 'rehearsal'),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
      if (!mounted || _sessionEnded || starter == null) return;
    }
    final saved = await openPage<JsonMap>(
      context,
      FormEditorScreen(
        controller: widget.controller,
        template: template,
        initialDefinition: starter == 'rehearsal'
            ? rehearsalWeekendPreset()
            : null,
        requireDescription: starter == 'rehearsal',
        requireDeleteAfter: starter == 'rehearsal',
      ),
    );
    if (!mounted || _sessionEnded || saved == null) return;
    if (widget.selectMode && saved['archived'] != true) {
      Navigator.pop(context, saved);
    } else {
      await _load();
    }
  }

  Future<void> _archive(JsonMap template) async {
    final archived = template['archived'] == true;
    final confirmed = await confirmAction(
      context,
      title: archived ? 'Formular wieder verwenden?' : 'Formular archivieren?',
      message: archived
          ? 'Das Formular kann danach wieder an neue Mitteilungen angehängt werden.'
          : 'Das Formular verschwindet aus der Auswahl für neue Mitteilungen. Bereits verschickte Formulare und Antworten bleiben erhalten.',
      confirmLabel: archived ? 'Wieder verwenden' : 'Archivieren',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await FormsApi(widget.controller).archive(template, !archived);
      if (!mounted) return;
      showDone(
        context,
        archived ? 'Formular wieder verfügbar.' : 'Formular archiviert.',
      );
      await _load();
    } catch (error) {
      if (mounted) showProblem(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionEnded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Formulare')),
        body: const Center(child: Text('Bitte die Formulare erneut öffnen.')),
      );
    }
    final templates = _templates
        .where((form) => _showArchived || form['archived'] != true)
        .toList();
    return AdminPage(
      controller: widget.controller,
      title: widget.selectMode ? 'Formular auswählen' : 'Formulare',
      onRefresh: _load,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Formular erstellen'),
      ),
      children: (context) => [
        Text(
          widget.selectMode
              ? 'Wähle ein gespeichertes Formular oder erstelle ein neues. Mitglieder füllen es direkt in der Mitteilung aus.'
              : 'Erstelle Formulare direkt in der App und hänge sie an Mitteilungen an. Die abgegebenen Antworten findest du bei der jeweiligen Mitteilung.',
        ),
        const SizedBox(height: 16),
        if (!widget.selectMode &&
            _templates.any((form) => form['archived'] == true))
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Archivierte anzeigen'),
            value: _showArchived,
            onChanged: (value) => setState(() => _showArchived = value),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null) ...[
          const EmptyState(
            icon: Icons.cloud_off_outlined,
            title: 'Formulare nicht geladen',
            message:
                'Zum Laden und Bearbeiten der Formulare brauchst du eine Verbindung.',
          ),
          OutlinedButton(
            onPressed: _load,
            child: const Text('Erneut versuchen'),
          ),
        ] else if (templates.isEmpty)
          const EmptyState(
            icon: Icons.description_outlined,
            title: 'Noch keine Formulare',
            message:
                'Ein Formular besteht aus deinen Fragen und einer Bestätigung bei der Abgabe. Eine Unterschrift kannst du ergänzen.',
          )
        else
          for (final template in templates) _tile(template),
      ],
    );
  }

  Widget _tile(JsonMap template) {
    final archived = template['archived'] == true;
    final fields = jsonList(template['fields']).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(
          archived ? Icons.archive_outlined : Icons.description_outlined,
        ),
        title: Text(textValue(template['title'])),
        subtitle: Text(
          [
            '$fields ${fields == 1 ? 'Feld' : 'Felder'}',
            if (template['signatureRequired'] == true) 'mit Unterschrift',
            if (archived) 'Archiviert',
          ].join(' · '),
        ),
        onTap: _busy
            ? null
            : () {
                if (widget.selectMode && !archived) {
                  Navigator.pop(context, template);
                } else {
                  _edit(template);
                }
              },
        trailing: PopupMenuButton<String>(
          enabled: !_busy,
          tooltip: 'Formular verwalten',
          onSelected: (action) {
            if (action == 'edit') _edit(template);
            if (action == 'archive') _archive(template);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
            PopupMenuItem(
              value: 'archive',
              child: Text(archived ? 'Wieder verwenden' : 'Archivieren'),
            ),
          ],
        ),
      ),
    );
  }
}
