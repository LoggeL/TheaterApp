import 'package:flutter/material.dart';

import '../../app/brand.dart';

/// Official artwork, on white so the black symbol remains legible. The badge is
/// at most 72 pt, so the 256 px copy is sharp and decodes far faster than the
/// unmodified original.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 36});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(size * .08),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(size * .16),
    ),
    child: Image.asset(
      'assets/brand/kolpingtheater-ramsen-256.png',
      fit: BoxFit.contain,
      semanticLabel: Brand.organization,
    ),
  );
}
