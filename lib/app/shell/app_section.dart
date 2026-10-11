import 'package:flutter/widgets.dart';

import 'app_navigation.dart';

/// The top-level sections of the app shell. [index] is the tab index.
enum AppSection { today, schedule, scripts, messages, me, admin }

/// Switches the shell to [section], also from routes opened above it and
/// from callbacks outside of build.
void selectSection(BuildContext context, AppSection section) {
  final selection = context
      .getInheritedWidgetOfExactType<AppNavigationScope>()
      ?.notifier;
  if (selection != null) selection.value = section.index;
}
