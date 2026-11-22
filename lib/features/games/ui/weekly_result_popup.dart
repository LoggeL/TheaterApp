import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../data/weekly_api.dart';

/// App-wide inbox, owned by the signed-in shell rather than the weekly page.
/// Never interrupts a pushed page (especially a run) or another dialog.
class WeeklyResultHost extends StatefulWidget {
  const WeeklyResultHost({
    super.key,
    required this.controller,
    required this.child,
    this.beforeCheck,
  });
  final AppController controller;
  final Widget child;
  final Future<void> Function()? beforeCheck;

  @override
  State<WeeklyResultHost> createState() => _WeeklyResultHostState();
}

class _WeeklyResultHostState extends State<WeeklyResultHost>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _ready = false, _checking = false;
  DateTime? _nextCheck;
  Object get _identity => (
    widget.controller.apiBaseUrl,
    widget.controller.user?.id,
    widget.controller.sessionEpoch,
  );
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool get _eligible =>
      widget.controller.hasAccess &&
      !widget.controller.isDemo &&
      widget.controller.supports('runnerWeeklyResults');
  bool get _canShow =>
      mounted && _foreground && (ModalRoute.of(context)?.isCurrent ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.beforeCheck?.call();
      if (!mounted) return;
      _ready = true;
      unawaited(_check());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  void _schedule() {
    _timer?.cancel();
    if (!mounted || !_foreground) return;
    // Retry network failures/covered routes, and discover newly enabled features.
    // The server supplies the exact Berlin week boundary (including DST).
    final until = _nextCheck?.difference(widget.controller.now);
    final delay =
        until != null &&
            until > Duration.zero &&
            until < const Duration(minutes: 1)
        ? until
        : const Duration(minutes: 1);
    _timer = Timer(delay, () => unawaited(_check()));
  }

  Future<void> _check() async {
    if (!_ready || _checking || !mounted) return;
    _checking = true;
    final identity = _identity;
    bool current() => mounted && identity == _identity && _eligible;
    try {
      if (!_eligible || !_canShow) return;
      final data = await widget.controller.remote(
        '/games/runner/weekly/results',
      );
      if (!current() || !_canShow) return;
      _nextCheck = DateTime.tryParse(textValue(data['nextCheckAt']));
      for (final raw in jsonList(data['results'])) {
        if (!mounted || raw is! Map || !current() || !_canShow) break;
        final result = WeeklyLastWeek.fromJson(jsonMap(raw));
        final acknowledged = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _ResultDialog(
            result: result,
            acknowledge: () async {
              if (!current()) {
                throw StateError('Die Sitzung hat sich geändert.');
              }
              await markWeeklySeen(widget.controller, result.week);
            },
          ),
        );
        if (acknowledged != true || !current()) break;
      }
    } catch (_) {
      // Offline: keep all unseen results on the server and try on resume/timer.
    } finally {
      _checking = false;
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ResultDialog extends StatefulWidget {
  const _ResultDialog({required this.result, required this.acknowledge});
  final WeeklyLastWeek result;
  final Future<void> Function() acknowledge;

  @override
  State<_ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<_ResultDialog> {
  bool _busy = false, _failed = false;

  Future<void> _dismiss() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.acknowledge();
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const ValueKey('weekly-result-popup'),
        title: const Text('Wochenprobe: Dein Ergebnis'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Woche ${r.week}'),
              const SizedBox(height: 12),
              Text('Platz ${r.rank} · ${r.score} Punkte'),
              if (r.trophy case final trophy?) Text(trophy.title),
              if (r.gage > 0) Text('+${r.gage} Gage'),
              if (r.crates > 0)
                Text(
                  '${r.crates} ${r.crates == 1 ? 'Wochenkiste' : 'Wochenkisten'}',
                ),
              const SizedBox(height: 12),
              const Text('Deine Belohnung ist bereits gutgeschrieben.'),
              if (_failed) ...[
                const SizedBox(height: 12),
                const Text(
                  'Bestätigung nicht gespeichert. Bitte erneut versuchen.',
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: _busy ? null : _dismiss,
            child: Text(_busy ? 'Wird gespeichert …' : 'Verstanden'),
          ),
        ],
      ),
    );
  }
}
