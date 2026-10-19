import 'package:flutter/material.dart';

import '../../app/theme/stage_theme.dart';

class StatePill extends StatelessWidget {
  const StatePill(
    this.label, {
    super.key,
    this.color = StageTheme.green,
    this.icon,
  });
  final String label;
  final Color color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    // Brand accents switch to their text tone, any other colour is shifted
    // until the label reaches WCAG AA (4.5:1) on its tint.
    final (:fill, :foreground) = StageTheme.tintedLabel(
      color,
      Theme.of(context).brightness,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(50),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
