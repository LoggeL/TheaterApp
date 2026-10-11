import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';

class GalleryEditor extends StatefulWidget {
  const GalleryEditor({super.key, required this.controller, this.gallery});
  final AppController controller;
  final JsonMap? gallery;
  @override
  State<GalleryEditor> createState() => _GalleryEditorState();
}

class _GalleryEditorState extends State<GalleryEditor> {
  late final TextEditingController _title, _description, _url;
  String? _production, _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    final g = widget.gallery ?? {};
    _title = TextEditingController(text: textValue(g['title']));
    _description = TextEditingController(text: textValue(g['description']));
    _url = TextEditingController(text: textValue(g['sourceUrl']));
    _production = g['productionId'] as String?;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Bitte einen Titel eingeben.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.remote(
        '/galleries',
        method: 'POST',
        body: {
          ...?widget.gallery,
          'title': _title.text,
          'description': _description.text,
          'sourceUrl': _url.text,
          'productionId': _production,
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Listens to the controller so the production list follows a sync.
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => _form(context),
  );

  Widget _form(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.gallery == null ? 'Album anlegen' : 'Album bearbeiten',
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        TextField(
          controller: _title,
          enabled: !_busy,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Albumtitel'),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _url,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Immich-Freigabelink',
            hintText: 'https://photo.rittmann.cloud/s/…',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Ohne Freigabelink kannst du eigene Bilder hochladen.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(
          initialValue:
              widget.controller.productions.any((p) => p.id == _production)
              ? _production
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Stück'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Ohne Zuordnung')),
            for (final p in widget.controller.productions)
              DropdownMenuItem(
                value: p.id,
                child: Text(p.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _busy
              ? null
              : (v) => _production = v?.isEmpty == true ? null : v,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _description,
          enabled: !_busy,
          minLines: 2,
          maxLines: 5,
          maxLength: 2000,
          decoration: const InputDecoration(labelText: 'Beschreibung'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(
            _busy
                ? 'Album wird geprüft …'
                : widget.gallery == null
                ? 'Für das Ensemble freigeben'
                : 'Speichern',
          ),
        ),
      ],
    ),
  );
}
