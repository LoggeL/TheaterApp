/// Public API of the games feature: a small game for the ensemble with a
/// shared leaderboard, reached through [SecretTap]: five quick taps on the
/// [HeaderLogo] or seven on the logo in "Über die App". Admins also find
/// the Skin-Viewer of all its skins in the settings ([openAdminSkinViewer]).
library;

export 'data/admin_skins_api.dart' show adminSkinsAvailable;
export 'ui/admin_skin_viewer.dart' show openAdminSkinViewer;
export 'ui/header_logo.dart';
export 'ui/secret_tap.dart';
export 'ui/stage_runner_screen.dart' show StageRunnerScreen, openStageRunner;
