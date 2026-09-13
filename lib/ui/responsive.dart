import 'package:flutter/material.dart';

/// Centers readable content while retaining the full route and its background.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 840});
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

EdgeInsets pagePadding(
  BuildContext context, {
  double maxWidth = 840,
  double top = 24,
  double bottom = 32,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final side = width > maxWidth ? (width - maxWidth) / 2 + 24 : 24.0;
  return EdgeInsets.fromLTRB(side, top, side, bottom);
}
