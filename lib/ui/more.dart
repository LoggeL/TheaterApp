import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/brand.dart';
import '../core/models.dart';
import '../core/device_services.dart';
import 'auth.dart';
import 'admin.dart';
import 'firebase_auth.dart';
import 'messages.dart';
import 'events.dart';
import 'theme.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({
    super.key,
    required this.controller,
    required this.devices,
  });
  final AppController controller;
  final DeviceServices devices;
  @override
  Widget build(BuildContext context) {
    final user = controller.user;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
      children: [
        const Eyebrow('Teil des Ensembles'),
        const SizedBox(height: 10),
        Text('Mein Bereich.', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 27,
                  backgroundColor: const Color(0xFFFFE2D3),
                  child: Text(
                    user?.initials ?? 'KR',
                    style: const TextStyle(
                      color: StageTheme.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user?.name ?? 'Ensemble',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        controller.isDemo
                            ? 'Demokonto · Beispieldaten'
                            : (user?.group.isNotEmpty == true
                                  ? user!.group
                                  : 'Kolpingtheater Ramsen'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (user?.isAdmin == true)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: StatePill(
                            'Administration',
                            color: StageTheme.violet,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('Im Theater'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Mitteilungen'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(context, MessagesScreen(controller: controller)),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              _MenuItem(
                Icons.beach_access_outlined,
                'Abwesenheiten',
                '${controller.absences.length} Zeiträume gemeldet',
                () => _open(context, AbsencesScreen(controller: controller)),
              ),
              const Divider(indent: 60),
              _MenuItem(
                Icons.groups_outlined,
                'Unser Ensemble',
                '${controller.members.length} Mitglieder',
                () => _open(context, MembersScreen(controller: controller)),
              ),
            ],
          ),
        ),
        const SectionTitle('So, wie du es brauchst'),
        Card(
          child: Column(
            children: [
              _MenuItem(
                Icons.tune,
                'Darstellung & Erinnerungen',
                'Design, Push und Benachrichtigungen',
                () => _open(
                  context,
                  SettingsScreen(controller: controller, devices: devices),
                ),
              ),
              const Divider(indent: 60),
              _MenuItem(
                Icons.sync_outlined,
                'Synchronisierung',
                controller.isDemo
                    ? 'Demo · alles bleibt auf diesem Gerät'
                    : '${controller.pendingCount} ausstehend · ${controller.failedCount} zu prüfen',
                () => _open(context, SyncScreen(controller: controller)),
              ),
              if (!controller.isDemo && (!controller.usesFirebase || controller.identity!.linkedProviders.contains('password'))) ...[
                const Divider(indent: 60),
                _MenuItem(
                  Icons.lock_outline,
                  'Passwort ändern',
                  'Deinen Zugang schützen',
                  () => _open(context, PasswordScreen(controller: controller)),
                ),
              ],
              if (controller.usesFirebase) ...[
                const Divider(indent: 60),
                _MenuItem(
                  Icons.login_outlined,
                  'Anmeldearten',
                  'Zugänge zu deinem Konto',
                  () => _open(
                    context,
                    AccountProvidersScreen(controller: controller),
                  ),
                ),
              ],
              if (user?.isAdmin == true && !controller.isDemo) ...[
                const Divider(indent: 60),
                _MenuItem(
                  Icons.admin_panel_settings_outlined,
                  'Probenleitung',
                  'Konten, Termine, Ensemble und Besetzung',
                  () =>
                      _open(context, ManagementScreen(controller: controller)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 26),
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(
                  controller.isDemo ? 'Demo verlassen?' : 'Abmelden?',
                ),
                content: Text(
                  controller.pendingCount + controller.failedCount > 0
                      ? 'Es gibt noch nicht übertragene Änderungen. Beim Abmelden werden lokale Daten und diese Änderungen gelöscht.'
                      : 'Die auf diesem Gerät gespeicherten Kontodaten und Drehbücher werden entfernt.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Hierbleiben'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Abmelden'),
                  ),
                ],
              ),
            );
            if (ok == true && context.mounted) {
              await runAction(context, () async {
                await devices.disablePush();
                await controller.logout();
              });
            }
          },
          icon: const Icon(Icons.logout),
          label: Text(controller.isDemo ? 'Demo verlassen' : 'Abmelden'),
        ),
        const SizedBox(height: 25),
        const Text(
          '${Brand.name} · 0.2.0\n${Brand.subtitle}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => showAboutDialog(
            context: context,
            applicationName: Brand.name,
            applicationVersion: '0.2.0',
            applicationIcon: const Icon(
              Icons.theater_comedy_outlined,
              size: 36,
            ),
            children: const [
              Text(
                'Eine gemeinsame Bühne für Termine und Texte. Entwicklungsstand zum Testen; Push und Serverzugriff benötigen eine konfigurierte Installation.',
              ),
            ],
          ),
          child: const Text('Über die App & Lizenzen'),
        ),
      ],
    );
  }
}

