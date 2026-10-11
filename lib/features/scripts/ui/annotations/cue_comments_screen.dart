import 'package:flutter/material.dart';

import '../../../../app/theme/stage_theme.dart';
import '../../../../core/app_controller.dart';
import '../../../../core/models.dart';
import '../../../../shared/feedback.dart';
import '../../../../shared/widgets/state_pill.dart';
import '../../data/comments_repository.dart';
import '../../domain/reader_entries.dart';

/// "vor 5 Minuten", "gestern, 18:30" or a date: when a comment was written.
String commentTime(DateTime at, DateTime now) {
  final local = at.toLocal(), current = now.toLocal();
  final diff = current.difference(local);
  String two(int value) => value.toString().padLeft(2, '0');
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(current.year, current.month, current.day);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) {
    return diff.inMinutes == 1
        ? 'vor 1 Minute'
        : 'vor ${diff.inMinutes} Minuten';
  }
  if (day == today) {
    return diff.inHours == 1 ? 'vor 1 Stunde' : 'vor ${diff.inHours} Stunden';
  }
  if (today.difference(day).inDays == 1) {
    return 'gestern, ${two(local.hour)}:${two(local.minute)}';
  }
  return '${local.day}.${local.month}.${local.year}';
}

class CueCommentsScreen extends StatefulWidget {
  const CueCommentsScreen({
    super.key,
    required this.controller,
    required this.document,
    required this.cue,
    this.repository,
  });
  final AppController controller;
  final ScriptDocument document;
  final ScriptCue cue;

  /// The reader's shared comments; without one the page loads its own.
  final CommentsRepository? repository;
  @override
  State<CueCommentsScreen> createState() => _CueCommentsScreenState();
}

class _CueCommentsScreenState extends State<CueCommentsScreen> {
  final _text = TextEditingController();
  late final CommentsRepository _repository =
      widget.repository ??
      CommentsRepository(
        controller: widget.controller,
        productionId: widget.document.productionId,
      );
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _repository.ensureLoaded();
  }

  @override
  void dispose() {
    _text.dispose();
    if (widget.repository == null) _repository.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final outcome = await _repository.add(
        revision: widget.document.revision,
        cueId: widget.cue.id,
        text: text,
      );
      _text.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        showDone(
          context,
          outcomeText(
            outcome,
            done: 'Kommentar gespeichert',
            queued: 'Kommentar vorgemerkt – wird bei Verbindung gesendet',
          ),
        );
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(CueComment comment) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Kommentar löschen?',
      message: 'Der Kommentar wird für das ganze Ensemble entfernt.',
      confirmLabel: 'Löschen',
    );
    if (!confirmed || !mounted) return;
    try {
      final outcome = await _repository.delete(comment.id);
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        showDone(
          context,
          outcomeText(
            outcome,
            done: 'Kommentar gelöscht',
            queued: 'Löschen vorgemerkt – wird bei Verbindung übertragen',
          ),
        );
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Kommentare')),
    body: ListenableBuilder(
      listenable: Listenable.merge([widget.controller, _repository, _text]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final comments = _repository.forCue(widget.cue.id);
        final user = widget.controller.user;
        return Column(
          children: [
            if (_repository.loading) const LinearProgressIndicator(),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Text(
                        [
                          sceneTitle(widget.document, widget.cue.sceneId),
                          if (widget.cue.role.isNotEmpty) widget.cue.role,
                        ].join(' · '),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.cue.text,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 24),
                      if (_repository.error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _repository.error!,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: _repository.reload,
                                child: const Text('Erneut laden'),
                              ),
                            ],
                          ),
                        ),
                      if (widget.controller.isDemo)
                        const Text(
                          'Kommentare gibt es nur mit einem verbundenen Theaterkonto.',
                        )
                      else if (comments.isEmpty && _repository.loaded)
                        Text(
                          'Noch keine Kommentare – schreib den ersten für das Ensemble.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      for (final c in comments)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text.rich(
                                          TextSpan(
                                            text: c.authorName.isEmpty
                                                ? 'Ensemble'
                                                : c.authorName,
                                            style: theme.textTheme.titleSmall,
                                            children: [
                                              if (c.createdAt != null)
                                                TextSpan(
                                                  text:
                                                      ' · ${commentTime(c.createdAt!, widget.controller.now)}',
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: theme
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      if (c.authorId == user?.personId ||
                                          user?.isAdmin == true)
                                        IconButton(
                                          tooltip: 'Kommentar löschen',
                                          onPressed: () => _delete(c),
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 20,
                                          ),
                                        )
                                      else
                                        const SizedBox(height: 40),
                                    ],
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Text(c.text),
                                  ),
                                  if (c.revision != widget.document.revision)
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
                    ],
                  ),
                ),
              ),
            ),
            _buildComposer(context),
          ],
        );
      },
    ),
  );

  /// The input pinned to the bottom, or why commenting is not possible.
  Widget _buildComposer(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: _repository.canWrite
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _text,
                            enabled: !_sending,
                            minLines: 1,
                            maxLines: 5,
                            maxLength: 3000,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                              labelText: 'Kommentar für das Ensemble',
                              counterText: '',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: 'Kommentieren',
                          onPressed: _sending || _text.text.trim().isEmpty
                              ? null
                              : _send,
                          icon: _sending
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_outlined),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Icon(
                          controller.isDemo
                              ? Icons.info_outline
                              : Icons.cloud_off_outlined,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            controller.isDemo
                                ? 'In der Demo kannst du keine Kommentare schreiben.'
                                : 'Offline – kommentieren kannst du, sobald wieder eine Verbindung besteht.',
                            style: theme.textTheme.bodyMedium,
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
}
