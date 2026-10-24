import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/page_header.dart';
import '../data/leaderboard_api.dart';
import '../data/wardrobe_api.dart';
import '../domain/stage_runner.dart';
import 'stage_runner_art.dart';
import 'stage_runner_fx.dart';
import 'stage_runner_look.dart';
import 'stage_runner_sound.dart';
import 'wardrobe_screen.dart';

/// Opens the stage runner.
Future<void> openStageRunner(BuildContext context, AppController controller) =>
    openPage<void>(context, StageRunnerScreen(controller: controller));

enum _Phase { intro, playing, finished }

/// "Bühnenlauf": an endless run on the flying wire with the ensemble's
/// shared leaderboard.
class StageRunnerScreen extends StatefulWidget {
  const StageRunnerScreen({
    super.key,
    required this.controller,
    this.random,
    this.onRun,
    this.sound,
  });
  final AppController controller;

  /// Replaced in tests; by default the [RunnerSound] of this platform.
  @visibleForTesting
  final RunnerSound? sound;

  /// Fixed in tests for reproducible courses.
  final Random? random;

  /// Gets each new run, so tests can follow it.
  @visibleForTesting
  final ValueChanged<StageRunner>? onRun;

  @override
  State<StageRunnerScreen> createState() => _StageRunnerScreenState();
}

