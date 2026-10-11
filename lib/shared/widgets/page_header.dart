import 'package:flutter/material.dart';

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 10,
      letterSpacing: 2.3,
      fontWeight: FontWeight.w800,
      color: color ?? Theme.of(context).colorScheme.primary,
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final text = Text(title, style: Theme.of(context).textTheme.titleLarge);
    // With very large text the action no longer fits beside the title.
    final stacked =
        trailing != null && MediaQuery.textScalerOf(context).scale(10) > 15;
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 14),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, trailing!],
            )
          : Row(
              children: [
                Expanded(child: text),
                ?trailing,
              ],
            ),
    );
  }
}

/// Large page title in the style of the main sections: optional eyebrow,
/// headline and a short subtitle.
class PageHeader extends StatelessWidget {
  const PageHeader(
    this.title, {
    super.key,
    this.eyebrow,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final String? eyebrow, subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null) ...[
                  Eyebrow(eyebrow!),
                  const SizedBox(height: 8),
                ],
                Text(title, style: theme.textTheme.headlineLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  Text(subtitle!, style: theme.textTheme.bodyMedium),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
