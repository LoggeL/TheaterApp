import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/device_services.dart';
import '../features/auth/ui/approval_pending_screen.dart';
import '../features/auth/ui/bot_check_screen.dart';
import '../features/auth/ui/firebase_welcome_screen.dart';
import '../features/auth/ui/password_screen.dart';
import '../features/auth/ui/welcome_screen.dart';
import '../shared/widgets/brand_logo.dart';
import '../shared/widgets/empty_state.dart';
import 'brand.dart';
import 'shell/app_shell.dart';

/// Chooses the home page for the current session state. It listens to the
/// controller itself, so the app root only rebuilds for session and theme.
class SessionGate extends StatelessWidget {
  const SessionGate({
    super.key,
    required this.controller,
    required this.devices,
    required this.starting,
    required this.startupError,
    required this.onRetry,
    required this.promptForPush,
    this.beforePushPrompt,
  });
  final AppController controller;
  final DeviceServices devices;
  final bool starting;

  /// The raw exception of a failed start, shown under 'Details'.
  final Object? startupError;
  final VoidCallback onRetry;
  final bool promptForPush;

  /// Resolves once other startup dialogs (the update check) are done.
  final Future<void> Function()? beforePushPrompt;

  @override
  Widget build(BuildContext context) {
    if (starting) return const _StartupProgress();
    if (startupError != null) {
      return _StartupError(error: startupError!, onRetry: onRetry);
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => controller.user == null
          ? controller.usesFirebase
                // The bot check comes before the first sign-in on a device.
                ? controller.needsBotCheck
                      ? BotCheckScreen(controller: controller)
                      : FirebaseWelcomeScreen(controller: controller)
                : WelcomeScreen(controller: controller)
          : !controller.hasAccess
          ? ApprovalPendingScreen(controller: controller, devices: devices)
          : controller.user!.mustChangePassword
          ? PasswordScreen(controller: controller, requiredChange: true)
          : AppShell(
              controller: controller,
              devices: devices,
              promptForPush: promptForPush,
              beforePushPrompt: beforePushPrompt,
            ),
    );
  }
}

class _StartupProgress extends StatelessWidget {
  const _StartupProgress();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BrandLogo(size: 72),
          const SizedBox(height: 16),
          Text(Brand.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 28),
          const CircularProgressIndicator.adaptive(),
        ],
      ),
    ),
  );
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: EmptyState(
              icon: Icons.storage_outlined,
              title: 'Start gerade nicht möglich',
              message:
                  'Die gespeicherten App-Daten auf diesem Gerät ließen sich '
                  'nicht öffnen. Versuch es bitte noch einmal. Hilft das '
                  'nicht, starte die App neu.',
              action: Column(
                children: [
                  FilledButton(
                    onPressed: onRetry,
                    child: const Text('Erneut versuchen'),
                  ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    title: const Text('Details'),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [SelectableText('$error')],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
