import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../data/api_client.dart' show ApiException;
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/page_header.dart';
import '../data/runner_menu_preferences.dart';
import '../data/weekly_api.dart';
import 'runner_menu.dart';

final _number = NumberFormat.decimalPattern('de');

/// What the Wochenprobe hands to the game: a ranked attempt that the
/// server has already started (and counted), or a training run.
class WeeklyPlay {
  const WeeklyPlay({required this.challenge, this.start, this.ghosts = true});
  final WeeklyChallenge challenge;

  /// The ranked attempt; null for training.
  final WeeklyStart? start;

  /// Whether a training run shows the ghosts; ranked runs always do.
  final bool ghosts;

  bool get ranked => start != null;
  int get seed => start?.seed ?? challenge.seed;

  /// Which of the week's attempts a ranked run is (1–3); 0 for training.
  int get attempt => switch (start?.attempt) {
    null => 0,
    final n when n > 0 => n,
    _ => challenge.used + 1,
  };
}

/// Without a connection the ranked start cannot be counted, so it does not
/// start at all; training runs without one.
const weeklyOfflineText =
    'Ohne Verbindung zum Server startet kein Wertungslauf, denn der Versuch '
    'wird beim Start gezählt. Training geht auch so.';

/// A ranked start without an answer: it may have reached the server, and
/// then the attempt counts.
const weeklyNoAnswerText =
    'Keine Antwort vom Server, der Wertungslauf ist nicht gestartet. Kam der '
    'Start dort noch an, ist der Versuch trotzdem gezählt – die Versuche oben '
    'zeigen es, sobald die Verbindung wieder steht.';

/// Opens the Wochenprobe; gives what to play, or null.
Future<WeeklyPlay?> openRunnerWeekly(
  BuildContext context,
  AppController controller, {
  WeeklyChallenge? initial,
  RunnerMenuPreferences? preferences,
  ValueChanged<WeeklyChallenge>? onLoaded,
}) => openPage<WeeklyPlay>(
  context,
  RunnerWeeklyScreen(
    controller: controller,
    initial: initial,
    preferences: preferences,
    onLoaded: onLoaded,
  ),
);

/// The Wochenprobe: this week's course with its countdown, the ranked
/// attempts and training, the week's ranking and, once, last week's
/// reward.
class RunnerWeeklyScreen extends StatefulWidget {
  const RunnerWeeklyScreen({
    super.key,
    required this.controller,
    this.initial,
    this.preferences,
    this.cache,
    this.onLoaded,
  });
  final AppController controller;

  /// What the menu knew already; shown until the fresh one arrives.
  final WeeklyChallenge? initial;
  final RunnerMenuPreferences? preferences;

  /// Where the course is kept for training offline; on this device by
  /// default.
  @visibleForTesting
  final WeeklyCourseCache? cache;

  /// Told about every freshly loaded week.
  final ValueChanged<WeeklyChallenge>? onLoaded;

  @override
  State<RunnerWeeklyScreen> createState() => _RunnerWeeklyScreenState();
}

class _RunnerWeeklyScreenState extends State<RunnerWeeklyScreen> {
  late final RunnerMenuPreferences _menu =
      widget.preferences ?? RunnerMenuPreferences();
  late final WeeklyCourseCache _cache = widget.cache ?? WeeklyCourseCache();
  WeeklyChallenge? _week;
  String? _error, _startError;
  bool _loading = false, _starting = false;

  /// Last week's reward, kept for this visit once the server shows it.
  WeeklyLastWeek? _reward;
  bool _rewardClosed = false;
  Timer? _clock;

  AppController get controller => widget.controller;
  DateTime get _now => controller.now;