class _StageRunnerScreenState extends State<StageRunnerScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastFrame = Duration.zero;
  _Phase _phase = _Phase.intro;
  StageRunner _game = StageRunner();
  RunnerFx _fx = RunnerFx();

  /// The art in the worn costume (see [dressArt]); the default art until
  /// the wardrobe is known.
  RunnerArt? _art = RunnerArt.loaded;
  RunnerTrail _trail = RunnerTrail();
  late final RunnerSound _sound = widget.sound ?? RunnerSound();

  /// The wardrobe, if the server offers it, and the progress after the last
  /// run.
  Wardrobe? _wardrobe;
  RunnerProgress? _progress;

  /// The closing line of the last run; its own dice, so courses stay
  /// reproducible.
  final _lines = Random();
  String _line = '';

  /// Repaints the stage without rebuilding widgets; the HUD only rebuilds
  /// when its numbers change.
  final _frame = ValueNotifier<int>(0);
  final _hud = ValueNotifier<(int, int)>((0, 0));
  int _pointers = 0;

  /// Increases with every run, so late server replies of an earlier run are
  /// ignored.
  int _run = 0;
  Future<String?>? _start;
  Leaderboard? _board;
  String? _boardError, _saveError;
  bool _loadingBoard = false, _saving = false, _improved = false;

  AppController get controller => widget.controller;
  bool get _ranked => leaderboardAvailable(controller);
  bool get _dressable => wardrobeAvailable(controller);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    if (_ranked) _loadBoard();
    if (_art == null) {
      RunnerArt.load().then((art) {
        if (mounted && art != null) setState(() => _art = art);
        _dress();
      });
    }
    if (_dressable) _loadWardrobe();
  }

  /// Only the worn costume is loaded; without it the default one plays.
  Future<void> _loadWardrobe() async {
    try {
      final w = await loadWardrobe(controller);
      if (!mounted) return;
      setState(() => _wardrobe = w);
      await _dress();
    } catch (e) {
      if (kDebugMode) debugPrint('Bühnenlauf: Garderobe nicht geladen: $e');
    }
  }

  Future<void> _dress() async {
    final base = RunnerArt.loaded, w = _wardrobe;
    if (base == null || w == null) return;
    final art = await dressArt(base, w, controller);
    if (mounted && identical(w, _wardrobe)) setState(() => _art = art);
  }

  Future<void> _openWardrobe() => openWardrobe(
    context,
    controller,
    wardrobe: _wardrobe,
    sound: _sound,
    onChanged: (w) {
      if (!mounted) return;
      setState(() {
        _wardrobe = w;
        if (_progress != null) _progress = w.progress;
      });
      _dress();
    },
  );

  @override
  void dispose() {
    _sound.stopMusic();
    if (widget.sound == null) _sound.dispose();
    _ticker.dispose();
    _frame.dispose();
    _hud.dispose();
    super.dispose();
  }

  Future<void> _loadBoard() async {
    setState(() {
      _loadingBoard = true;
      _boardError = null;
    });
    try {
      final board = await loadLeaderboard(controller);
      if (mounted) setState(() => _board = board);
    } catch (e) {
      if (mounted) setState(() => _boardError = userMessage(e));
    } finally {
      if (mounted) setState(() => _loadingBoard = false);
    }
  }

  void _play() {
    final run = ++_run;
    final game = _game = StageRunner(random: widget.random);
    final fx = _fx = RunnerFx(best: _board?.own?.score, onSound: _sound.play);
    // Its own dice, so courses stay reproducible.
    _trail = RunnerTrail();
    _progress = null;
    game.onPickup = (kind, x, y) => fx.pickup(kind, x - game.distance, y);
    // Called from the tap on "Vorhang auf", so browsers allow the sound.
    _sound
      ..prepare()
      ..startMusic();
    widget.onRun?.call(_game);
    _hud.value = (0, 0);
    _pointers = 0;
    _saveError = null;
    _improved = false;
    _saving = false;
    // The server times the run; a failed start only means it is not ranked.
    _start = _ranked
        ? startRound(controller).then<String?>(
            (id) => id,
            onError: (Object e) {
              if (mounted && run == _run) {
                setState(() => _saveError = userMessage(e));
              }
              return null;
            },
          )
        : null;
    setState(() => _phase = _Phase.playing);
    _lastFrame = Duration.zero;
    _ticker
      ..stop()
      ..start();
  }

  static final _holdKeys = {
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.keyW,
  };

  void _tick(Duration elapsed) {
    final dt = (elapsed - _lastFrame).inMicroseconds / 1e6;
    _lastFrame = elapsed;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    _game
      ..holding = _pointers > 0 || keys.any(_holdKeys.contains)
      ..update(dt);
    _fx.update(dt, _game);
    _trail.update(dt, _game, _art?.effect);
    _frame.value++;
    final hud = (_game.score, _game.meters);
    if (hud != _hud.value) _hud.value = hud;
    // Let the curtain close before showing the result.
    if (_game.over && _game.sinceOver >= _curtainEnd) {
      _ticker.stop();
      _sound.stopMusic();
      _finish(_run);
    }
  }

  Future<void> _finish(int run) async {
    setState(() {
      _phase = _Phase.finished;
      _line = curtainLine(_game.hitBy, _lines);
    });
    final start = _start;
    if (start == null) return;
    setState(() => _saving = true);
    try {
      final roundId = await start;
      if (roundId == null || roundId.isEmpty) return;
      final result = await submitRound(
        controller,
        roundId: roundId,
        score: _game.score,
        meters: _game.meters,
        hitBy: _game.hitBy,
      );
      if (!mounted || run != _run) return;
      // The fanfare, unless it already played when the record fell.
      if (result.improved && !_fx.recordBroken) {
        _sound.play(RunnerSfx.record);
      } else if ((result.progress?.newCrates ?? 0) > 0) {
        _sound.play(RunnerSfx.reveal);
      }
      setState(() {
        _improved = result.improved;
        _progress = result.progress;
        _board = result.leaderboard;
        _boardError = null;
      });
    } catch (e) {
      if (mounted && run == _run) {
        setState(() => _saveError = userMessage(e));
      }
    } finally {
      if (mounted && run == _run) setState(() => _saving = false);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) =>
      _holdKeys.contains(event.logicalKey)
      ? KeyEventResult.handled
      : KeyEventResult.ignored;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Bühnenlauf'),
      actions: [
        ValueListenableBuilder(
          valueListenable: _sound.enabled,
          builder: (context, on, _) => IconButton(
            key: const ValueKey('runner-sound'),
            tooltip: on ? 'Ton aus' : 'Ton an',
            isSelected: on,
            icon: const Icon(Icons.volume_off_outlined),
            selectedIcon: const Icon(Icons.volume_up_outlined),
            onPressed: () => _sound.setEnabled(!on),
          ),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: switch (_phase) {
      _Phase.playing => Focus(
        autofocus: true,
        onKeyEvent: _key,
        child: _stage(context),
      ),
      _ => ListView(
        padding: pagePadding(context, maxWidth: 640),
        children: [
          if (_phase == _Phase.intro) ..._intro(context) else _result(context),
          const SizedBox(height: 20),
          _leaderboard(context),
        ],
      ),
    },
  );

  List<Widget> _intro(BuildContext context) {
    final theme = Theme.of(context);
    Widget legend(PickupKind? kind, String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CustomPaint(painter: _LegendPainter(kind, _art)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(value, style: theme.textTheme.titleMedium),
        ],
      ),
    );
    return [
      PageHeader(
        'Bühnenlauf',
        eyebrow: 'Hinter der Bühne',
        // Names whoever is worn, as the picture below shows them.
        subtitle:
            '${_wardrobe?.worn(WardrobeKind.character)?.name ?? 'Engel Logge'} hängt zum ersten Mal am Flugseil – und die Technik hat die Bühne nicht aufgeräumt. Vorbei an Kisten, Kulissen, Scheinwerfern und Sandsäcken, immer schneller, bis der Vorhang fällt.',
      ),
      if (_art case final art?)
        Center(
          child: SizedBox(
            width: 96,
            height: 126,
            child: CustomPaint(
              painter: _SpritePainter(art, RunnerSprite.cheer),
            ),
          ),
        ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              legend(null, 'Jeder Meter', '+1'),
              for (final kind in PickupKind.values)
                legend(kind, _pickupLabel(kind), '+${kind.points}'),
              const SizedBox(height: 12),
              Text(
                'Halten zieht dich nach oben, Loslassen lässt dich sinken: Finger oder Maustaste auf der Bühne, am Rechner auch Leertaste oder Pfeil nach oben. Ein Zusammenstoß beendet den Lauf.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      Center(
        child: FilledButton.icon(
          onPressed: _play,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Vorhang auf'),
        ),
      ),
      if (_dressable) ...[
        const SizedBox(height: 12),
        Center(
          child: WardrobeButton(
            crates: _wardrobe?.progress.crates ?? 0,
            onPressed: _openWardrobe,
          ),
        ),
      ],
    ];
  }

  /// The way to the next costume crate after a run.
  Widget _crateProgress(BuildContext context, RunnerProgress p) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('runner-progress'),
      children: [
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: p.complete ? 1 : p.fraction,
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '+${metersText(p.gained)} · ${nextCrateText(p)}',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        if (p.newCrates > 0) ...[
          const SizedBox(height: 8),
          Text(
            p.newCrates == 1
                ? 'Neue Kostümkiste! Ab in die Garderobe.'
                : '${p.newCrates} neue Kostümkisten! Ab in die Garderobe.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: StageTheme.orange,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }

  Widget _result(BuildContext context) {
    final theme = Theme.of(context);
    final status = !_ranked
        ? null
        : _saving
        ? 'Punkte werden eingetragen …'
        : _saveError != null
        ? 'Nicht in der Bestenliste: $_saveError'
        : _improved
        ? 'Neuer persönlicher Bestwert!'
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (_art case final art?)
              SizedBox(
                width: 120,
                height: 74,
                child: CustomPaint(
                  painter: _SpritePainter(art, RunnerSprite.crash),
                ),
              )
            else
              const Icon(
                Icons.theater_comedy,
                size: 48,
                color: StageTheme.orange,
              ),
            const SizedBox(height: 12),
            Text(
              'Der Vorhang fällt!',
              style: theme.textTheme.labelLarge?.copyWith(
                color: StageTheme.orange,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _line,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              _game.score == 1 ? '1 Punkt' : '${_game.score} Punkte',
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${_game.meters} m · ${_game.collected} ${_game.collected == 1 ? 'Requisite' : 'Requisiten'} gesammelt',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            if (status != null) ...[
              const SizedBox(height: 12),
              Text(
                status,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _saveError != null
                      ? theme.colorScheme.error
                      : _improved
                      ? StageTheme.green
                      : null,
                  fontWeight: _improved ? FontWeight.w700 : null,
                ),
              ),
            ],
            if (_progress case final p?) _crateProgress(context, p),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  autofocus: true,
                  onPressed: _play,
                  icon: const Icon(Icons.replay),
                  label: const Text('Nochmal'),
                ),
                if (_dressable)
                  WardrobeButton(
                    crates:
                        _progress?.crates ?? _wardrobe?.progress.crates ?? 0,
                    onPressed: _openWardrobe,
                  ),
                OutlinedButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('Zurück in die App'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _leaderboard(BuildContext context) {
    final theme = Theme.of(context);
    final board = _board;
    final me = controller.user?.personId;
    Widget row(LeaderboardEntry e) {
      final own = e.personId == me;
      final style = own
          ? theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            )
          : theme.textTheme.bodyLarge;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(width: 36, child: Text('${e.rank}.', style: style)),
            Expanded(
              child: Text(
                e.name,
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('${e.score}', style: style),
          ],
        ),
      );
    }

    final List<Widget> content;
    if (!_ranked) {
      content = [
        Text(
          controller.isDemo
              ? 'In der Demo gibt es keine Bestenliste.'
              : 'Die Bestenliste ist auf diesem Server noch nicht verfügbar.',
        ),
      ];
    } else if (board == null) {
      content = [
        if (_loadingBoard)
          const Center(child: CircularProgressIndicator())
        else ...[
          Text(_boardError ?? 'Die Bestenliste konnte nicht geladen werden.'),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: _loadBoard,
              child: const Text('Erneut laden'),
            ),
          ),
        ],
      ];
    } else if (board.top.isEmpty) {
      content = [const Text('Noch keine Punkte. Lauf als Erste oder Erster!')];
    } else {
      final ownOutside =
          board.own != null &&
          !board.top.any((e) => e.personId == board.own!.personId);
      content = [
        for (final e in board.top) row(e),
        if (ownOutside) ...[const Divider(), row(board.own!)],
        if (board.own == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Du stehst noch nicht auf der Liste.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ];
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
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
                    'Bestenliste',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...content,
          ],
        ),
      ),
    );
  }

  /// The whole area below the app bar takes the touch, so a thumb anywhere
  /// on the screen flies; the stage keeps its fixed proportions.
  Widget _stage(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _pointers++,
      onPointerUp: (_) => _pointers = max(0, _pointers - 1),
      onPointerCancel: (_) => _pointers = max(0, _pointers - 1),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: ValueListenableBuilder(
                    valueListenable: _hud,
                    builder: (context, hud, _) => Row(
                      children: [
                        Expanded(
                          child: Text(
                            hud.$1 == 1 ? '1 Punkt' : '${hud.$1} Punkte',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        Text('${hud.$2} m', style: theme.textTheme.titleLarge),
                      ],
                    ),
                  ),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: AspectRatio(
                      aspectRatio: StageRunner.viewWidth,
                      child: RepaintBoundary(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: CustomPaint(
                            key: const ValueKey('runner-stage'),
                            size: Size.infinite,
                            painter: _StagePainter(
                              () => _game,
                              () => _fx,
                              () => _art,
                              _frame,
                              () => _trail,
                              pixelRatio: MediaQuery.devicePixelRatioOf(
                                context,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Halten zum Steigen',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _pickupLabel(PickupKind kind) => switch (kind) {
  PickupKind.rose => 'Rose',
  PickupKind.mask => 'Maske',
  PickupKind.star => 'Stern des Abends',
};

/// Seconds from the crash until the result shows: a comic fall, then the
/// curtain closes.
const _curtainEnd = 1.0, _curtainStart = .2;

const _stageDark = Color(0xFF151A17), _wall = Color(0xFF1D2420);
const _velvet = Color(0xFF8E2420), _velvetDark = Color(0xFF5E1714);
const _gold = Color(0xFFD9A441);
const _floorColor = Color(0xFF3B2A1E), _plank = Color(0xFF2C1F16);
const _floorEdge = Color(0xFF6B4A30);
const _wood = Color(0xFFB07A45), _woodDark = Color(0xFF7D532C);
const _canvas = Color(0xFFD9CBB0), _canvasEdge = Color(0xFF8E7D62);
const _metal = Color(0xFF59605C), _beam = Color(0xFFFFF1C9);
const _sack = Color(0xFF8A6A48), _rope = Color(0xFFBDB29C);
const _roseColor = Color(0xFFE5486B), _starColor = Color(0xFFFFC94A);
const _crowd = Color(0xFF07090A);

Paint _fill(Color color) => Paint()..color = color;
Paint _stroke(Color color, double width) => Paint()
  ..color = color
  ..strokeWidth = width
  ..style = PaintingStyle.stroke;

/// Each sprite comes from the atlas of its layer in the worn costume (see
/// [RunnerArt.imageOf]), with that layer's paint.
void _sprite(Canvas canvas, RunnerArt art, RunnerSprite sprite, Rect dst) =>
    canvas.drawImageRect(
      art.imageOf(sprite),
      sprite.rect,
      dst,
      art.paintOf(sprite),
    );

/// [sprite] centred in [size], as large as it fits.
Rect _fit(RunnerSprite sprite, Size size) {
  final scale = min(size.width / sprite.width, size.height / sprite.height);
  return Rect.fromCenter(
    center: size.center(Offset.zero),
    width: sprite.width * scale,
    height: sprite.height * scale,
  );
}

IconData _pickupIcon(PickupKind kind) => switch (kind) {
  PickupKind.rose => Icons.local_florist,
  PickupKind.mask => Icons.theater_comedy,
  PickupKind.star => Icons.star_rounded,
};

Color _pickupColor(PickupKind kind) => switch (kind) {
  PickupKind.rose => _roseColor,
  PickupKind.mask => StageTheme.onInkAccent,
  PickupKind.star => _starColor,
};

/// Laid-out text by content and size, reused across frames until the stage
/// size changes. Popups, banners and the sandbag label share one frame, so
/// different sizes must not push each other out.
@visibleForTesting
class RunnerGlyphs {
  /// On the web the labels name the bundled font. For a style without a
  /// family, CanvasKit takes every character from U+00A0 on (the "–" and
  /// "×" of the banners) as missing and searches the Noto fallback fonts;
  /// the first time it downloads one, and then lays out all text again.
  static const _font = kIsWeb ? 'Roboto' : null;

  double _stage = 0;
  final Map<Object, TextPainter> _cache = {};

  /// Called once per paint with the stage size; a new size drops the cache.
  void stage(double s) {
    if (s == _stage) return;
    _clear();
    _stage = s;
  }

  TextPainter icon(PickupKind kind, double size) {
    _bound();
    return _cache[(kind, size)] ??= _layout(
      String.fromCharCode(_pickupIcon(kind).codePoint),
      TextStyle(
        fontFamily: _pickupIcon(kind).fontFamily,
        package: _pickupIcon(kind).fontPackage,
        fontSize: size,
        color: _pickupColor(kind),
      ),
    );
  }

  TextPainter kg(double size) {
    _bound();
    return _cache[('kg', size)] ??= _layout(
      'kg',
      TextStyle(
        fontFamily: _font,
        color: const Color(0xFFF3E6CF),
        fontSize: size * .45,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  /// A popup or banner line; [shadow] is the dark copy drawn behind it.
  TextPainter label(String text, double size, {bool shadow = false}) {
    _bound();
    return _cache[(text, size, shadow)] ??= _layout(
      text,
      TextStyle(
        fontFamily: _font,
        color: shadow ? const Color(0xE6000000) : const Color(0xFFFFE7A3),
        fontSize: size,
        fontWeight: FontWeight.w900,
        letterSpacing: -.3,
      ),
    );
  }

  /// A safety net: sizes that keep changing must not grow the cache forever.
  void _bound() {
    if (_cache.length > 64) _clear();
  }

  void _clear() {
    for (final p in _cache.values) {
      p.dispose();
    }
    _cache.clear();
  }

  static TextPainter _layout(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
}

void _paintCentered(Canvas canvas, TextPainter p, Offset center) =>
    p.paint(canvas, center - Offset(p.width / 2, p.height / 2));

class _SpritePainter extends CustomPainter {
  _SpritePainter(this.art, this.sprite);
  final RunnerArt art;
  final RunnerSprite sprite;
  @override
  void paint(Canvas canvas, Size size) =>
      _sprite(canvas, art, sprite, _fit(sprite, size));

  @override
  bool shouldRepaint(_SpritePainter old) =>
      old.art != art || old.sprite != sprite;
}

class _LegendPainter extends CustomPainter {
  _LegendPainter(this.kind, this.art);
  final PickupKind? kind;
  final RunnerArt? art;
  final _glyphs = RunnerGlyphs();
  @override
  void paint(Canvas canvas, Size size) {
    _glyphs.stage(size.width);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(size.width * .3),
      ),
      _fill(_stageDark),
    );
    final c = size.center(Offset.zero);
    final kind = this.kind, art = this.art;
    if (kind != null && art != null) {
      final sprite = RunnerSprite.of(kind);
      _sprite(canvas, art, sprite, _fit(sprite, size * .8).shift(c * .2));
    } else if (kind != null) {
      _paintCentered(canvas, _glyphs.icon(kind, size.width * .7), c);
    } else {
      // Two floor planks for "metres".
      final y = size.height * .62;
      canvas.drawLine(
        Offset(size.width * .2, y),
        Offset(size.width * .8, y),
        _stroke(_wood, 3),
      );
      canvas.drawLine(
        Offset(size.width * .35, y - 7),
        Offset(size.width * .65, y - 7),
        _stroke(_wood, 3),
      );
    }
  }

  @override
  bool shouldRepaint(_LegendPainter old) => old.kind != kind || old.art != art;
}

/// Paints the run. Paints, paths and text are created once; per frame it
/// issues a few dozen rectangles, circles and sprite copies from one atlas.
/// Without the pictures (offline on the web) it draws simple shapes.
class _StagePainter extends CustomPainter {
  _StagePainter(
    this.game,
    this.fx,
    this.art,
    Listenable repaint,
    this.trail, {
    this.pixelRatio = 1,
  }) : super(repaint: repaint);
  final StageRunner Function() game;
  final RunnerFx Function() fx;
  final RunnerArt? Function() art;

  /// The trail of the worn effect.
  final RunnerTrail Function() trail;

  /// Device pixels per logical pixel; the stage scrolls in whole device
  /// pixels.
  final double pixelRatio;

  static final _bg = _fill(_stageDark), _wallPaint = _fill(_wall);
  static final _velvetPaint = _fill(_velvet);
  static final _foldPaint = _fill(_velvetDark);
  static final _goldPaint = _fill(_gold);
  static final _floorPaint = _fill(_floorColor);
  static final _plankPaint = _stroke(_plank, 2);
  static final _edgePaint = _stroke(_floorEdge, 2);
  static final _woodPaint = _fill(_wood), _woodLine = _stroke(_woodDark, 2);
  static final _canvasPaint = _fill(_canvas);
  static final _canvasLine = _stroke(_canvasEdge, 2);
  static final _metalPaint = _fill(_metal), _sackPaint = _fill(_sack);
  static final _beamPaint = _fill(_beam.withValues(alpha: .07));
  static final _conePaint = _fill(_beam.withValues(alpha: .045));
  static final _poolPaint = _fill(_beam.withValues(alpha: .07));
  static final _lensPaint = _fill(_beam);
  static final _ropePaint = _stroke(_rope, 1.5);
  static final _crowdPaint = _fill(_crowd);
  static final _platePaint = _fill(const Color(0xDD151A17));
  static final _plateEdge = _stroke(_gold, 2);
  static final _bodyPaint = _fill(StageTheme.onInkAccent);
  static final _headPaint = _fill(const Color(0xFFF2D3B8));
  static final _limbPaint = _stroke(const Color(0xFFF2F3ED), 3)
    ..strokeCap = StrokeCap.round;
  static final _particlePaints = [
    _fill(_roseColor),
    _fill(_starColor),
    _fill(const Color(0xFFFFF4C2)),
    _fill(const Color(0xFFBFA88A)),
  ];
  final _glyphs = RunnerGlyphs();
  final _path = Path();

  @override
  void paint(Canvas canvas, Size size) {
    final g = game(), f = fx(), a = art();
    // One stage height in pixels; the course is viewWidth heights wide.
    final s = size.height, w = size.width;
    final floorY = s * StageRunner.floor;
    _glyphs.stage(s);

    canvas.drawRect((Offset.zero & size).inflate(s * .05), _bg);
    final (dx, dy) = f.shake(g);
    canvas.save();
    canvas.translate(dx * s, dy * s);

    // The whole stage moves as one, exactly at the running pace: backdrop,
    // lights, wings, floor, course and front row. Layers at their own pace
    // (parallax) made players feel sick. The shift is rounded to whole
    // device pixels, so each frame is the last one moved by whole pixels and
    // the pictures don't shimmer.
    final scroll = (g.distance * s * pixelRatio).round() / pixelRatio;
    _backdrop(canvas, a, s, w, floorY, scroll);
    _spotlights(canvas, s, w, floorY, scroll);
    _wings(canvas, s, w, scroll);
    _floor(canvas, s, w, floorY, scroll);

    for (final o in g.obstacles) {
      final rect = Rect.fromLTRB(
        o.left * s - scroll,
        o.top * s,
        o.right * s - scroll,
        o.bottom * s,
      );
      if (rect.right < -s * .1 || rect.left > w + s * .1) continue;
      if (a == null) {
        _plainObstacle(canvas, o.kind, rect, s, floorY);
      } else {
        _obstacle(canvas, a, o, rect, s, floorY);
      }
    }

    _pickups(canvas, g, a, s, w, scroll);
    trail().paint(canvas, s, a?.effect);
    if (a == null) {
      _plainRunner(canvas, g, s);
    } else {
      _runner(canvas, g, f, a, s);
    }
    _particles(canvas, f, s);
    _audience(canvas, g, f, s, w, scroll);
    _bannerAndValance(canvas, f, s, w);
    canvas.restore();

    if (g.over) _curtain(canvas, g, s, w);
  }

  /// The painted backdrop passes [scroll] pixels to the left, tiled in turn
  /// as painted and mirrored, so the seams match for runs of any length.
  /// Its paint samples with mipmaps ([FilterQuality.medium]): smooth when
  /// scaled down, no stair steps when scaled up.
  void _backdrop(
    Canvas canvas,
    RunnerArt? a,
    double s,
    double w,
    double floorY,
    double scroll,
  ) {
    if (a == null) {
      canvas.drawRect(Rect.fromLTRB(0, s * .1, w, floorY), _wallPaint);
      return;
    }
    final image = a.backdrop, top = s * .04, h = floorY - top;
    final tile = h * image.width / image.height;
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    for (var x = -(scroll % (2 * tile)); x < w; x += 2 * tile) {
      canvas.drawImageRect(
        image,
        src,
        Rect.fromLTWH(x, top, tile, h),
        a.backdropPaint,
      );
      canvas
        ..save()
        ..translate(x + 2 * tile, top)
        ..scale(-1, 1)
        ..drawImageRect(
          image,
          src,
          Rect.fromLTWH(0, 0, tile, h),
          a.backdropPaint,
        )
        ..restore();
    }
  }

  /// Light cones hung every .72 stage heights, passing with the stage:
  /// flat translucent shapes, no blur.
  void _spotlights(
    Canvas canvas,
    double s,
    double w,
    double floorY,
    double scroll,
  ) {
    final period = s * .72;
    for (
      var x = s * .48 - scroll % period - period;
      x < w + s * .25;
      x += period
    ) {
      _path
        ..reset()
        ..moveTo(x - s * .02, 0)
        ..lineTo(x + s * .02, 0)
        ..lineTo(x + s * .22, floorY)
        ..lineTo(x - s * .22, floorY)
        ..close();
      canvas.drawPath(_path, _conePaint);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(x, floorY + s * .02),
          width: s * .46,
          height: s * .06,
        ),
        _poolPaint,
      );
    }
  }

  /// Velvet wings every .51 stage heights, passing with the stage.
  void _wings(Canvas canvas, double s, double w, double scroll) {
    const width = .07;
    final period = s * .51;
    for (var left = -(scroll % period); left < w; left += period) {
      final top = s * .05, bottom = s * StageRunner.floor;
      canvas.drawRect(
        Rect.fromLTRB(left, top, left + s * width, bottom),
        _velvetPaint,
      );
      for (final fold in const [.012, .042]) {
        canvas.drawRect(
          Rect.fromLTRB(left + s * fold, top, left + s * (fold + .012), bottom),
          _foldPaint,
        );
      }
    }
  }

  void _floor(Canvas canvas, double s, double w, double floorY, double scroll) {
    canvas.drawRect(Rect.fromLTRB(0, floorY, w, s), _floorPaint);
    final period = s * .25;
    for (var x = -(scroll % period); x < w + s * .04; x += period) {
      canvas.drawLine(Offset(x, floorY), Offset(x - s * .04, s), _plankPaint);
    }
    canvas.drawLine(Offset(0, floorY), Offset(w, floorY), _edgePaint);
  }

  void _obstacle(
    Canvas canvas,
    RunnerArt a,
    Obstacle o,
    Rect rect,
    double s,
    double floorY,
  ) {
    switch (o.kind) {
      case ObstacleKind.crate:
        // A tall pile is two crates, so none gets stretched much.
        if (rect.height > rect.width * 1.35) {
          final half = rect.height / 2;
          _sprite(
            canvas,
            a,
            RunnerSprite.crate,
            rect.topLeft & Size(rect.width, half),
          );
          _sprite(
            canvas,
            a,
            RunnerSprite.crate,
            Rect.fromLTWH(rect.left, rect.top + half, rect.width, half),
          );
        } else {
          _sprite(canvas, a, RunnerSprite.crate, rect);
        }
      case ObstacleKind.flat:
        _flat(canvas, a, rect);
      case ObstacleKind.border:
        _velvetPiece(canvas, rect, s);
      case ObstacleKind.lamp:
        final width = rect.width * 1.05;
        final body = _lamp(
          canvas,
          a,
          rect.center.dx,
          rect.bottom,
          width,
          floorY,
        );
        canvas.drawLine(
          Offset(rect.center.dx, 0),
          Offset(rect.center.dx, body.top),
          _ropePaint,
        );
      case ObstacleKind.sandbag:
        final sprite = RunnerSprite.sandbag;
        final width = rect.width * 1.25;
        final height = width * sprite.height / sprite.width;
        final bag = Rect.fromLTWH(
          rect.center.dx - width / 2,
          rect.bottom - height,
          width,
          height,
        );
        canvas.drawLine(
          Offset(rect.center.dx, 0),
          Offset(rect.center.dx, bag.top + height * .1),
          _ropePaint,
        );
        _sprite(canvas, a, sprite, bag);
      case ObstacleKind.drum:
        // The spokes turn with the way it rolled.
        final r = rect.width * .56;
        final center = Offset(rect.center.dx, rect.bottom - r);
        canvas
          ..save()
          ..translate(center.dx, center.dy)
          ..rotate(o.left * s / r);
        _sprite(
          canvas,
          a,
          RunnerSprite.drum,
          Rect.fromCircle(center: Offset.zero, radius: r),
        );
        canvas.restore();
      case ObstacleKind.pile:
        // The lower part holds two crates side by side, the top one.
        final count = max(1, (rect.width / rect.height).round());
        final width = rect.width / count;
        for (var i = 0; i < count; i++) {
          _sprite(
            canvas,
            a,
            RunnerSprite.crate,
            Rect.fromLTWH(rect.left + i * width, rect.top, width, rect.height),
          );
        }
      case ObstacleKind.truss:
        // Four lamps under the truss, the outer ones flush with its ends.
        final bar = RunnerSprite.truss;
        final lampWidth = rect.width * .19;
        final lampHeight =
            lampWidth * RunnerSprite.lamp.height / RunnerSprite.lamp.width;
        final barHeight = rect.width * bar.height / bar.width;
        final barTop = rect.bottom - lampHeight - barHeight * .5;
        for (var i = 0; i < 4; i++) {
          final x =
              rect.left + lampWidth / 2 + i * (rect.width - lampWidth) / 3;
          _lamp(canvas, a, x, rect.bottom, lampWidth, floorY);
        }
        for (final x in [rect.left + s * .012, rect.right - s * .012]) {
          canvas.drawLine(Offset(x, 0), Offset(x, barTop), _ropePaint);
        }
        _sprite(
          canvas,
          a,
          bar,
          Rect.fromLTWH(rect.left, barTop, rect.width, barHeight),
        );
      case ObstacleKind.drop:
        final sprite = RunnerSprite.drop;
        final height = rect.width * sprite.height / sprite.width;
        final frame = Rect.fromLTWH(
          rect.left,
          rect.bottom - height,
          rect.width,
          height,
        );
        for (final x in [.28, .72]) {
          final dx = frame.left + frame.width * x;
          canvas.drawLine(
            Offset(dx, 0),
            Offset(dx, frame.top + height * .02),
            _ropePaint,
          );
        }
        _sprite(canvas, a, sprite, frame);
    }
  }

  /// A stage light hanging with its lens at [bottom], with its beam down to
  /// the floor; returns where the lamp is.
  Rect _lamp(
    Canvas canvas,
    RunnerArt a,
    double centerX,
    double bottom,
    double width,
    double floorY,
  ) {
    final sprite = RunnerSprite.lamp;
    final height = width * sprite.height / sprite.width;
    final body = Rect.fromLTWH(
      centerX - width / 2,
      bottom - height,
      width,
      height,
    );
    // The beam from the lens down to the floor.
    final lens = Offset(body.center.dx, body.bottom - height * .06);
    _path
      ..reset()
      ..moveTo(lens.dx - width * .3, lens.dy)
      ..lineTo(lens.dx + width * .3, lens.dy)
      ..lineTo(lens.dx + width * .9, floorY)
      ..lineTo(lens.dx - width * .9, floorY)
      ..close();
    canvas.drawPath(_path, _beamPaint);
    _sprite(canvas, a, sprite, body);
    return body;
  }

  /// A painted flat in three slices: frame top and feet keep their shape,
  /// only the canvas in between stretches.
  void _flat(Canvas canvas, RunnerArt a, Rect rect) {
    final sprite = RunnerSprite.flat, src = sprite.rect;
    final width = rect.width * 1.35, scale = width / sprite.width;
    final left = rect.center.dx - width / 2;
    const topCap = 36.0, footCap = 64.0;
    final top = topCap * scale, foot = footCap * scale;
    if (rect.height <= top + foot) {
      _sprite(
        canvas,
        a,
        sprite,
        Rect.fromLTWH(left, rect.top, width, rect.height),
      );
      return;
    }
    void slice(
      double srcTop,
      double srcBottom,
      double dstTop,
      double dstBottom,
    ) => canvas.drawImageRect(
      a.imageOf(sprite),
      Rect.fromLTRB(src.left, src.top + srcTop, src.right, src.top + srcBottom),
      Rect.fromLTRB(left, dstTop, left + width, dstBottom),
      a.paintOf(sprite),
    );
    slice(0, topCap, rect.top, rect.top + top);
    slice(topCap, sprite.height - footCap, rect.top + top, rect.bottom - foot);
    slice(
      sprite.height - footCap,
      sprite.height,
      rect.bottom - foot,
      rect.bottom,
    );
  }

  /// A border (short curtain) hanging from the fly loft, with gold fringe.
  void _velvetPiece(Canvas canvas, Rect rect, double s) {
    canvas.drawRect(rect, _velvetPaint);
    final fold = rect.width / 5;
    for (var i = 1; i < 5; i += 2) {
      canvas.drawRect(
        Rect.fromLTWH(rect.left + fold * i, rect.top, fold * .7, rect.height),
        _foldPaint,
      );
    }
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.bottom - s * .014, rect.width, s * .014),
      _goldPaint,
    );
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(
        Offset(rect.left + rect.width * (i + .5) / 4, rect.bottom + s * .006),
        s * .006,
        _goldPaint,
      );
    }
  }

  void _pickups(
    Canvas canvas,
    StageRunner g,
    RunnerArt? a,
    double s,
    double w,
    double scroll,
  ) {
    final glyph = s * .075, height = s * .085;
    for (final p in g.pickups) {
      if (p.taken) continue;
      final x = p.x * s - scroll;
      if (x < -glyph || x > w + glyph) continue;
      // A gentle bob; the hitbox stays where it is.
      final y = p.y * s + sin(g.time * 4 + p.x * 7) * s * .008;
      if (a == null) {
        _paintCentered(canvas, _glyphs.icon(p.kind, glyph), Offset(x, y));
        continue;
      }
      final sprite = RunnerSprite.of(p.kind);
      final scale = height / max(sprite.width, sprite.height);
      _sprite(
        canvas,
        a,
        sprite,
        Rect.fromCenter(
          center: Offset(x, y),
          width: sprite.width * scale,
          height: sprite.height * scale,
        ),
      );
    }
  }

  /// Engel Logge: runs on the floor, flies with arms forward, dangles when
  /// sinking, cheers at a pickup and crashes comically.
  void _runner(
    Canvas canvas,
    StageRunner g,
    RunnerFx f,
    RunnerArt a,
    double s,
  ) {
    final onFloor =
        g.y >= StageRunner.floor - StageRunner.runnerHeight / 2 - .001;
    final RunnerSprite sprite;
    var feet = g.y + StageRunner.runnerHeight / 2 + .006;
    var angle = 0.0, wireTop = 0.0;
    if (g.over) {
      sprite = RunnerSprite.crash;
      // Drops to the floor with a little bounce; the wire snaps upwards.
      final t = (g.sinceOver / .35).clamp(0, 1).toDouble();
      final bounce = (1 - t) * sin(t * pi) * .06;
      feet =
          feet +
          (StageRunner.floor + .01 - feet) * Curves.easeIn.transform(t) -
          bounce;
      angle = (1 - t) * .5;
      wireTop =
          (g.y - StageRunner.runnerHeight / 2) * Curves.easeOut.transform(t);
    } else if (f.cheer > 0) {
      sprite = RunnerSprite.cheer;
    } else if (onFloor) {
      sprite = RunnerSprite.stride(g.distance);
    } else {
      sprite = g.vy < -.05 ? RunnerSprite.fly : RunnerSprite.dangle;
      angle = (g.vy * .12).clamp(-.2, .2).toDouble();
    }
    final scale = RunnerSprite.stagePerPixel * s;
    final width = sprite.width * scale, height = sprite.height * scale;
    // Flying flat, the body lies around the middle of the hitbox; every
    // other pose stands on its feet.
    if (sprite == RunnerSprite.fly) feet = g.y + height / s / 2;
    final cx = StageRunner.runnerX * s, bottom = feet * s;
    final dst = Rect.fromLTWH(cx - width / 2, bottom - height, width, height);
    final harness = dst.topLeft + a.harnessOf(sprite) * scale;
    if (!g.over) {
      canvas.drawLine(Offset(harness.dx, 0), harness, _ropePaint);
    } else if (wireTop > 0) {
      canvas.drawLine(
        Offset(cx, 0),
        Offset(
          cx,
          (g.y - StageRunner.runnerHeight / 2) * s - wireTop * s + s * .02,
        ),
        _ropePaint,
      );
    }
    if (angle == 0) {
      _sprite(canvas, a, sprite, dst);
      return;
    }
    final pivot = dst.center;
    canvas
      ..save()
      ..translate(pivot.dx, pivot.dy)
      ..rotate(angle)
      ..translate(-pivot.dx, -pivot.dy);
    _sprite(canvas, a, sprite, dst);
    canvas.restore();
  }

  void _particles(Canvas canvas, RunnerFx f, double s) {
    for (var i = 0; i < RunnerFx.maxParticles; i++) {
      final life = f.life[i];
      if (life <= 0) continue;
      canvas.drawCircle(
        Offset(f.px[i] * s, f.py[i] * s),
        f.size[i] * s * min(1, life * 3),
        _particlePaints[f.tint[i]],
      );
    }
    final size = s * .045;
    for (final p in f.popups) {
      if (!p.alive) continue;
      final at = Offset(p.x * s, (p.y - p.age * .12) * s);
      _paintCentered(
        canvas,
        _glyphs.label(p.text, size, shadow: true),
        at + Offset(s * .003, s * .003),
      );
      _paintCentered(canvas, _glyphs.label(p.text, size), at);
    }
  }

  /// Heads in the front row, passing at the pace of the floor; they bounce
  /// while a banner celebrates.
  void _audience(
    Canvas canvas,
    StageRunner g,
    RunnerFx f,
    double s,
    double w,
    double scroll,
  ) {
    final spacing = s * .11;
    final first = (scroll / spacing).floor();
    final cheering = f.showsBanner && !g.over;
    for (var i = first - 1; i * spacing - scroll < w + spacing; i++) {
      final h = (i * 7919) % 13;
      final r = s * (.034 + (h % 3) * .004);
      final x = i * spacing - scroll + (h % 5) * s * .004;
      final hop = cheering ? -(sin(g.time * 9 + i) * .5 + .5) * s * .014 : 0.0;
      final y = s * (.985 - (h % 4) * .006) + hop;
      canvas.drawCircle(Offset(x, y - r * .6), r, _crowdPaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x, y + r * 1.2),
            width: r * 3.2,
            height: r * 2.2,
          ),
          Radius.circular(r),
        ),
        _crowdPaint,
      );
    }
  }

  /// The banner pops in below the valance and slides up behind it.
  void _bannerAndValance(Canvas canvas, RunnerFx f, double s, double w) {
    final text = f.banner;
    if (text != null && f.showsBanner) {
      final t = f.bannerAge;
      final pop = t < .18 ? Curves.easeOutBack.transform(t / .18) : 1.0;
      final leave = max(0.0, t - (RunnerFx.bannerLife - .3)) / .3;
      final label = _glyphs.label(text, s * .055);
      final center = Offset(w / 2, s * (.2 - leave * .2));
      final plate = Rect.fromCenter(
        center: center,
        width: label.width + s * .08,
        height: label.height + s * .03,
      );
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..scale(pop)
        ..translate(-center.dx, -center.dy);
      final rrect = RRect.fromRectAndRadius(plate, Radius.circular(s * .03));
      canvas
        ..drawRRect(rrect, _platePaint)
        ..drawRRect(rrect, _plateEdge);
      _paintCentered(canvas, label, center);
      canvas.restore();
    }
    // Valance of the stage portal with a scalloped edge.
    final bottom = s * StageRunner.ceiling * .7, r = s * .03;
    canvas.drawRect(Rect.fromLTRB(0, 0, w, bottom), _velvetPaint);
    for (var x = r; x < w + r; x += r * 2) {
      canvas.drawCircle(Offset(x, bottom), r, _velvetPaint);
    }
    canvas.drawRect(
      Rect.fromLTRB(0, bottom - s * .01, w, bottom - s * .004),
      _goldPaint,
    );
  }

  /// The curtain closes from both sides after the crash.
  void _curtain(Canvas canvas, StageRunner g, double s, double w) {
    final t = Curves.easeIn.transform(
      ((g.sinceOver - _curtainStart) / (_curtainEnd - _curtainStart - .05))
          .clamp(0, 1)
          .toDouble(),
    );
    if (t == 0) return;
    final half = w * .5 * t, fold = s * .06;
    for (final left in [true, false]) {
      final rect = left
          ? Rect.fromLTRB(0, 0, half, s)
          : Rect.fromLTRB(w - half, 0, w, s);
      canvas.drawRect(rect, _velvetPaint);
      for (var x = rect.left + fold * .5; x < rect.right; x += fold) {
        canvas.drawRect(Rect.fromLTWH(x, 0, fold * .35, s), _foldPaint);
      }
      final edge = left ? rect.right - s * .012 : rect.left;
      canvas.drawRect(Rect.fromLTWH(edge, 0, s * .012, s), _goldPaint);
    }
  }

  void _plainObstacle(
    Canvas canvas,
    ObstacleKind kind,
    Rect rect,
    double s,
    double floorY,
  ) {
    switch (kind) {
      case ObstacleKind.crate:
        canvas.drawRect(rect, _woodPaint);
        canvas.drawRect(rect.deflate(1), _woodLine);
        canvas.drawLine(rect.topLeft, rect.bottomRight, _woodLine);
        canvas.drawLine(rect.topRight, rect.bottomLeft, _woodLine);
      case ObstacleKind.flat:
        canvas.drawRect(rect, _canvasPaint);
        canvas.drawRect(rect.deflate(1), _canvasLine);
      case ObstacleKind.border:
        _velvetPiece(canvas, rect, s);
      case ObstacleKind.lamp:
        final cx = rect.center.dx;
        final body = Rect.fromLTRB(
          rect.left,
          rect.bottom - s * .1,
          rect.right,
          rect.bottom,
        );
        canvas.drawLine(Offset(cx, 0), Offset(cx, body.top), _ropePaint);
        canvas.drawRect(body, _metalPaint);
        canvas.drawRect(
          Rect.fromLTRB(
            body.left + 3,
            body.bottom - 5,
            body.right - 3,
            body.bottom,
          ),
          _lensPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(body.left, body.bottom, body.right, floorY),
          _beamPaint,
        );
      case ObstacleKind.sandbag:
        final cx = rect.center.dx;
        canvas.drawLine(Offset(cx, 0), Offset(cx, rect.top), _ropePaint);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(rect.width * .3)),
          _sackPaint,
        );
        _paintCentered(canvas, _glyphs.kg(rect.width), rect.center);
      case ObstacleKind.drum:
        canvas
          ..drawCircle(rect.center, rect.width / 2, _woodPaint)
          ..drawCircle(rect.center, rect.width / 2 - 1, _woodLine)
          ..drawCircle(rect.center, rect.width * .15, _metalPaint);
      case ObstacleKind.pile:
        canvas.drawRect(rect, _woodPaint);
        canvas.drawRect(rect.deflate(1), _woodLine);
      case ObstacleKind.truss:
        final bar = Rect.fromLTRB(
          rect.left,
          rect.bottom - s * .1,
          rect.right,
          rect.bottom - s * .06,
        );
        for (final x in [bar.left + 2, bar.right - 2]) {
          canvas.drawLine(Offset(x, 0), Offset(x, bar.top), _ropePaint);
        }
        canvas.drawRect(bar, _metalPaint);
        canvas.drawRect(
          Rect.fromLTRB(rect.left, bar.bottom, rect.right, rect.bottom),
          _metalPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(rect.left, rect.bottom, rect.right, floorY),
          _beamPaint,
        );
      case ObstacleKind.drop:
        final frame = Rect.fromLTRB(
          rect.left,
          rect.bottom - rect.width * 1.4,
          rect.right,
          rect.bottom,
        );
        canvas.drawLine(
          Offset(frame.center.dx, 0),
          Offset(frame.center.dx, frame.top),
          _ropePaint,
        );
        canvas.drawRect(frame, _canvasPaint);
        canvas.drawRect(frame.deflate(1), _canvasLine);
    }
  }

  void _plainRunner(Canvas canvas, StageRunner g, double s) {
    final cx = StageRunner.runnerX * s, cy = g.y * s;
    final h = StageRunner.runnerHeight * s, bw = StageRunner.runnerWidth * s;
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - h * .5), _ropePaint);
    final onFloor =
        g.y >= StageRunner.floor - StageRunner.runnerHeight / 2 - .001;
    final swing = onFloor && !g.over
        ? sin(g.distance * 40) * bw * .5
        : bw * .15;
    final hip = Offset(cx, cy + h * .15);
    canvas.drawLine(hip, Offset(cx + swing, cy + h * .5), _limbPaint);
    canvas.drawLine(hip, Offset(cx - swing, cy + h * .5), _limbPaint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy - h * .02),
          width: bw * .8,
          height: h * .42,
        ),
        Radius.circular(bw * .3),
      ),
      _bodyPaint,
    );
    canvas.drawCircle(Offset(cx, cy - h * .34), h * .14, _headPaint);
  }

  @override
  bool shouldRepaint(_StagePainter old) => old.pixelRatio != pixelRatio;
}
