import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';

/// The game's visible entry for those who play it often: a destination in
/// the section rail on wide screens, a tile at the top of "Mein Bereich" on
/// phones. The server sets `runnerEntry` from more than ten runs; the demo
/// never shows it. [SecretTap] keeps opening the game for everybody.
bool gameEntryShown(AppController controller) =>
    !controller.isDemo && controller.user?.runnerEntry == true;

/// The entry's name in the rail and on the tile.
const gameEntryLabel = 'Bühnenlauf';
const gameEntryIcon = Icons.sports_esports_outlined;
const gameEntrySelectedIcon = Icons.sports_esports;
