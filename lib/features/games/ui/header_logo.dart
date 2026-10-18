import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../shared/widgets/brand_logo.dart';
import 'secret_tap.dart';
import 'stage_runner_screen.dart';

/// The logo in the app's header. Five quick taps open the ensemble's game;
/// otherwise it is the plain [BrandLogo].
class HeaderLogo extends StatelessWidget {
  const HeaderLogo({super.key, required this.controller, this.size = 32});
  final AppController controller;
  final double size;

  static const taps = 5;

  @override
  Widget build(BuildContext context) => SecretTap(
    taps: taps,
    onUnlocked: () => openStageRunner(context, controller),
    child: BrandLogo(size: size),
  );
}
