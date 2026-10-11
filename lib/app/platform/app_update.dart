import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:url_launcher/url_launcher.dart';

/// Keeps the Android app current: Google Play's update screen first, the store
/// page as fallback. Builds not installed from Play simply report no update.
class AppUpdateCheck {
  AppUpdateCheck({
    Future<AppUpdateInfo> Function()? check,
    Future<AppUpdateResult> Function()? update,
    Future<bool> Function(Uri)? open,
    DateTime Function()? clock,
  }) : _check = check ?? InAppUpdate.checkForUpdate,
       _update = update ?? InAppUpdate.performImmediateUpdate,
       _open = open ?? _openStore,
       _clock = clock ?? DateTime.now;

  static const packageName = 'de.kolpingtheater.ramsen.theaterapp';
  static final storeUri = Uri.parse('market://details?id=$packageName');
  static final webUri = Uri.parse(
    'https://play.google.com/store/apps/details?id=$packageName',
  );

  /// Returning to the app checks again after this pause.
  static const interval = Duration(hours: 12);

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final Future<AppUpdateInfo> Function() _check;
  final Future<AppUpdateResult> Function() _update;
  final Future<bool> Function(Uri) _open;
  final DateTime Function() _clock;
  DateTime? _checkedAt;
  bool _running = false;

  static Future<bool> _openStore(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return true;
      }
    } catch (_) {
      // No Play Store app: use the web page.
    }
    return launchUrl(webUri, mode: LaunchMode.externalApplication);
  }

  /// Checks at most every [interval]; `context` must be below a Navigator.
  Future<void> run(BuildContext Function() context) async {
    final now = _clock();
    if (_running ||
        (_checkedAt != null && now.difference(_checkedAt!) < interval)) {
      return;
    }
    _running = true;
    _checkedAt = now;
    try {
      final AppUpdateInfo info;
      try {
        info = await _check();
      } catch (_) {
        return; // Not installed from Google Play or Play is unavailable.
      }
      final pending =
          info.updateAvailability ==
          UpdateAvailability.developerTriggeredUpdateInProgress;
      if (info.updateAvailability != UpdateAvailability.updateAvailable &&
          !pending) {
        return;
      }
      if (info.immediateUpdateAllowed || pending) {
        try {
          if (await _update() == AppUpdateResult.success) return;
        } catch (_) {
          // Fall back to the store page below.
        }
      }
      final target = context();
      if (!target.mounted) return;
      final open = await showDialog<bool>(
        context: target,
        builder: (ctx) => AlertDialog(
          title: const Text('Neue Version verfügbar'),
          content: const Text(
            'Bitte aktualisiere die Theater-App über Google Play, damit alles zuverlässig funktioniert.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Später'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Zu Google Play'),
            ),
          ],
        ),
      );
      if (open == true) await _open(storeUri);
    } finally {
      _running = false;
    }
  }
}
