/// Version name from pubspec.yaml; a test keeps both in sync.
const appVersion = '0.6.0';

/// Store build number, passed by the Android release build
/// (`--dart-define=APP_BUILD=…`); empty for web and local builds.
const appBuild = String.fromEnvironment('APP_BUILD');

/// e.g. "Version 0.6.0 (Build 12)".
const appVersionLabel =
    'Version $appVersion${appBuild == '' ? '' : ' (Build $appBuild)'}';
