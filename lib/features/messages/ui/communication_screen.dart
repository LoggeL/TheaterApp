import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/visible_listenable_builder.dart';
import '../../polls/domain/poll_selectors.dart';
import '../../polls/ui/poll_editor_screen.dart';
import '../../polls/ui/polls_screen.dart';
import '../domain/message_selectors.dart';
import 'message_composer_screen.dart';
import 'messages_screen.dart';
import 'push_admin_screen.dart';

/// The Mitteilungen tab of the app shell: messages and polls, switched by a
/// segment below the header.
class CommunicationScreen extends StatefulWidget {
  const CommunicationScreen({
    super.key,
    required this.controller,
    this.showPolls,
  });
  final AppController controller;

  /// The selected segment (true: polls). The shell owns it, so links from
  /// other tabs can open a segment; without it the screen keeps its own.
  final ValueNotifier<bool>? showPolls;
  @override
  State<CommunicationScreen> createState() => _CommunicationScreenState();
}

class _CommunicationScreenState extends State<CommunicationScreen> {
  ValueNotifier<bool>? _own;
  ValueNotifier<bool> get _segment =>
      widget.showPolls ?? (_own ??= ValueNotifier(false));
  bool get _polls => _segment.value;

  @override
  void initState() {
    super.initState();
    _segment.addListener(_changed);
  }

  @override
  void didUpdateWidget(CommunicationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showPolls != widget.showPolls) {
      (oldWidget.showPolls ?? _own)?.removeListener(_changed);
      _segment.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _segment.removeListener(_changed);
    _own?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// One entry point for everything admins can send to the ensemble.
  Future<void> _create() async {
    final c = widget.controller;
    final screen = await showModalBottomSheet<Widget>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Mitteilung'),
              subtitle: const Text('Bleibt im Reiter zum Nachlesen'),
              onTap: () =>
                  Navigator.pop(context, MessageComposerScreen(controller: c)),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Push senden'),
              subtitle: const Text('Kurzer Hinweis, wird nicht gespeichert'),
              onTap: () =>
                  Navigator.pop(context, PushAdminScreen(controller: c)),
            ),
            ListTile(
              leading: const Icon(Icons.poll_outlined),
              title: const Text('Abstimmung'),
              subtitle: const Text('Eine Frage an das Ensemble'),
              onTap: () =>
                  Navigator.pop(context, PollEditorScreen(controller: c)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (screen != null && mounted) await openPage(context, screen);
  }

  @override
  Widget build(BuildContext context) => VisibleListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final unread = unreadMessageCount(c), open = pollsToVote(c).length;
      final switcher = Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<bool>(
          segments: [
            ButtonSegment(
              value: false,
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(
                unread == 0 ? 'Mitteilungen' : 'Mitteilungen · $unread',
              ),
            ),
            ButtonSegment(
              value: true,
              icon: const Icon(Icons.poll_outlined),
              label: Text(
                open == 0 ? 'Abstimmungen' : 'Abstimmungen · $open offen',
              ),
            ),
          ],
          selected: {_polls},
          showSelectedIcon: false,
          onSelectionChanged: (s) => _segment.value = s.single,
        ),
      );
      final create = c.user?.isAdmin == true
          ? FloatingActionButton.extended(
              tooltip: 'Neu erstellen',
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('Neu'),
            )
          : null;
      return _polls
          ? PollsScreen(
              controller: c,
              embedded: true,
              switcher: switcher,
              floatingActionButton: create,
            )
          : MessagesScreen(
              controller: c,
              embedded: true,
              switcher: switcher,
              floatingActionButton: create,
            );
    },
  );
}
