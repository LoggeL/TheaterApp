import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../core/device_services.dart';

Future<void> requestPushOnOpen(
  BuildContext context,
  AppController controller,
  DeviceServices devices,
) async {
  final session = controller.sessionEpoch;
  if (!await devices.preparePushPrompt() ||
      !context.mounted ||
      controller.sessionEpoch != session) {
    return;
  }
  if (!kIsWeb) {
    await controller.setPreference('pushPromptSeen', true);
    try {
      await devices.enablePush();
    } catch (_) {
      /* Settings retain a manual retry. */
    }
    return;
  }
  // Browsers require a user gesture. Initializing FCM happens before the dialog.
  await showDialog<void>(
    context: context,
    builder: (_) => _PushPrompt(controller: controller, devices: devices),
  );
  if (controller.sessionEpoch == session) {
    await controller.setPreference('pushPromptSeen', true);
  }
}

class _PushPrompt extends StatefulWidget {
  const _PushPrompt({required this.controller, required this.devices});
  final AppController controller;
  final DeviceServices devices;
  @override
  State<_PushPrompt> createState() => _PushPromptState();
}

class _PushPromptState extends State<_PushPrompt> {
  bool _busy = false;
  String? _result;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Benachrichtigungen erlauben?'),
    content: Text(
      _result ??
          'Erhalte Erinnerungen und Änderungen zu euren Terminen direkt auf diesem Gerät.',
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(_result == null ? 'Jetzt nicht' : 'Schließen'),
      ),
      if (_result == null)
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    final message = await widget.devices.enablePush();
                    if (!mounted) return;
                    if (widget.controller.preferences['pushEnabled'] == true) {
                      Navigator.pop(this.context);
                    } else {
                      setState(() => _result = message);
                    }
                  } catch (e) {
                    if (mounted) setState(() => _result = e.toString());
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: Text(_busy ? 'Wird aktiviert …' : 'Erlauben'),
        ),
    ],
  );
}
