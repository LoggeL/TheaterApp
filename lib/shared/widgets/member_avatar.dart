import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import 'protected_image.dart';

class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.controller,
    this.avatarId,
    required this.initials,
    this.radius = 22,
    this.alignment = Alignment.center,
  });
  final AppController controller;
  final String? avatarId;
  final String initials;
  final double radius;

  /// [Alignment.topCenter] keeps the face of a portrait photo in the circle.
  final Alignment alignment;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diameter = radius * 2;
    if (avatarId == null) {
      return SizedBox.square(
        dimension: diameter,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.secondaryContainer,
          ),
          child: Center(
            child: Text(
              initials,
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }
    final fallback = ColoredBox(
      color: scheme.secondaryContainer,
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            color: scheme.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = (diameter * dpr).round().clamp(64, 256);
    return SizedBox.square(
      dimension: diameter,
      child: ClipOval(
        child: ProtectedImage(
          controller: controller,
          path: '/media/$avatarId',
          alignment: alignment,
          decodeWidth: decodeWidth,
          fallback: fallback,
        ),
      ),
    );
  }
}