void _open(BuildContext context, Widget screen) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

class _MenuItem extends StatelessWidget {
  const _MenuItem(this.icon, this.title, this.subtitle, this.tap);
  final IconData icon;
  final String title, subtitle;
  final VoidCallback tap;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
    leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
    title: Text(
      title,
      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(subtitle, style: const TextStyle(fontSize: 12)),
    ),
    trailing: const Icon(Icons.chevron_right, size: 20),
    onTap: tap,
  );
}

class AbsencesScreen extends StatelessWidget {
  const AbsencesScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Abwesenheiten')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            _open(context, AddAbsenceScreen(controller: controller)),
        icon: const Icon(Icons.add),
        label: const Text('Zeitraum melden'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 100),
        children: [
          Text(
            'Mal nicht da?',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 10),
          const Text(
            'Sag dem Ensemble Bescheid, wenn du länger fehlst. Passende bestehende Proben werden beim Speichern automatisch abgesagt.',
          ),
          const SizedBox(height: 24),
          if (controller.absences.isEmpty)
            const EmptyState(
              icon: Icons.beach_access_outlined,
              title: 'Keine Abwesenheiten',
              message:
                  'Urlaub, Arbeit oder eine Pause: Melde hier deinen Zeitraum.',
            ),
          ...controller.absences.map(
            (absence) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.date_range_outlined,
                        color: StageTheme.orange,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${DateFormat('dd.MM.yyyy').format(absence.from)} – ${DateFormat('dd.MM.yyyy').format(absence.to)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (absence.reason.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 7),
                                child: Text(absence.reason),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Abwesenheit löschen',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Abwesenheit entfernen?'),
                              content: const Text(
                                'Bereits gespeicherte Absagen bleiben bestehen. Ändere sie bei Bedarf im jeweiligen Termin.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Abbrechen'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Entfernen'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true && context.mounted) {
                            await runAction(
                              context,
                              () => controller.deleteAbsence(absence.id),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class AddAbsenceScreen extends StatefulWidget {
  const AddAbsenceScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<AddAbsenceScreen> createState() => _AddAbsenceScreenState();
}

class _AddAbsenceScreenState extends State<AddAbsenceScreen> {
  DateTimeRange? _range;
  final _reason = TextEditingController();
  bool _saving = false;
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_range == null) return;
    setState(() => _saving = true);
    try {
      await widget.controller.addAbsence(
        _range!.start,
        _range!.end,
        _reason.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Abwesenheit melden')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Eyebrow('Gut zu wissen'),
        const SizedBox(height: 12),
        Text(
          'Wann fehlst du?',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 22),
        OutlinedButton.icon(
          onPressed: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime.now().subtract(const Duration(days: 365)),
              lastDate: DateTime.now().add(const Duration(days: 730)),
              initialDateRange: _range,
            );
            if (mounted && picked != null) setState(() => _range = picked);
          },
          icon: const Icon(Icons.calendar_month),
          label: Text(
            _range == null
                ? 'Zeitraum auswählen'
                : '${DateFormat('dd.MM.yyyy').format(_range!.start)} – ${DateFormat('dd.MM.yyyy').format(_range!.end)}',
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _reason,
          decoration: const InputDecoration(
            labelText: 'Grund (freiwillig)',
            hintText: 'Zum Beispiel: Urlaub',
          ),
          minLines: 3,
          maxLines: 5,
          maxLength: 500,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _range == null || _saving ? null : _save,
          child: Text(_saving ? 'Wird gespeichert …' : 'Abwesenheit melden'),
        ),
      ],
    ),
  );
}

class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final members = widget.controller.members
        .where(
          (m) => '${m.name} ${m.group}'.toLowerCase().contains(
            _query.toLowerCase(),
          ),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Unser Ensemble')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Name oder Gruppe suchen',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: members.length,
              separatorBuilder: (_, i) => const Divider(indent: 82),
              itemBuilder: (context, i) {
                final member = members[i];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 7,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFE8DED1),
                    child: Text(
                      member.initials,
                      style: const TextStyle(
                        color: StageTheme.ink,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  title: Text(member.name),
                  subtitle: Text(member.group),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class CheckInScreen extends StatefulWidget {
  const CheckInScreen({
    super.key,
    required this.controller,
    required this.event,
  });
  final AppController controller;
  final TheaterEvent event;
  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  final _present = <int>{};
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    final saved = jsonMap(widget.controller.checkinsByEvent[widget.event.id]);
    _present.addAll(
      widget.controller.members
          .where((m) => m.active && saved[m.id.toString()] == true)
          .map((m) => m.id),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Anwesenheit erfassen')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.event.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text('${_present.length} als anwesend markiert'),
              const SizedBox(height: 8),
              const Text(
                'Speichert die vollständige Anwesenheitsliste für diesen Termin. Bitte alle Anwesenden auswählen.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.controller.members.where((m) => m.active).length,
            itemBuilder: (context, index) {
              final member = widget.controller.members
                  .where((m) => m.active)
                  .elementAt(index);
              return CheckboxListTile(
                title: Text(member.name),
                subtitle: Text(member.group),
                value: _present.contains(member.id),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    _present.add(member.id);
                  } else {
                    _present.remove(member.id);
                  }
                }),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving
                    ? null
                    : () async {
                        setState(() => _saving = true);
                        try {
                          await widget.controller.checkIn(
                            widget.event.id,
                            _present.toList(),
                          );
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(e.toString())),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _saving = false);
                        }
                      },
                child: Text(
                  _saving ? 'Wird gespeichert …' : 'Anwesenheit speichern',
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.devices,
  });
  final AppController controller;
  final DeviceServices devices;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Darstellung & Erinnerungen')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const Eyebrow('Deine App'),
          const SectionTitle('Darstellung'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<String>(
                initialValue:
                    controller.preferences['themeMode'] as String? ?? 'system',
                decoration: const InputDecoration(labelText: 'Farbschema'),
                items: const [
                  DropdownMenuItem(
                    value: 'system',
                    child: Text('Wie dein Gerät'),
                  ),
                  DropdownMenuItem(value: 'light', child: Text('Hell')),
                  DropdownMenuItem(value: 'dark', child: Text('Dunkel')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    runAction(
                      context,
                      () => controller.setPreference('themeMode', v),
                    );
                  }
                },
              ),
            ),
          ),
          const SectionTitle('Erinnere mich'),
          Card(
            child: Column(
              children: [
                for (final item in const [
                  ('dayBefore', 'Am Vortag', 'Einen Tag vor einer Probe'),
                  (
                    'twoHours',
                    'Zwei Stunden vorher',
                    'Noch genug Zeit zum Losfahren',
                  ),
                  ('changes', 'Bei Änderungen', 'Wenn sich ein Termin ändert'),
                ])
                  SwitchListTile(
                    title: Text(item.$2),
                    subtitle: Text(item.$3),
                    value: controller.reminders[item.$1] ?? true,
                    onChanged: (v) => runAction(
                      context,
                      () => controller.saveReminders({
                        ...controller.reminders,
                        item.$1: v,
                      }),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            controller.isDemo
                ? 'In der Demo werden deine Einstellungen lokal gespeichert. Es werden keine Benachrichtigungen versendet.'
                : Brand.pushEnabled
                ? 'Push-Benachrichtigungen werden erst nach deiner Freigabe auf diesem Gerät aktiviert.'
                : 'Push ist in diesem Build noch nicht konfiguriert. Die App speichert deine Wünsche bereits für den späteren Betrieb.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: controller.isDemo || !Brand.pushEnabled
                ? null
                : () => runAction(context, () async {
                    final message = await devices.enablePush();
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(message)));
                    }
                  }),
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('Push auf diesem Gerät aktivieren'),
          ),
          if (!controller.isDemo && Brand.pushEnabled)
            TextButton(
              onPressed: () => runAction(
                context,
                devices.disablePush,
                message: 'Push-Gerät abgemeldet.',
              ),
              child: const Text('Push auf diesem Gerät deaktivieren'),
            ),
          const SectionTitle('Offline'),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Geöffnete Drehbücher und zuletzt geladene Termine bleiben auf diesem Gerät verfügbar. Rückmeldungen werden zwischengespeichert und bei der nächsten Synchronisierung übertragen. Beim Abmelden werden diese Kontodaten entfernt.',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Synchronisierung')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          StatePill(
            controller.isDemo
                ? 'Lokale Demo'
                : controller.isOffline
                ? 'Offline'
                : 'Server verbunden',
            color: controller.isOffline ? StageTheme.orange : StageTheme.green,
            icon: controller.isOffline
                ? Icons.cloud_off
                : Icons.cloud_done_outlined,
          ),
          const SizedBox(height: 18),
          Text(
            controller.lastSync == null
                ? 'Noch keine Server-Synchronisierung.'
                : 'Zuletzt aktualisiert: ${DateFormat('dd.MM.yyyy · HH:mm').format(controller.lastSync!.toLocal())}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          if (!controller.isDemo)
            SelectableText(
              controller.apiBaseUrl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: controller.busy
                ? null
                : () => runAction(context, controller.retryPending),
            icon: const Icon(Icons.sync),
            label: const Text('Jetzt synchronisieren'),
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SectionTitle('Ausstehende Änderungen'),
          if (controller.outbox.isEmpty)
            const EmptyState(
              icon: Icons.done_all,
              title: 'Alles auf dem aktuellen Stand.',
              message: 'Es warten keine lokalen Änderungen auf Übertragung.',
            ),
          ...controller.outbox.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: Icon(
                    entry.failed
                        ? Icons.error_outline
                        : Icons.schedule_send_outlined,
                    color: entry.failed
                        ? Theme.of(context).colorScheme.error
                        : StageTheme.orange,
                  ),
                  title: Text(entry.label),
                  subtitle: Text(
                    entry.lastError ??
                        'Wartet auf Übertragung · ${DateFormat.Hm().format(entry.createdAt)}',
                  ),
                  isThreeLine: entry.lastError != null,
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Änderung bearbeiten',
                    itemBuilder: (_) => [
                      if (entry.failed)
                        const PopupMenuItem(
                          value: 'retry',
                          child: Text('Erneut versuchen'),
                        ),
                      const PopupMenuItem(
                        value: 'discard',
                        child: Text('Änderung verwerfen'),
                      ),
                    ],
                    onSelected: (choice) => runAction(
                      context,
                      () => choice == 'retry'
                          ? controller.retryFailed(entry.id)
                          : controller.discardAction(entry.id),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
