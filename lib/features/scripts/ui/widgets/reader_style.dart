import 'package:flutter/material.dart';

import '../../../../app/theme/stage_theme.dart';

/// The reader's accent: own roles, the live focus and scene markers.
const readerAccent = StageTheme.orange;

/// [readerAccent] for text: deeper on light pages, lighter on dark ones.
Color readerAccentText(BuildContext context) =>
    StageTheme.accentText(readerAccent, Theme.of(context).brightness);

/// [readerAccent] as a fill behind white text.
const readerAccentFill = StageTheme.orangeDeep;

/// The dark card colour of the production library.
const readerInk = StageTheme.ink;
