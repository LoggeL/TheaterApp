import 'package:flutter/material.dart';

import '../../../../core/models.dart';

/// Normalized strokes keep a signature stable across screen and PDF sizes.
class SignatureController extends ChangeNotifier {
  final List<List<Offset>> _strokes = [];
  bool _drawing = false;
  static const maxStrokes = 100, maxPoints = 5000;

  List<List<Offset>> get strokes => _strokes;
  int get pointCount => _strokes.fold(0, (sum, stroke) => sum + stroke.length);
  bool get isEmpty => _strokes.isEmpty;
  bool get isValid =>
      _strokes.any((stroke) => stroke.length >= 2) &&
      _strokes.fold<double>(0, (sum, stroke) {
            for (var i = 1; i < stroke.length; i++) {
              sum += (stroke[i] - stroke[i - 1]).distance;
            }
            return sum;
          }) >=
          0.02;
  bool get atLimit => _strokes.length >= maxStrokes || pointCount >= maxPoints;

  JsonMap get toJson => {
    'strokes': [
      for (final stroke in _strokes.where((s) => s.length >= 2))
        [
          for (final point in stroke) [point.dx, point.dy],
        ],
    ],
  };

  void start(Offset point) {
    _drawing = !atLimit;
    if (!_drawing) return;
    _strokes.add([point]);
    notifyListeners();
  }

  void add(Offset point) {
    if (!_drawing || _strokes.isEmpty || pointCount >= maxPoints) return;
    if (_strokes.last.last == point) return;
    _strokes.last.add(point);
    notifyListeners();
  }

  void end() {
    _drawing = false;
    if (_strokes.isNotEmpty && _strokes.last.length < 2) {
      _strokes.removeLast();
      notifyListeners();
    }
  }

  void clear() {
    _drawing = false;
    _strokes.clear();
    notifyListeners();
  }
}

List<List<Offset>> signatureStrokes(JsonMap signature) => [
  for (final rawStroke in jsonList(signature['strokes']))
    [
      for (final rawPoint in jsonList(rawStroke))
        if (rawPoint is List &&
            rawPoint.length == 2 &&
            rawPoint[0] is num &&
            rawPoint[1] is num)
          Offset(
            (rawPoint[0] as num).toDouble().clamp(0, 1),
            (rawPoint[1] as num).toDouble().clamp(0, 1),
          ),
    ],
];

class SignaturePad extends StatelessWidget {
  const SignaturePad({
    super.key,
    required this.controller,
    this.enabled = true,
  });
  final SignatureController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: 'Unterschriftenfeld. Mit Finger oder Maus unterschreiben.',
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = width * 110 / 300;
              Offset normalized(Offset point) => Offset(
                (point.dx / width).clamp(0, 1),
                (point.dy / height).clamp(0, 1),
              );
              return GestureDetector(
                key: const ValueKey('signature-pad'),
                behavior: HitTestBehavior.opaque,
                onPanStart: enabled
                    ? (details) =>
                          controller.start(normalized(details.localPosition))
                    : null,
                onPanUpdate: enabled
                    ? (details) =>
                          controller.add(normalized(details.localPosition))
                    : null,
                onPanEnd: enabled ? (_) => controller.end() : null,
                onPanCancel: enabled ? controller.end : null,
                child: _SignatureCanvas(strokes: controller.strokes),
              );
            },
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                controller.atLimit
                    ? 'Zeichenfläche voll. Bei Bedarf löschen und neu unterschreiben.'
                    : 'Mit Finger oder Maus unterschreiben.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: enabled && !controller.isEmpty
                  ? controller.clear
                  : null,
              child: const Text('Unterschrift löschen'),
            ),
          ],
        ),
      ],
    ),
  );
}

class SignaturePreview extends StatelessWidget {
  const SignaturePreview({super.key, required this.signature});
  final JsonMap signature;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Abgegebene Unterschrift',
    child: _SignatureCanvas(strokes: signatureStrokes(signature)),
  );
}

class _SignatureCanvas extends StatelessWidget {
  const _SignatureCanvas({required this.strokes});
  final List<List<Offset>> strokes;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 300 / 110,
    child: Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(painter: _SignaturePainter(strokes)),
    ),
  );
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes);
  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()
        ..moveTo(stroke.first.dx * size.width, stroke.first.dy * size.height);
      for (final point in stroke.skip(1)) {
        path.lineTo(point.dx * size.width, point.dy * size.height);
      }
      canvas.drawPath(path, pen);
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) => true;
}
