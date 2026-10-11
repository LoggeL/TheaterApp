import 'package:flutter/material.dart';

/// The common frame of the reader's bottom sheets: a title, an optional
/// subtitle, the scrolling [child] and an optional non-scrolling [footer].
class ReaderSheetFrame extends StatelessWidget {
  const ReaderSheetFrame({
    super.key,
    required this.title,
    this.subtitle = '',
    required this.child,
    this.footer,
  });
  final String title, subtitle;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Flexible(child: child),
          ?footer,
        ],
      ),
    ),
  );
}
