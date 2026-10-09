import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_version.dart';

class PrivacyLinks extends StatelessWidget {
  const PrivacyLinks({super.key, this.showVersion = true});

  /// The sign-in footers show the version; Mein Bereich has its own footer.
  final bool showVersion;

  Future<void> _open(BuildContext context, String fragment) async {
    final uri = Uri.parse(
      'https://theater-app.logge.top/privacy.html$fragment',
    );
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Keep the public contact route accessible if no browser is available.
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Datenschutz und Kontolöschung'),
        content: SelectableText(
          '$uri\n\nFür Datenschutzfragen oder die Löschung deines Kontos und deiner Daten: kolpingtheaterramsen@gmail.com',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Wrap(
        alignment: WrapAlignment.center,
        children: [
          TextButton(
            onPressed: () => _open(context, ''),
            child: const Text('Datenschutz'),
          ),
          TextButton(
            onPressed: () => _open(context, '#konto-loeschen'),
            child: const Text('Konto und Daten löschen'),
          ),
        ],
      ),
      if (showVersion)
        Text(
          appVersionLabel,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
    ],
  );
}
