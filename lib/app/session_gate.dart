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
    return _SessionPage(
      controller: controller,
      devices: devices,
      promptForPush: promptForPush,
      beforePushPrompt: beforePushPrompt,
    );
  }
}

/// What decides the home page; see [_SessionPageState._gate].
typedef _Gate = ({
  bool signedIn,
  bool usesFirebase,
  bool needsBotCheck,
  bool hasAccess,
  bool mustChangePassword,
});

/// The home page for the session. The sign-in and approval pages read the
/// controller (errors, settings) and rebuild with every change. The app
/// shell listens itself, so it is rebuilt here only when the page changes.
class _SessionPage extends StatefulWidget {
  const _SessionPage({
    required this.controller,
    required this.devices,
    required this.promptForPush,
    required this.beforePushPrompt,
  });
  final AppController controller;
  final DeviceServices devices;
  final bool promptForPush;
  final Future<void> Function()? beforePushPrompt;

  @override
  State<_SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<_SessionPage> {
  late _Gate _shown = _gate;

  _Gate get _gate {
    final c = widget.controller;
    return (
      signedIn: c.user != null,
      usesFirebase: c.usesFirebase,
      needsBotCheck: c.needsBotCheck,
      hasAccess: c.hasAccess,
      mustChangePassword: c.user?.mustChangePassword == true,
    );
  }

  static bool _isShell(_Gate gate) =>
      gate.signedIn && gate.hasAccess && !gate.mustChangePassword;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(_SessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final gate = _gate;
    if (gate != _shown || !_isShell(gate)) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller, gate = _shown = _gate;
    if (!gate.signedIn) {
      return gate.usesFirebase
          // The bot check comes before the first sign-in on a device.
          ? gate.needsBotCheck
                ? BotCheckScreen(controller: controller)
                : FirebaseWelcomeScreen(controller: controller)
          : WelcomeScreen(controller: controller);
    }
    if (!gate.hasAccess) {
      return ApprovalPendingScreen(
        controller: controller,
        devices: widget.devices,
      );
    }
    if (gate.mustChangePassword) {
      return PasswordScreen(controller: controller, requiredChange: true);
    }
    return AppShell(
      controller: controller,
      devices: widget.devices,
      promptForPush: widget.promptForPush,
      beforePushPrompt: widget.beforePushPrompt,
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
