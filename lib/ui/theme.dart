import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

abstract final class StageTheme {
  static const orange = Color(0xFFE96131);
  static const ink = Color(0xFF202823);
  static const cream = Color(0xFFF8F6F0);
  static const green = Color(0xFF32775D);
  static const violet = Color(0xFF74619B);
  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: orange,
          brightness: brightness,
        ).copyWith(
          primary: dark ? const Color(0xFFFFA584) : const Color(0xFFB83E16),
          surface: dark ? const Color(0xFF171C19) : cream,
          onSurface: dark ? const Color(0xFFF2F3ED) : ink,
          secondary: dark ? const Color(0xFF9ED6B6) : green,
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontSize: 36,
          fontWeight: FontWeight.w800,
          letterSpacing: -1.4,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.8,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.5),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: dark ? const Color(0xFF222923) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF222923) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 17,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 78,
        backgroundColor: dark ? const Color(0xFF1F2521) : Colors.white,
        indicatorColor: dark
            ? const Color(0xFF65311F)
            : const Color(0xFFFFE4D8),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .45),
        space: 1,
      ),
      // A calm fade-through everywhere; iOS keeps its swipe-back gesture.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        selectedColor: dark ? const Color(0xFF65311F) : const Color(0xFFFFE4D8),
        showCheckmark: false,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll(
            base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? (dark ? const Color(0xFF65311F) : const Color(0xFFFFE4D8))
                : null,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        width: null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFE9E4DA) : ink,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(
          color: dark ? ink : cream,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(50),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title, message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
    child: Column(
      children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 34,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
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
