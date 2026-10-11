import 'package:flutter/material.dart';

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
