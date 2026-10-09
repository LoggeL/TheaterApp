import 'package:flutter/material.dart';
import '../core/pwa_install.dart';

class PwaInstallCard extends StatefulWidget {
  const PwaInstallCard({super.key, this.installation, this.homeHint = false});
  final PwaInstallation? installation;

  /// Dismissible variant for the home screen. Only shown on iOS, where Safari
  /// offers no install prompt and the share menu option is easily missed.
  final bool homeHint;
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
      if (_installation.devicePlatform == 'ios') {
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => IosInstallSteps(embedded: _installation.embedded),
        );
        return;
      }
      final instructions = switch (_installation.devicePlatform) {
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
      if (widget.homeHint &&
          (_installation.devicePlatform != 'ios' || _installation.dismissed)) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: EdgeInsets.only(
          top: widget.homeHint ? 0 : 18,
          bottom: widget.homeHint ? 16 : 0,
        ),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.homeHint
                            ? 'Zum Home-Bildschirm hinzufügen'
                            : 'Theater-App installieren',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (widget.homeHint)
                      IconButton(
                        tooltip: 'Hinweis ausblenden',
                        onPressed: _installation.dismiss,
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  widget.homeHint
                      ? 'Starte die Theater-App wie eine normale App direkt von deinem Home-Bildschirm.'
                      : 'Starte die App direkt über ihr Symbol auf deinem Gerät.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _install,
                  icon: const Icon(Icons.install_mobile_outlined),
                  label: Text(
                    _installation.canPrompt
                        ? 'Installieren'
                        : widget.homeHint
                        ? 'So geht’s'
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

/// Step-by-step guide for Safari's "Zum Home-Bildschirm", which iOS does not
/// let websites trigger themselves.
class IosInstallSteps extends StatelessWidget {
  const IosInstallSteps({super.key, required this.embedded});
  final bool embedded;
  @override
  Widget build(BuildContext context) {
    final steps = [
      if (embedded)
        (
          Icons.open_in_browser,
          'In Safari öffnen',
          'Diese Ansicht kann keine Apps hinzufügen. Öffne die Seite über das Menü (⋯ oder Kompass-Symbol) in Safari.',
        ),
      (
        Icons.ios_share,
        'Teilen antippen',
        'Tippe in Safari auf das Teilen-Symbol. Falls es nicht sichtbar ist, findest du es im ⋯-Menü neben der Adresse.',
      ),
      (
        Icons.add_box_outlined,
        '„Zum Home-Bildschirm“ wählen',
        'Scrolle in der Liste nach unten, bis der Eintrag erscheint.',
      ),
      (
        Icons.check_circle_outline,
        '„Hinzufügen“ bestätigen',
        'Falls angezeigt, lass „Als Web-App öffnen“ eingeschaltet. Danach startest du die Theater-App über ihr Symbol.',
      ),
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Auf dem iPhone oder iPad installieren',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            for (final (index, (icon, title, detail)) in steps.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(child: Icon(icon)),
                title: Text('${index + 1}. $title'),
                subtitle: Text(detail),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Verstanden'),
            ),
          ],
        ),
      ),
    );
  }
}
