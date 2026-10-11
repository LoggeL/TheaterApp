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
  });
  final AppController controller;
  final String? avatarId;
  final String initials;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
    return SizedBox.square(
      dimension: radius * 2,
      child: ClipOval(
        child: avatarId == null
            ? fallback
            : ProtectedImage(
                controller: controller,
                path: '/media/$avatarId',
                decodeWidth: 256,
                fallback: fallback,
              ),
      ),
    );
  }
}
