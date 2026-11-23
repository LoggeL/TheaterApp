import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/app_version.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../domain/changelog.dart';

/// Preference key storing the newest app version whose changelog was opened.
const seenChangelogVersionKey = 'seenChangelogVersion';

const _adminItemPrefix = 'Für die Theaterleitung:';
const _initialChangelogCount = 5;

/// Whether the signed-in member has not yet opened "Was ist neu" for
/// [appVersion].
bool hasUnseenChangelog(AppController controller) =>
    controller.user != null &&
    controller.preferences[seenChangelogVersionKey] != appVersion;

/// Opens "Was ist neu" and marks [appVersion] as seen when [controller] is set.
Future<void> openChangelog(BuildContext context, {AppController? controller}) {
  if (controller != null && hasUnseenChangelog(controller)) {
    unawaited(controller.setPreference(seenChangelogVersionKey, appVersion));
  }
  return openPage<void>(context, ChangelogScreen(controller: controller));
}

/// What changed in the recent versions, newest first.
class ChangelogScreen extends StatefulWidget {
  const ChangelogScreen({
    super.key,
    this.entries = changelog,
    this.controller,
    this.isAdmin,
  });
  final List<ChangelogEntry> entries;
  final AppController? controller;
  final bool? isAdmin;

  @override
  State<ChangelogScreen> createState() => _ChangelogScreenState();
}

class _ChangelogScreenState extends State<ChangelogScreen> {
  bool _showOlder = false;
  bool _showAdminItems = false;

  bool get _isAdmin => widget.isAdmin ?? widget.controller?.user?.isAdmin ?? false;

  static bool _isAdminItem(String item) => item.startsWith(_adminItemPrefix);

  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    if (controller != null && hasUnseenChangelog(controller)) {
      Future.microtask(() {
        if (hasUnseenChangelog(controller)) {
          unawaited(
            controller.setPreference(seenChangelogVersionKey, appVersion),
          );
        }
      });
    }
  }

  bool get _hasAdminItems =>
      widget.entries.any((entry) => entry.items.any(_isAdminItem));

  List<ChangelogEntry> get _filteredEntries {
    if (_isAdmin || _showAdminItems) return widget.entries;
    return [
      for (final entry in widget.entries)
        if (entry.items.any((item) => !_isAdminItem(item)))
          ChangelogEntry(
            version: entry.version,
            date: entry.date,
            items: [
              for (final item in entry.items)
                if (!_isAdminItem(item)) item,
            ],
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _filteredEntries;
    final shown = _showOlder || visible.length <= _initialChangelogCount
        ? visible
        : visible.take(_initialChangelogCount).toList();
    final hiddenOlder = visible.length - shown.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Was ist neu')),
      body: ListView(
        padding: pagePadding(context),
        children: [
          const PageHeader(
            'Was ist neu',
            eyebrow: 'Neuigkeiten',
            subtitle: 'Was sich in den letzten Versionen der App getan hat.',
          ),
          if (!_isAdmin && _hasAdminItems)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                    key: const ValueKey('changelog-show-all'),
                    selected: _showAdminItems,
                    avatar: const Icon(Icons.visibility_outlined, size: 18),
                    label: const Text('Alle zeigen'),
                    onSelected: (value) =>
                        setState(() => _showAdminItems = value),
                  ),
                  Text(
                    _showAdminItems
                        ? 'Auch Änderungen für die Theaterleitung werden angezeigt.'
                        : 'Änderungen nur für die Theaterleitung sind ausgeblendet.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'In den letzten Versionen gab es nur Änderungen für die Theaterleitung.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (final entry in shown) _EntryCard(entry: entry),
          if (hiddenOlder > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 16),
              child: Center(
                child: OutlinedButton.icon(
                  key: const ValueKey('changelog-show-older'),
                  onPressed: () => setState(() => _showOlder = true),
                  icon: const Icon(Icons.expand_more),
                  label: Text(
                    hiddenOlder == 1
                        ? '1 ältere Version anzeigen'
                        : '$hiddenOlder ältere Versionen anzeigen',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
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
  const VersionLink({
    super.key,
    this.label = appVersionLabel,
    this.style,
    this.controller,
  });
  final String label;
  final TextStyle? style;
  final AppController? controller;

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
        onTap: () => openChangelog(context, controller: controller),
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
