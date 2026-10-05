import 'package:flutter/material.dart';
import '../core/pwa_install.dart';

class PwaInstallCard extends StatefulWidget {
  const PwaInstallCard({super.key, this.installation});
  final PwaInstallation? installation;
  @override
  State<PwaInstallCard> createState() => _PwaInstallCardState();
}

class _PwaInstallCardState extends State<PwaInstallCard> {
  late final PwaInstallation _installation;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _installation = widget.installation ?? PwaInstallation.create();
  }

  @override
  void dispose() {
    if (widget.installation == null) _installation.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    if (!_installation.canPrompt) {
      final instructions = switch (_installation.devicePlatform) {
        'ios' =>
          'Öffne die App in Safari. Tippe auf Teilen, dann auf "Zum Home-Bildschirm" und bestätige mit "Hinzufügen".',
        'android' =>
          'Öffne die App in Chrome. Wähle im Browsermenü "App installieren" oder "Zum Startbildschirm hinzufügen".',
        'macos' =>
          'Wähle in Safari "Ablage" und dann "Zum Dock hinzufügen". In Chrome oder Edge nutze das Installationssymbol in der Adressleiste.',
        _ =>
          'Öffne die App in Chrome oder Edge. Nutze das Installationssymbol in der Adressleiste oder "App installieren" im Browsermenü.',
      };
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('App installieren'),
          content: Text(instructions),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Verstanden'),
            ),
          ],
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await _installation.prompt();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Die Installation konnte nicht gestartet werden. Bitte nutze das Browsermenü.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _installation,
    builder: (context, _) {
      if (!_installation.available || _installation.installed) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Theater-App installieren',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Starte die App direkt über ihr Symbol auf deinem Gerät.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _install,
                  icon: const Icon(Icons.install_mobile_outlined),
                  label: Text(
                    _installation.canPrompt
                        ? 'Installieren'
                        : 'Installationsanleitung',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
