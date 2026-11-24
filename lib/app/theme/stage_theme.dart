import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

abstract final class StageTheme {
  static const orange = Color(0xFFE96131);
  static const ink = Color(0xFF202823);
  static const cream = Color(0xFFF8F6F0);
  static const green = Color(0xFF32775D);
  static const violet = Color(0xFF74619B);

  /// Amber for "later" and "unknown" states.
  static const amber = Color(0xFFA25B06);

  /// Accent for text and icons on [ink] cards (e.g. the next-event card).
  static const onInkAccent = Color(0xFFFFA584);

  /// The brand orange deepened just enough to carry white text (WCAG AA),
  /// for filled buttons and markers on [ink] cards.
  static const orangeDeep = Color(0xFFCB4516);

  /// Cards and input fields in the dark theme.
  static const inkCard = Color(0xFF222923);

  /// Text and icon tones of the accents. The brand colours above stay for
  /// fills, bars and borders; as text they are too light on cream (orange)
  /// or too dark on the dark cards (green, violet). Each tone reaches 4.5:1
  /// on the cards, the surface and the tinted [StatePill]s of its theme.
  static const orangeTone = AccentTone(Color(0xFFB13C15), onInkAccent);
  static const greenTone = AccentTone(Color(0xFF2F7057), Color(0xFF9ED6B6));
  static const violetTone = AccentTone(Color(0xFF6D5B92), Color(0xFFC9B8F0));
  static const amberTone = AccentTone(Color(0xFF965406), Color(0xFFFFB18A));
  static const redTone = AccentTone(Color(0xFFAA4040), Color(0xFFFFB3AB));
  static const neutralTone = AccentTone(Color(0xFF5B665E), Color(0xFFBFC8C0));

  static final Map<Color, AccentTone> _tones = {
    orange: orangeTone,
    const Color(0xFFB83E16): orangeTone,
    green: greenTone,
    violet: violetTone,
    amber: amberTone,
  };

  /// [accent] as a text or icon colour in [brightness]: the brand colours
  /// map to their [AccentTone], anything else is returned unchanged.
  static Color accentText(Color accent, Brightness brightness) =>
      _tones[accent]?.of(brightness) ?? accent;

  /// Tint alpha of [StatePill]s and similar status labels.
  static const tintAlpha = .12;

  /// The base a tinted label is checked against: the lowest-contrast of
  /// the surfaces it sits on (cream in light, the card in dark).
  static Color labelBase(Brightness brightness) =>
      brightness == Brightness.dark ? inkCard : cream;

  static final _tintedLabelCache =
      <(int, Brightness, double, double), ({Color fill, Color foreground})>{};

  /// Fill and foreground of a label tinted with [accent]. The fill is the
  /// accent's tone at [alpha]; the foreground keeps the tone's hue and
  /// reaches [minimum] contrast on that fill over [labelBase].
  static ({Color fill, Color foreground}) tintedLabel(
    Color accent,
    Brightness brightness, {
    double alpha = tintAlpha,
    double minimum = 4.5,
  }) {
    final key = (accent.toARGB32(), brightness, alpha, minimum);
    final cached = _tintedLabelCache[key];
    if (cached != null) return cached;
    final tone = accentText(accent, brightness);
    final fill = tone.withValues(alpha: alpha);
    final background = Color.alphaBlend(fill, labelBase(brightness));
    final result = (
      fill: fill,
      foreground: legible(tone, background, minimum: minimum),
    );
    if (_tintedLabelCache.length < 128) _tintedLabelCache[key] = result;
    return result;
  }

