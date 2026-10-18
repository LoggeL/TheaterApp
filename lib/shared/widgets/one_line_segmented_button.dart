import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A [SegmentedButton] whose segment labels never break inside a word.
///
/// Segments share the available width equally. When the widest label plus
/// its icon does not fit into one share – on narrow phones or with a larger
/// system font – the icons are left out, because the labels carry the
/// meaning. Should a label still be too wide, it is scaled down slightly
/// instead of wrapping onto a second line.
class OneLineSegmentedButton<T> extends StatelessWidget {
  const OneLineSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.emptySelectionAllowed = false,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final void Function(Set<T>)? onSelectionChanged;
  final bool showSelectedIcon;
  final bool emptySelectionAllowed;

  /// Horizontal space an icon takes inside a segment beyond its label: the
  /// 18 px icon, the gap to the label, the wider padding of icon segments
  /// and the border.
  static const _iconSegmentChrome = 56.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final icons = _iconsFit(context, constraints.maxWidth);
      return SegmentedButton<T>(
        segments: [
          for (final segment in segments)
            ButtonSegment<T>(
              value: segment.value,
              enabled: segment.enabled,
              tooltip: segment.tooltip,
              icon: icons || segment.label == null ? segment.icon : null,
              label: segment.label == null
                  ? null
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: DefaultTextStyle.merge(
                        maxLines: 1,
                        softWrap: false,
                        child: segment.label!,
                      ),
                    ),
            ),
        ],
        selected: selected,
        onSelectionChanged: onSelectionChanged,
        showSelectedIcon: showSelectedIcon && icons,
        emptySelectionAllowed: emptySelectionAllowed,
      );
    },
  );

  bool _iconsFit(BuildContext context, double maxWidth) {
    if (!maxWidth.isFinite) return true;
    final style =
        SegmentedButtonTheme.of(context).style?.textStyle?.resolve(const {}) ??
        Theme.of(context).textTheme.labelLarge ??
        const TextStyle();
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    var widest = 0.0;
    for (final segment in segments) {
      final label = segment.label;
      if (label is! Text || label.data == null) continue;
      if (segment.icon == null && !showSelectedIcon) continue;
      final painter = TextPainter(
        text: TextSpan(text: label.data, style: style.merge(label.style)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return (widest + _iconSegmentChrome) * segments.length <= maxWidth;
  }
}
