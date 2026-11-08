import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../../../app/theme/stage_theme.dart';
import '../../../shared/widgets/brand_logo.dart';

/// Shared, scrollable entry to the app, including verification and approval.
/// Large text keeps the single-column layout even on a wide window.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 960 &&
                MediaQuery.textScalerOf(context).scale(16) <= 22;
            final compact = constraints.maxWidth < 400;
            final form = Container(
              padding: EdgeInsets.all(compact ? 20 : 32),
              decoration: BoxDecoration(
                color: dark ? StageTheme.inkCard : Colors.white,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: .5),
                ),
              ),
              child: child,
            );
            return SingleChildScrollView(
              padding: EdgeInsets.all(compact ? 16 : 28),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - (compact ? 32 : 56))
                      .clamp(0, double.infinity),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: wide ? 1040 : 496),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Expanded(child: _EnsemblePanel()),
                              const SizedBox(width: 28),
                              Expanded(child: form),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Padding(
                                padding: EdgeInsets.fromLTRB(4, 4, 4, 24),
                                child: AuthBrand(),
                              ),
                              form,
                            ],
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class AuthBrand extends StatelessWidget {
  const AuthBrand({super.key, this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const BrandLogo(size: 44),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              Brand.name,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: onDark ? Colors.white : null,
              ),
            ),
            Text(
              Brand.organization,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: onDark
                    ? const Color(0xFFCBD2CC)
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _EnsemblePanel extends StatelessWidget {
  const _EnsemblePanel();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(36),
    decoration: BoxDecoration(
      color: StageTheme.ink,
      borderRadius: BorderRadius.circular(28),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AuthBrand(onDark: true),
        const SizedBox(height: 72),
        Container(width: 42, height: 4, color: StageTheme.onInkAccent),
        const SizedBox(height: 24),
        const Text(
          'Alles für deine\nnächste Probe.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 42,
            fontWeight: FontWeight.w800,
            height: 1.1,
            letterSpacing: -1.4,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Termine abstimmen, Texte lernen und mit dem Ensemble in Verbindung bleiben.',
          style: TextStyle(color: Color(0xFFCBD2CC), fontSize: 16, height: 1.6),
        ),
        const SizedBox(height: 48),
        for (final (icon, title) in [
          (Icons.calendar_today_outlined, 'Dein Probenplan'),
          (Icons.menu_book_outlined, 'Deine Drehbücher'),
          (Icons.forum_outlined, 'Dein Ensemble'),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: StageTheme.onInkAccent),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
