import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../data/api_client.dart' show ApiException;
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../data/admin_releases_api.dart';
import 'admin_skin_viewer.dart' show releaseDateText;
import 'runner_menu.dart' show berlinWallClock;

/// Opens the admins' Release-Zeitplan; nothing for anybody else.
Future<void> openAdminReleaseSchedule(
  BuildContext context,
  AppController controller,
) async {
  if (!adminReleasesAvailable(controller)) return;
  await openPage<void>(
    context,
    AdminReleaseScheduleScreen(controller: controller),
  );
}

/// "Push gesendet am So., 22.11.2026, 18:00" …: how the drop push stands.
String releasePushText(AdminRelease release) => switch (release.pushState) {
  'sent' =>
    release.pushAt == null
        ? 'Push gesendet'
        : 'Push gesendet am ${releaseDateText(release.pushAt!)}',
  'skipped' => 'Kein Push: erst über 24 Stunden nach dem Termin erkannt',
  'held' => 'Push folgt, sobald alle Bilder da sind',
  'silent' => 'Ohne Push (vor Einführung des Drop-Pushs gestartet)',
  _ => 'Push „Neu: ${release.name}“ zum Termin',
};

/// "Geplant · Bilder fehlen noch (3)", "Blockiert · 2 Bilder fehlen", "Live".
String releaseStatusText(AdminRelease release) => switch (release.status) {
  AdminReleaseStatus.live => 'Live',
  AdminReleaseStatus.blocked =>
    'Blockiert wegen fehlender Bilder'
        '${release.missing > 0 ? ' (${release.missing})' : ''}',
  AdminReleaseStatus.scheduled =>
    release.ready
        ? 'Geplant'
        : 'Geplant · Bilder fehlen noch'
              '${release.missing > 0 ? ' (${release.missing})' : ''}',
};

/// The admins' Release-Zeitplan of the stage runner: the drops of
/// releases.json in order, with their state, and a new date for each.
/// A new date applies on the server at once and overrides releases.json.
class AdminReleaseScheduleScreen extends StatefulWidget {
  const AdminReleaseScheduleScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<AdminReleaseScheduleScreen> createState() =>
      _AdminReleaseScheduleScreenState();
}

class _AdminReleaseScheduleScreenState
    extends State<AdminReleaseScheduleScreen> {
  AdminReleasePlan? _plan;
  Object? _error;
  bool _loading = false, _saving = false;

  bool get _allowed => adminReleasesAvailable(widget.controller);

  @override
  void initState() {
    super.initState();
    if (_allowed) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final plan = await loadAdminReleases(widget.controller);
      if (mounted) setState(() => _plan = plan);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => _allowed
        ? _page(context)
        : Scaffold(
            appBar: AppBar(title: const Text('Release-Zeitplan')),
            body: const Center(child: Text('Nur für Admins.')),
          ),
  );

  Widget _page(BuildContext context) {
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Release-Zeitplan'),
        actions: [
          IconButton(
            tooltip: 'Neu laden',
            onPressed: _loading || _saving ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _saving || (_loading && plan != null)
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: plan == null
          ? _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            userMessage(_error!),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.tonal(
                            onPressed: _load,
                            child: const Text('Erneut versuchen'),
                          ),
                        ],
                      ),
                    ),
                  )
                : const Center(child: CircularProgressIndicator())
          : _list(context, plan),
    );
  }

  Widget _list(BuildContext context, AdminReleasePlan plan) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            'Alle Zeiten in deutscher Zeit (Europe/Berlin). Ein neuer Termin '
            'gilt sofort auf dem Server und überschreibt releases.json, ohne '
            'Bereitstellung. Ein Pack geht erst live, wenn alle Bilder da '
            'sind. Der Push „Neu: …“ kommt einmal und wird höchstens '
            '24 Stunden nachgeholt.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (plan.releases.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('Keine Releases geplant.')),
            ),
          for (final release in plan.releases)
            _ReleaseCard(
              release: release,
              onTap: _saving ? null : () => _edit(release),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(AdminRelease release) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                release.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              subtitle: Text('${releaseDateText(release.startsAt)} Uhr'),
            ),
            ListTile(
              key: const ValueKey('release-change-date'),
              leading: const Icon(Icons.edit_calendar_outlined),
              title: const Text('Termin ändern'),
              onTap: () => Navigator.pop(context, 'change'),
            ),
            if (release.overridden)
              ListTile(
                key: const ValueKey('release-reset-date'),
                leading: const Icon(Icons.restore),
                title: const Text('Termin aus releases.json'),
                subtitle: Text(
                  '${releaseDateText(release.plannedStartsAt)} Uhr',
                ),
                onTap: () => Navigator.pop(context, 'reset'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'reset') {
      await _save(release, reset: true);
      return;
    }
    final picked = await _pick(release);
    if (!mounted || picked == null) return;
    await _save(release, day: picked.day, time: picked.time);
  }

  /// A new day and time on the Berlin wall clock, or null when cancelled.
  Future<({DateTime day, TimeOfDay time})?> _pick(AdminRelease release) async {
    final wall = berlinWallClock(release.startsAt);
    final day = await showDatePicker(
      context: context,
      initialDate: DateTime(wall.year, wall.month, wall.day),
      firstDate: DateTime(2020),
      lastDate: DateTime(2099, 12, 31),
      helpText: 'Neuer Termin für ${release.name}',
    );
    if (day == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: wall.hour, minute: wall.minute),
      helpText: 'Uhrzeit (deutsche Zeit)',
    );
    if (time == null || !mounted) return null;
    return (day: day, time: time);
  }

  Future<void> _save(
    AdminRelease release, {
    DateTime? day,
    TimeOfDay? time,
    bool reset = false,
    bool confirm = false,
  }) async {
    setState(() => _saving = true);
    try {
      await rescheduleAdminRelease(
        widget.controller,
        release.id,
        day: day,
        hour: time?.hour ?? 18,
        minute: time?.minute ?? 0,
        reset: reset,
        confirm: confirm,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Termin von „${release.name}“ gespeichert.')),
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'release_live' && !confirm) {
        setState(() => _saving = false);
        final go = await confirmAction(
          context,
          title: 'Bereits freigeschaltet',
          message:
              '${e.message}\n\nDie Inhalte verschwinden für alle bis zum neuen '
              'Termin.',
          confirmLabel: 'Trotzdem verschieben',
          destructive: true,
        );
        if (go && mounted) {
          await _save(
            release,
            day: day,
            time: time,
            reset: reset,
            confirm: true,
          );
        }
        return;
      }
      showProblem(context, e);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.release, required this.onTap});
  final AdminRelease release;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (background, foreground) = switch (release.status) {
      AdminReleaseStatus.live => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      AdminReleaseStatus.blocked => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      AdminReleaseStatus.scheduled => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    final count = release.itemCount == 1
        ? '1 Inhalt'
        : '${release.itemCount} Inhalte';
    return Card(
      key: ValueKey('release-${release.id}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(release.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${releaseDateText(release.startsAt)} Uhr · $count',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (release.overridden)
                      Text(
                        'Geändert · laut releases.json '
                        '${releaseDateText(release.plannedStartsAt)} Uhr',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.tertiary,
                        ),
                      ),
                    // The chip says it already, unless there is more.
                    if (releaseStatusText(release) != release.status.label)
                      Text(
                        releaseStatusText(release),
                        style: theme.textTheme.bodySmall,
                      ),
                    Text(
                      releasePushText(release),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  release.status.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