  /// WCAG 2 contrast ratio of two opaque colours (1 to 21).
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return la > lb ? (la + .05) / (lb + .05) : (lb + .05) / (la + .05);
  }

  /// [foreground] darkened or lightened (hue and saturation kept) until it
  /// reaches [minimum] contrast against [background].
  static Color legible(
    Color foreground,
    Color background, {
    double minimum = 4.5,
  }) {
    if (contrast(foreground, background) >= minimum) return foreground;
    final darken =
        contrast(Colors.black, background) >=
        contrast(Colors.white, background);
    final hsl = HSLColor.fromColor(foreground);
    for (var step = 1; step <= 100; step++) {
      final lightness = (hsl.lightness + (darken ? -step : step) / 100).clamp(
        0.0,
        1.0,
      );
      final candidate = hsl.withLightness(lightness).toColor();
      if (contrast(candidate, background) >= minimum) return candidate;
    }
    return darken ? Colors.black : Colors.white;
  }

  /// Background of selected chips, segments and navigation indicators.
  static Color selectedTint(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFF65311F)
      : const Color(0xFFFFE4D8);
  static final _themes = <(Brightness, TargetPlatform), ThemeData>{};

  /// The app theme for [brightness]. Built once per brightness (and target
  /// platform, which the theme captures) and then shared: the seeded colour
  /// scheme alone costs about a millisecond, too much for every build of a
  /// screen that switches themes (the reader's stage mode).
  static ThemeData build(Brightness brightness) =>
      _themes[(brightness, defaultTargetPlatform)] ??= _create(brightness);

  static ThemeData _create(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: orange,
          brightness: brightness,
        ).copyWith(
          primary: dark ? onInkAccent : const Color(0xFFB83E16),
          surface: dark ? const Color(0xFF171C19) : cream,
          onSurface: dark ? const Color(0xFFF2F3ED) : ink,
          secondary: dark ? const Color(0xFF9ED6B6) : green,
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      // Material 3's InkSparkle compiles a custom GLSL fragment shader on
      // the first tap, causing a noticeable freeze on WebGL / iOS Safari.
      // InkRipple renders smoothly without custom shader compilation.
      splashFactory: kIsWeb ? InkRipple.splashFactory : null,
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
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        color: dark ? inkCard : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? inkCard : Colors.white,
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
        height: 68,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: dark ? const Color(0xFF1F2521) : Colors.white,
        indicatorColor: selectedTint(brightness),
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
      // On the web (especially iOS Safari at 3x DPR), Cupertino's dual-page
      // slide with edge shadow and Material's full-screen fade saveLayer are
      // heavy; use a lightweight GPU transform transition on web. Native iOS
      // keeps its swipe-back gesture.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: kIsWeb
            ? {
                TargetPlatform.android: _WebSlidePageTransitionsBuilder(),
                TargetPlatform.iOS: _WebSlidePageTransitionsBuilder(),
                TargetPlatform.macOS: _WebFadePageTransitionsBuilder(),
                TargetPlatform.windows: _WebFadePageTransitionsBuilder(),
                TargetPlatform.linux: _WebFadePageTransitionsBuilder(),
              }
            : {
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
        selectedColor: selectedTint(brightness),
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
                ? selectedTint(brightness)
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

/// An accent as text or icon colour: [light] on cream and white,
/// [dark] on the dark surfaces and cards.
class AccentTone {
  const AccentTone(this.light, this.dark);
  final Color light, dark;
  Color of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// Pure GPU transform slide-in for mobile web (especially iOS Safari): no
/// full-screen Opacity saveLayer, no edge shadow, no secondary-page parallax.
class _WebSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const _WebSlidePageTransitionsBuilder();

  static final _tween = Tween<Offset>(
    begin: const Offset(1, 0),
    end: Offset.zero,
  ).chain(CurveTween(curve: Curves.easeOutCubic));

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (animation.status == AnimationStatus.completed) return child;
    return SlideTransition(
      position: animation.drive(_tween),
      child: child,
    );
  }
}

/// Fast incoming-only fade for desktop web without secondary-route overdraw.
class _WebFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _WebFadePageTransitionsBuilder();

  static final _curve = CurveTween(curve: Curves.easeOut);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (animation.status == AnimationStatus.completed) return child;
    return FadeTransition(
      opacity: animation.drive(_curve),
      child: child,
    );
  }
}
