import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/widgets/one_line_segmented_button.dart';
import '../../../shared/widgets/page_header.dart';
import '../data/feedback_api.dart';
import '../domain/feedback_entry.dart';
import 'feedback_category_icon.dart';

/// Lets a member send an idea, a bug report or anything else about the app
/// to the admins.
class FeedbackFormScreen extends StatefulWidget {
  const FeedbackFormScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<FeedbackFormScreen> createState() => _FeedbackFormScreenState();
}

class _FeedbackFormScreenState extends State<FeedbackFormScreen> {
  final _message = TextEditingController();
  String _category = 'idea';
  bool _busy = false, _sent = false;
  String? _error;

  AppController get controller => widget.controller;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  String get _text => _message.text.trim();

  bool get _canSend =>
      !_busy &&
      !controller.isOffline &&
      _text.isNotEmpty &&
      _text.length <= feedbackMaxLength;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await submitFeedback(controller, message: _text, category: _category);
      if (!mounted) return;
      setState(() {
        _sent = true;
        _message.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _again() => setState(() {
    _sent = false;
    _category = 'idea';
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => DiscardGuard(
      dirty: !_busy && _text.isNotEmpty,
      child: Scaffold(
        appBar: AppBar(title: const Text('Feedback geben')),
        body: ListView(
          padding: pagePadding(context),
          children: _sent ? _thanks(context) : _form(context),
        ),
      ),
    ),
  );

  List<Widget> _thanks(BuildContext context) {
    final theme = Theme.of(context);
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(
                Icons.check_circle_outline,
                size: 48,
                color: StageTheme.green,
              ),
              const SizedBox(height: 16),
              Text(
                'Danke für dein Feedback!',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Es ist bei der Theaterleitung angekommen und wird dort gelesen.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton(
                    onPressed: () => Navigator.maybePop(context),
                    child: const Text('Fertig'),
                  ),
                  OutlinedButton(
                    onPressed: _again,
                    child: const Text('Weiteres Feedback senden'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _form(BuildContext context) {
    final theme = Theme.of(context);
    return [
      const PageHeader(
        'Feedback',
        eyebrow: 'Deine Meinung zählt',
        subtitle:
            'Eine Idee, ein Fehler oder etwas, das dich stört? Schreib es '
            'hier auf – die Theaterleitung sieht es mit deinem Namen.',
      ),
      const SectionTitle('Worum geht es?'),
      SizedBox(
        width: double.infinity,
        child: OneLineSegmentedButton<String>(
          key: const ValueKey('feedback-category'),
          showSelectedIcon: false,
          segments: [
            for (final category in feedbackCategories)
              ButtonSegment(
                value: category,
                label: Text(feedbackCategoryLabel(category)),
                icon: Icon(feedbackCategoryIcon(category)),
              ),
          ],
          selected: {_category},
          onSelectionChanged: _busy
              ? null
              : (value) => setState(() => _category = value.single),
        ),
      ),
      const SizedBox(height: 20),
      TextField(
        key: const ValueKey('feedback-message'),
        controller: _message,
        enabled: !_busy,
        decoration: InputDecoration(
          labelText: 'Deine Nachricht',
          alignLabelWithHint: true,
          hintText: switch (_category) {
            'bug' => 'Was ist passiert, und was hast du davor gemacht?',
            'idea' => 'Was würde dir die Arbeit mit der App erleichtern?',
            _ => 'Was möchtest du der Theaterleitung mitteilen?',
          },
        ),
        minLines: 5,
        maxLines: 12,
        maxLength: feedbackMaxLength,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() => _error = null),
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: _canSend ? _send : null,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_outlined),
          label: Text(_busy ? 'Wird gesendet …' : 'Feedback senden'),
        ),
      ),
      if (_text.length > feedbackMaxLength) ...[
        const SizedBox(height: 12),
        Text(
          'Bitte kürze den Text auf höchstens $feedbackMaxLength Zeichen.',
          style: theme.textTheme.bodySmall,
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(
          _error!,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
      if (controller.isOffline) ...[
        const SizedBox(height: 12),
        Text(
          'Zum Senden wird eine Verbindung zum Server benötigt.',
          style: theme.textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: 16),
      Text(
        'Mitgesendet werden dein Name, die App-Version und die Plattform '
        '(Android, iOS oder Web), damit Fehler leichter nachvollziehbar sind.',
        style: theme.textTheme.bodySmall,
      ),
    ];
  }
}
