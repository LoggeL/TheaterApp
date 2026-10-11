import 'package:flutter/material.dart';

/// One entry of a [TileGroup].
class GroupTile {
  const GroupTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.onTap,
    this.trailing,
    this.key,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Key? key;
}

/// Related navigation entries in one card, separated by hairlines, each with
/// a tinted icon. Keeps settings-like lists calm and consistent.
class TileGroup extends StatelessWidget {
  const TileGroup({super.key, this.title, required this.tiles});
  final String? title;
  final List<GroupTile> tiles;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
            child: Text(
              title!,
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, t) in tiles.indexed) ...[
                if (i > 0) const Divider(indent: 70, height: 1),
                ListTile(
                  key: t.key,
                  shape: const RoundedRectangleBorder(),
                  minVerticalPadding: 14,
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(t.icon, size: 20, color: scheme.primary),
                  ),
                  title: Text(
                    t.title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  subtitle: t.subtitle == null
                      ? null
                      : Text(
                          t.subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: t.subtitleColor,
                            fontWeight: t.subtitleColor == null
                                ? null
                                : FontWeight.w700,
                          ),
                        ),
                  trailing:
                      t.trailing ??
                      Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  onTap: t.onTap,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Lays out groups in one column on phones and two on wide screens.
class ResponsiveGroups extends StatelessWidget {
  const ResponsiveGroups({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 760 ? 2 : 1;
      if (columns == 1) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, c) in children.indexed) ...[
              if (i > 0) const SizedBox(height: 24),
              c,
            ],
          ],
        );
      }
      // Fill the shorter column next; tile groups are weighed by entries.
      final left = <Widget>[], right = <Widget>[];
      var leftWeight = 0, rightWeight = 0;
      for (final child in children) {
        final weight = child is TileGroup ? child.tiles.length + 1 : 3;
        if (leftWeight <= rightWeight) {
          left.add(child);
          leftWeight += weight;
        } else {
          right.add(child);
          rightWeight += weight;
        }
      }
      Widget column(List<Widget> items) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, c) in items.indexed) ...[
            if (i > 0) const SizedBox(height: 24),
            c,
          ],
        ],
      );
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: column(left)),
          const SizedBox(width: 20),
          Expanded(child: column(right)),
        ],
      );
    },
  );
}
