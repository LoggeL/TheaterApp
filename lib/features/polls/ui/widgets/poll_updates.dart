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
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _scheduleDeadline();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      if (_visible) _scheduleDeadline();
    }
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
    DateTime? earliest;
    for (final poll in widget.controller.polls) {
      final close = poll.closesAt;
      if (!poll.closed && close != null && close.isAfter(now)) {
        if (earliest == null || close.isBefore(earliest)) earliest = close;
      }
    }
    if (earliest != null) {
      _deadline = Timer(
        earliest.difference(now) + const Duration(milliseconds: 25),
        _changed,
      );
    }
  }

  void _changed() {
    if (!_visible) return;
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
