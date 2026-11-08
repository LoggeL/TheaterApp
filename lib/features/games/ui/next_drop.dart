import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../data/wardrobe_api.dart' show NextDrop, nextDropClock;

/// The countdown to the next content drop ([NextDrop]): a card at the top of
/// the game menu ([NextDropCard]) and a line in the wardrobe header
/// ([NextDropLine]). Both count every second while they are visible and ask
/// for a fresh wardrobe ([DropDue]) when the countdown reaches zero.

/// [remaining] as "HH:MM:SS", rounded up to the second so the last second
/// shows "00:00:01" and zero is the start itself; nothing below zero.
String dropCountdown(Duration remaining) {
  final micros = remaining.inMicroseconds;
  final seconds = micros <= 0
      ? 0
      : (micros + Duration.microsecondsPerSecond - 1) ~/
            Duration.microsecondsPerSecond;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(seconds ~/ 3600)}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
}

/// What the countdown says [remaining] before [drop]: the time left while
/// there is some, then whether the drop is there or still on its way (a pack
/// waiting for its pictures, `ready: false`).
String dropText(NextDrop drop, Duration remaining) {
  final name = drop.name.trim();
  final named = name.isEmpty ? '' : ' · $name';
  if (remaining > Duration.zero) {
    return 'Neue Kostüme in ${dropCountdown(remaining)}$named';
  }
  return drop.ready
      ? 'Neue Kostüme sind da$named'
      : 'Gleich soll es so weit sein …';
}

/// How long to wait from [remaining] until the shown second changes: the
/// fraction to the next whole second, at most one second.
Duration dropTickDelay(Duration remaining) {
  if (remaining <= Duration.zero) return const Duration(seconds: 1);
  final rest = remaining.inMicroseconds % Duration.microsecondsPerSecond;
  return Duration(
    microseconds: rest == 0 ? Duration.microsecondsPerSecond : rest,
  );
}

/// Asked when a countdown reaches zero: brings a fresh wardrobe and says
/// whether it came (false: offline, an error, not now).
typedef DropDue = Future<bool> Function();

/// The drops whose [NextDropTicker.onDue] brought a fresh wardrobe (true)
/// or is under way (false). Kept beside the drop rather than in a ticker, so
/// a countdown that reached zero while none showed it (during a run,
/// scrolled out of view) still asks once one shows it again.
final _dueAsked = Expando<bool>('nextDropDue');

/// Rebuilds [builder] once a second while [drop] counts down and calls
/// [onDue] when it is due: at zero on screen, or as soon as it shows when
/// zero passed unseen. Only for a reply from before the start
/// ([NextDrop.countsDown]): one that came after it is fresh. A failed
/// [onDue] is asked again after a while. One timer, nothing per frame; none
/// while a route covers it ([TickerMode] off) and none once due.
class NextDropTicker extends StatefulWidget {
  const NextDropTicker({
    super.key,
    required this.drop,
    required this.builder,
    this.onDue,
    this.clock,
  });

  final NextDrop drop;
  final Widget Function(BuildContext context, String text, Duration remaining)
  builder;
  final DropDue? onDue;

  /// The monotonic clock [NextDrop.receivedAt] was taken by
  /// ([nextDropClock] unless given).
  final Duration Function()? clock;

  /// How long a failed [onDue] waits before it is asked again.
  @visibleForTesting
  static Duration retryDelay = const Duration(seconds: 15);

  @override
  State<NextDropTicker> createState() => _NextDropTickerState();
}

class _NextDropTickerState extends State<NextDropTicker> {
  Timer? _timer, _retry;
  ValueListenable<TickerModeData>? _ticking;

  Duration get _remaining =>
      widget.drop.remainingAt((widget.clock ?? nextDropClock)());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticking = TickerMode.getValuesNotifier(context);
    if (!identical(ticking, _ticking)) {
      _ticking?.removeListener(_tickingChanged);
      _ticking = ticking..addListener(_tickingChanged);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(NextDropTicker old) {
    super.didUpdateWidget(old);
    // A fresh reply counts anew, without the wait of a failed one.
    if (!identical(old.drop, widget.drop)) {
      _retry?.cancel();
      _retry = null;
    }
    _schedule();
  }

  // Called while the route above changes, maybe during a build: no state
  // here, the next tick (within a second) shows the time of then.
  void _tickingChanged() => _schedule();

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final remaining = _remaining;
    if (remaining <= Duration.zero) {
      _due();
      return;
    }
    if (!(_ticking?.value.enabled ?? true)) return;
    _timer = Timer(dropTickDelay(remaining), _tick);
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    _schedule();
  }

  void _due() {
    final drop = widget.drop, onDue = widget.onDue;
    if (onDue == null ||
        !drop.countsDown ||
        _dueAsked[drop] != null ||
        _retry != null) {
      return;
    }
    _dueAsked[drop] = false;
    // After this frame, or one asked for when none is coming (a retry):
    // the parent may set state in it.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _ask(drop, onDue))
      ..ensureVisualUpdate();
  }

  Future<void> _ask(NextDrop drop, DropDue onDue) async {
    var fresh = false;
    if (mounted) {
      try {
        fresh = await onDue();
      } catch (_) {
        // Like a failed reload: asked again below.
      }
    }
    if (fresh) {
      _dueAsked[drop] = true;
      return;
    }
    // Free for the next ticker that shows it, or for this one in a while.
    _dueAsked[drop] = null;
    if (!mounted || !identical(widget.drop, drop)) return;
    _retry = Timer(NextDropTicker.retryDelay, () {
      _retry = null;
      if (mounted) _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _retry?.cancel();
    _ticking?.removeListener(_tickingChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remaining;
    return widget.builder(context, dropText(widget.drop, remaining), remaining);
  }
}

const _tabular = [FontFeature.tabularFigures()];

/// The card at the top of the game menu while a drop is less than a day
/// away.
class NextDropCard extends StatelessWidget {
  const NextDropCard({super.key, required this.drop, this.onDue, this.clock});

  final NextDrop drop;
  final DropDue? onDue;
  final Duration Function()? clock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('runner-next-drop'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
        child: Row(
          children: [
            const Icon(Icons.checkroom, color: StageTheme.orange),
            const SizedBox(width: 14),
            Expanded(
              child: NextDropTicker(
                drop: drop,
                onDue: onDue,
                clock: clock,
                builder: (context, text, _) => Text(
                  text,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: _tabular,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The small line under the wardrobe's title while a drop is less than a
/// day away.
class NextDropLine extends StatelessWidget {
  const NextDropLine({super.key, required this.drop, this.onDue, this.clock});

  final NextDrop drop;
  final DropDue? onDue;
  final Duration Function()? clock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return NextDropTicker(
      drop: drop,
      onDue: onDue,
      clock: clock,
      builder: (context, text, _) => Text(
        text,
        key: const ValueKey('wardrobe-next-drop'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: StageTheme.orange,
          fontFeatures: _tabular,
        ),
      ),
    );
  }
}
