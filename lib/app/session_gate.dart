import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/device_services.dart';
import '../features/auth/ui/approval_pending_screen.dart';
import '../features/auth/ui/firebase_welcome_screen.dart';
import '../features/auth/ui/password_screen.dart';
import '../features/auth/ui/welcome_screen.dart';
import '../shared/widgets/empty_state.dart';
import 'shell/app_shell.dart';

/// Chooses the home page for the current session state.
class SessionGate extends StatelessWidget {
  const SessionGate({
    super.key,
    required this.controller,
    required this.devices,
    required this.starting,
    required this.startupError,
    required this.onRetry,
    required this.promptForPush,
  });
  final AppController controller;
  final DeviceServices devices;
  final bool starting;
  final String? startupError;
  final VoidCallback onRetry;
  final bool promptForPush;

  @override
  Widget build(BuildContext context) => starting
      ? const Scaffold(
          body: Center(child: CircularProgressIndicator.adaptive()),
        )
      : startupError != null
      ? Scaffold(
          body: SafeArea(
            child: EmptyState(
              icon: Icons.storage_outlined,
              title: 'Start gerade nicht möglich',
              message: startupError!,
              action: FilledButton(
                onPressed: onRetry,
                child: const Text('Erneut versuchen'),
              ),
            ),
          ),
        )
      : controller.user == null
      ? controller.usesFirebase
            ? FirebaseWelcomeScreen(controller: controller)
            : WelcomeScreen(controller: controller)
      : !controller.hasAccess
      ? ApprovalPendingScreen(controller: controller)
      : controller.user!.mustChangePassword
      ? PasswordScreen(controller: controller, requiredChange: true)
      : AppShell(
          controller: controller,
          devices: devices,
          promptForPush: promptForPush,
        );
}
