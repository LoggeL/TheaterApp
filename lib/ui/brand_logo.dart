import 'package:flutter/material.dart';
import '../core/brand.dart';

/// Unmodified official artwork, on white so the black symbol remains legible.
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
      'assets/brand/kolpingtheater-ramsen.png',
      fit: BoxFit.contain,
      semanticLabel: Brand.organization,
    ),
  );
}
