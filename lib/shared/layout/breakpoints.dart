/// Window widths at which layouts change. The values match the literals the
/// screens used so far; replace a literal only where the value is identical.
abstract final class Breakpoints {
  /// Navigation rail instead of the bottom navigation bar.
  static const double rail = 900;

  /// The rail shows its labels next to the icons.
  static const double extendedRail = 1250;
  static const double todayTwoColumn = 900;
  static const double scheduleMasterDetail = 1000;
  static const double readerDesktop = 1000;
  static const double productionsTwoColumn = 820;
  static const double responsiveGroups = 760;
  static const double compact = 600;
}
