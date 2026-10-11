import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/app_controller.dart';

class PollUpdates extends StatefulWidget {
  const PollUpdates({
    super.key,
    required this.controller,
    required this.builder,
  });
  final AppController controller;
  final TransitionBuilder builder;
  @override
  State<PollUpdates> createState() => _PollUpdatesState();
}

class _PollUpdatesState extends State<PollUpdates> {
  Timer? _deadline;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _scheduleDeadline();
  }

  @override
  void didUpdateWidget(PollUpdates oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _scheduleDeadline();
  }

  void _scheduleDeadline() {
    _deadline?.cancel();
    final now = widget.controller.now;
    final deadlines =
        widget.controller.polls
            .where(
              (poll) => !poll.closed && poll.closesAt?.isAfter(now) == true,
            )
            .map((poll) => poll.closesAt!)
            .toList()
          ..sort();
    if (deadlines.isNotEmpty) {
      _deadline = Timer(
        deadlines.first.difference(now) + const Duration(milliseconds: 25),
        _changed,
      );
    }
  }

  void _changed() {
    _scheduleDeadline();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _deadline?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, null);
}
