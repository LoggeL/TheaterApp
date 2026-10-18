import 'dart:async';
import 'dart:math';

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
import '../domain/stage_runner.dart';

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
  });
  final AppController controller;

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

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    if (_ranked) _loadBoard();
  }

  @override
  void dispose() {
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
    _game = StageRunner(random: widget.random);
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
    _frame.value++;
    final hud = (_game.score, _game.meters);
    if (hud != _hud.value) _hud.value = hud;
    // Let the curtain close before showing the result.
    if (_game.over && _game.sinceOver >= .8) {
      _ticker.stop();
      _finish(_run);
    }
  }

  Future<void> _finish(int run) async {
    setState(() => _phase = _Phase.finished);
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
      );
      if (!mounted || run != _run) return;
      setState(() {
        _improved = result.improved;
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
    appBar: AppBar(title: const Text('Bühnenlauf')),
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
            child: CustomPaint(painter: _LegendPainter(kind)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(value, style: theme.textTheme.titleMedium),
        ],
      ),
    );
    return [
      const PageHeader(
        'Bühnenlauf',
        eyebrow: 'Hinter der Bühne',
        subtitle:
            'Am Flugseil quer über die Bühne – vorbei an Kisten, Kulissen, Scheinwerfern und Sandsäcken. Es wird immer schneller, bis der Vorhang fällt.',
      ),
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
    ];
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
            const Icon(
              Icons.theater_comedy,
              size: 48,
              color: StageTheme.orange,
            ),
            const SizedBox(height: 12),
            Text('Der Vorhang fällt!', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
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
                            painter: _StagePainter(() => _game, _frame),
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

const _stageDark = Color(0xFF151A17), _wall = Color(0xFF1D2420);
const _leg = Color(0xFF2A1E1C), _curtain = Color(0xFF9E2B25);
const _floorColor = Color(0xFF3B2A1E), _plank = Color(0xFF2C1F16);
const _wood = Color(0xFFB07A45), _woodDark = Color(0xFF7D532C);
const _canvas = Color(0xFFD9CBB0), _canvasEdge = Color(0xFF8E7D62);
const _metal = Color(0xFF59605C), _beam = Color(0xFFFFF1C9);
const _sack = Color(0xFF8A6A48), _rope = Color(0xFFBDB29C);
const _roseColor = Color(0xFFE5486B), _starColor = Color(0xFFFFC94A);

Paint _fill(Color color) => Paint()..color = color;
Paint _stroke(Color color, double width) => Paint()
  ..color = color
  ..strokeWidth = width
  ..style = PaintingStyle.stroke;

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

/// Laid-out glyphs, reused across frames as long as the size stays the same.
class _Glyphs {
  double _size = 0;
  final Map<Object, TextPainter> _cache = {};

  TextPainter icon(PickupKind kind, double size) {
    _reset(size);
    return _cache[kind] ??= _layout(
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
    _reset(size);
    return _cache['kg'] ??= _layout(
      'kg',
      TextStyle(
        color: const Color(0xFFF3E6CF),
        fontSize: size * .45,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  void _reset(double size) {
    if (size == _size) return;
    for (final p in _cache.values) {
      p.dispose();
    }
    _cache.clear();
    _size = size;
  }

  static TextPainter _layout(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
}

void _paintCentered(Canvas canvas, TextPainter p, Offset center) =>
    p.paint(canvas, center - Offset(p.width / 2, p.height / 2));

class _LegendPainter extends CustomPainter {
  _LegendPainter(this.kind);
  final PickupKind? kind;
  final _glyphs = _Glyphs();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(size.width * .3),
      ),
      _fill(_stageDark),
    );
    final c = size.center(Offset.zero);
    final kind = this.kind;
    if (kind != null) {
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
  bool shouldRepaint(_LegendPainter old) => old.kind != kind;
}

/// Paints the run. Paints and glyphs are created once; per frame it only
/// issues a few dozen plain rectangles, lines and cached glyphs.
class _StagePainter extends CustomPainter {
  _StagePainter(this.game, Listenable repaint) : super(repaint: repaint);
  final StageRunner Function() game;

  static final _bg = _fill(_stageDark), _wallPaint = _fill(_wall);
  static final _legPaint = _fill(_leg), _curtainPaint = _fill(_curtain);
  static final _floorPaint = _fill(_floorColor);
  static final _plankPaint = _stroke(_plank, 2);
  static final _woodPaint = _fill(_wood), _woodLine = _stroke(_woodDark, 2);
  static final _canvasPaint = _fill(_canvas);
  static final _canvasLine = _stroke(_canvasEdge, 2);
  static final _metalPaint = _fill(_metal), _sackPaint = _fill(_sack);
  static final _beamPaint = _fill(_beam.withValues(alpha: .07));
  static final _lensPaint = _fill(_beam);
  static final _ropePaint = _stroke(_rope, 1.5);
  static final _bodyPaint = _fill(StageTheme.onInkAccent);
  static final _headPaint = _fill(const Color(0xFFF2D3B8));
  static final _limbPaint = _stroke(const Color(0xFFF2F3ED), 3)
    ..strokeCap = StrokeCap.round;
  final _glyphs = _Glyphs();

  @override
  void paint(Canvas canvas, Size size) {
    final g = game();
    // One stage height in pixels; the course is viewWidth heights wide.
    final s = size.height, w = size.width;
    double sx(double worldX) => (worldX - g.distance) * s;

    canvas.drawRect(Offset.zero & size, _bg);
    // Back wall with wings that move at half speed (parallax).
    canvas.drawRect(
      Rect.fromLTRB(0, s * .1, w, s * StageRunner.floor),
      _wallPaint,
    );
    const wingSpacing = .55;
    final offset = (g.distance * .5) % wingSpacing;
    for (
      var x = -offset;
      x < StageRunner.viewWidth + wingSpacing;
      x += wingSpacing
    ) {
      canvas.drawRect(
        Rect.fromLTWH(x * s, s * .05, s * .06, s * (StageRunner.floor - .05)),
        _legPaint,
      );
    }
    // Floor with planks moving at full speed.
    final floorY = s * StageRunner.floor;
    canvas.drawRect(Rect.fromLTRB(0, floorY, w, s), _floorPaint);
    const plankSpacing = .25;
    final plankOffset = g.distance % plankSpacing;
    for (var x = -plankOffset; x < StageRunner.viewWidth; x += plankSpacing) {
      canvas.drawLine(
        Offset(x * s, floorY),
        Offset(x * s - s * .04, s),
        _plankPaint,
      );
    }

    for (final o in g.obstacles) {
      final rect = Rect.fromLTRB(
        sx(o.left),
        o.top * s,
        sx(o.right),
        o.bottom * s,
      );
      if (rect.right < 0 || rect.left > w) continue;
      switch (o.kind) {
        case ObstacleKind.crate:
          canvas.drawRect(rect, _woodPaint);
          canvas.drawRect(rect.deflate(1), _woodLine);
          canvas.drawLine(rect.topLeft, rect.bottomRight, _woodLine);
          canvas.drawLine(rect.topRight, rect.bottomLeft, _woodLine);
        case ObstacleKind.flat:
          canvas.drawRect(rect, _canvasPaint);
          canvas.drawRect(rect.deflate(1), _canvasLine);
          final strut = rect.left + rect.width * .5;
          canvas.drawLine(
            Offset(strut, rect.top + 4),
            Offset(strut, rect.bottom),
            _canvasLine,
          );
        case ObstacleKind.border:
          canvas.drawRect(rect, _curtainPaint);
          canvas.drawLine(rect.bottomLeft, rect.bottomRight, _canvasLine);
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
          // A faint beam; a flat rectangle, no blur.
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
      }
    }

    final glyph = s * .075;
    for (final p in g.pickups) {
      if (p.taken) continue;
      final x = sx(p.x);
      if (x < -glyph || x > w + glyph) continue;
      _paintCentered(canvas, _glyphs.icon(p.kind, glyph), Offset(x, p.y * s));
    }

    _paintRunner(canvas, g, s);

    // Top border of the stage portal.
    canvas.drawRect(
      Rect.fromLTRB(0, 0, w, s * StageRunner.ceiling * .7),
      _curtainPaint,
    );

    if (g.over) {
      // The curtain closes from both sides.
      final t = Curves.easeIn.transform(
        (g.sinceOver / .8).clamp(0, 1).toDouble(),
      );
      canvas.drawRect(Rect.fromLTRB(0, 0, w * .5 * t, s), _curtainPaint);
      canvas.drawRect(Rect.fromLTRB(w - w * .5 * t, 0, w, s), _curtainPaint);
    }
  }

  void _paintRunner(Canvas canvas, StageRunner g, double s) {
    final cx = StageRunner.runnerX * s, cy = g.y * s;
    final h = StageRunner.runnerHeight * s, bw = StageRunner.runnerWidth * s;
    // The flying wire up into the fly loft.
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - h * .5), _ropePaint);
    final onFloor =
        g.y >= StageRunner.floor - StageRunner.runnerHeight / 2 - .001;
    // Legs swing while running, dangle while flying.
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
  bool shouldRepaint(_StagePainter old) => false;
}
