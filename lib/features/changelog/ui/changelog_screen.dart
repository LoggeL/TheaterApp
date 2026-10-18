import 'package:flutter/material.dart';

import '../../../core/app_version.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../domain/changelog.dart';

/// Opens "Was ist neu".
Future<void> openChangelog(BuildContext context) =>
    openPage<void>(context, const ChangelogScreen());

/// What changed in the recent versions, newest first.
class ChangelogScreen extends StatelessWidget {
  const ChangelogScreen({super.key, this.entries = changelog});
  final List<ChangelogEntry> entries;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Was ist neu')),
    body: ListView(
      padding: pagePadding(context),
      children: [
        const PageHeader(
          'Was ist neu',
          eyebrow: 'Neuigkeiten',
          subtitle: 'Was sich in den letzten Versionen der App getan hat.',
        ),
        for (final entry in entries) _EntryCard(entry: entry),
      ],
    ),
  );
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry});
  final ChangelogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Version ${entry.version}',
                  style: theme.textTheme.titleMedium,
                ),
                if (entry.version == appVersion)
                  const StatePill('Deine Version'),
              ],
            ),
            const SizedBox(height: 2),
            Text(entry.date, style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            for (final item in entry.items)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Text(
                        '•  ',
                        style: TextStyle(color: theme.colorScheme.primary),
                      ),
                    ),
                    Expanded(child: Text(item)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The app version as a quiet link to "Was ist neu". [label] defaults to
/// the version label.
class VersionLink extends StatelessWidget {
  const VersionLink({super.key, this.label = appVersionLabel, this.style});
  final String label;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = style ?? theme.textTheme.bodySmall;
    return Semantics(
      button: true,
      label: '$label, Was ist neu',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('version-link'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => openChangelog(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, textAlign: TextAlign.center, style: base),
              Text(
                'Was ist neu?',
                style: base?.copyWith(color: theme.colorScheme.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