  @override
  void initState() {
    super.initState();
    _week = widget.initial;
    _menu.addListener(_changed);
    _load();
    // The countdown; a week that ends meanwhile brings the next.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final week = _week;
      if (week != null && !week.currentAt(_now) && !_loading) {
        _load();
      } else {
        setState(() {});
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _clock?.cancel();
    _menu.removeListener(_changed);
    if (widget.preferences == null) _menu.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final week = await loadWeekly(controller);
      if (!mounted) return;
      setState(() {
        _week = week;
        if (week.lastWeek case final last? when _reward == null) {
          _reward = last;
        }
      });
      widget.onLoaded?.call(week);
      unawaited(_cache.write(week));
      // Shown once: the server leaves it out from now on.
      if (week.lastWeek case final last?) {
        unawaited(
          markWeeklySeen(controller, last.week).catchError((Object e) {
            if (kDebugMode) debugPrint('Wochenprobe: nicht gesehen: $e');
          }),
        );
      }
    } catch (e) {
      final cached = _week == null || _week!.cached
          ? await _cache.read()
          : null;
      if (!mounted) return;
      setState(() {
        _error = userMessage(e);
        if (cached != null && cached.currentAt(_now)) _week = cached;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startRanked() async {
    final week = _week;
    if (week == null || _starting) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('weekly-confirm'),
        title: const Text('Wertungslauf starten?'),
        content: Text(
          'Das ist dein Versuch ${week.used + 1} von ${week.max}. Er zählt, '
          'sobald der Lauf startet – auch wenn du abbrichst oder die App '
          'schließt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            key: const ValueKey('weekly-confirm-start'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Los geht’s'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final start = await startWeeklyRound(
        controller,
        week: week.week,
        ranked: true,
      );
      if (!mounted) return;
      Navigator.pop(context, WeeklyPlay(challenge: week, start: start));
    } catch (e) {
      if (!mounted) return;
      final refusal = weeklyRefusal(e);
      setState(() {
        _startError = switch (refusal) {
          WeeklyRefusal.attemptsUsed =>
            'Alle Versuche dieser Woche sind schon genutzt.',
          WeeklyRefusal.weekOver =>
            'Diese Woche ist vorbei – die neue Strecke ist da.',
          null when e is ApiException && e.statusCode == 0 =>
            weeklyNoAnswerText,
          null => userMessage(e),
        };
      });
      // The attempts as the server counted them: also a start that got no
      // answer may have counted.
      unawaited(_load());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _train() {
    final week = _week;
    if (week == null || _starting) return;
    Navigator.pop(
      context,
      WeeklyPlay(challenge: week, ghosts: _menu.trainingGhosts),
    );
  }

  @override
  Widget build(BuildContext context) {
    final week = _week;
    // While a ranked start is on its way the page stays: the server counts
    // the attempt with the start, so its run must be played from here.
    return PopScope(canPop: !_starting, child: _page(context, week));
  }

  Widget _page(BuildContext context, WeeklyChallenge? week) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wochenprobe')),
      body: week == null
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _error ??
                                'Die Wochenprobe konnte nicht geladen werden.',
                            key: const ValueKey('weekly-error'),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _load,
                            child: const Text('Erneut laden'),
                          ),
                        ],
                      ),
                    ),
            )
          : ListView(
              padding: pagePadding(context, maxWidth: 640, top: 16),
              children: [
                if (_reward case final r? when !_rewardClosed) ...[
                  _rewardBanner(context, r),
                  const SizedBox(height: 16),
                ],
                _course(context, week),
                const SizedBox(height: 16),
                _ranking(context, week),
              ],
            ),
    );
  }

  Widget _rewardBanner(BuildContext context, WeeklyLastWeek reward) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('weekly-reward'),
      color: StageTheme.orange.withValues(alpha: StageTheme.tintAlpha),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          children: [
            const Icon(Icons.payments_outlined, color: StageTheme.orange),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                weeklyRewardText(reward.rank, reward.gage),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Schließen',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _rewardClosed = true),
            ),
          ],
        ),
      ),
    );
  }

  /// The week, its countdown, the attempts and the two ways to run.
  Widget _course(BuildContext context, WeeklyChallenge week) {
    final theme = Theme.of(context);
    final current = week.currentAt(_now);
    final offline = week.cached;
    final rankedOpen = !offline && current && week.left > 0 && !_starting;
    final own = week.own;
    final best =
        week.best ?? (own == null ? null : WeeklyBest(score: own.score));
    return Card(
      key: const ValueKey('weekly-course'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Eyebrow('Eine Strecke für alle'),
            const SizedBox(height: 6),
            Text(
              weeklyHeadline(week.week, week.startsAt, week.endsAt),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 2),
            Text(
              weeklyCountdown(week.endsAt, _now),
              key: const ValueKey('weekly-countdown'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Diese Woche laufen alle dieselbe Strecke. Drei Wertungsläufe, '
              'der beste zählt; trainieren kannst du so oft du willst.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            if (!offline)
              Row(
                children: [
                  for (var i = 0; i < week.max; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        i < week.used ? Icons.circle : Icons.circle_outlined,
                        size: 14,
                        color: StageTheme.orange,
                      ),
                    ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      weeklyAttemptsText(week.used, week.max),
                      key: const ValueKey('weekly-attempts'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            if (best != null) ...[
              const SizedBox(height: 6),
              Text(
                own == null
                    ? 'Dein Wochenbestwert: ${_number.format(best.score)} Punkte'
                    : 'Dein Wochenbestwert: ${_number.format(best.score)} '
                          'Punkte · Platz ${own.rank}',
                key: const ValueKey('weekly-best'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('weekly-ranked'),
              style: FilledButton.styleFrom(
                backgroundColor: StageTheme.orange,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: rankedOpen ? _startRanked : null,
              icon: _starting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.flag_outlined),
              label: const Text('Wertungslauf starten'),
            ),
            const SizedBox(height: 6),
            Text(
              offline
                  ? weeklyOfflineText
                  : week.left == 0
                  ? 'Nächste Woche gibt es neue Versuche. Training geht weiter.'
                  : 'Ein Versuch zählt, sobald der Lauf startet.',
              key: const ValueKey('weekly-ranked-note'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            if (_startError case final error?) ...[
              const SizedBox(height: 8),
              Text(
                error,
                key: const ValueKey('weekly-start-error'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('weekly-training'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: current && !_starting ? _train : null,
              icon: const Icon(Icons.fitness_center),
              label: const Text('Training'),
            ),
            if (!offline)
              SwitchListTile(
                key: const ValueKey('weekly-ghosts'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Geister im Training'),
                subtitle: const Text('Die besten Läufe der Woche laufen mit.'),
                value: _menu.trainingGhosts,
                onChanged: _menu.setTrainingGhosts,
              ),
          ],
        ),
      ),
    );
  }

  Widget _ranking(BuildContext context, WeeklyChallenge week) {
    final theme = Theme.of(context);
    final rows = week.leaderboard;
    return Card(
      key: const ValueKey('weekly-ranking'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.emoji_events_outlined,
                  color: StageTheme.orange,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Wochenwertung',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (week.cached)
              Text(
                _error == null
                    ? 'Die Wochenwertung lädt, sobald der Server erreichbar ist.'
                    : 'Gerade keine Verbindung: Die Wochenwertung lädt, '
                          'sobald der Server erreichbar ist.',
                key: const ValueKey('weekly-offline'),
              )
            else if (rows.isEmpty)
              const Text(
                'Diese Woche hat noch niemand gewertet. Lauf als Erste oder '
                'Erster!',
              )
            else
              for (final e in rows)
                RunnerRankRow(
                  rank: e.rank,
                  name: e.name,
                  own: e.me,
                  trailing: _number.format(e.score),
                ),
            if (week.cached)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: _loading ? null : _load,
                  child: const Text('Erneut laden'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
