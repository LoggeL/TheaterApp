import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../../../core/app_controller.dart';
import '../../../core/device_services.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/widgets/one_line_segmented_button.dart';
import '../../../shared/widgets/page_header.dart';
import '../domain/reminder_lead_times.dart';

/// Answer of [DeviceServices.enablePush] when the operating system or browser
/// blocks notifications for the app.
const _pushBlocked =
    'Benachrichtigungen sind in den Geräteeinstellungen deaktiviert.';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.devices,
  });
  final AppController controller;
  final DeviceServices devices;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pushBusy = false, _blocked = false;

  AppController get controller => widget.controller;

  bool get _pushAvailable => !controller.isDemo && Brand.pushEnabled;
  bool get _pushOn => controller.preferences['pushEnabled'] == true;

  String get _pushStatus {
    if (controller.isDemo) return 'In der Demo nicht verfügbar';
    if (!Brand.pushEnabled) return 'In dieser App-Version nicht eingerichtet';
    if (_pushBusy) return 'Wird eingerichtet …';
    if (_blocked && !_pushOn) {
      return 'Blockiert – erlaube Benachrichtigungen in den Geräteeinstellungen';
    }
    if (!_pushOn) return 'Aus';
    return controller.pushConfigured
        ? 'Aktiv auf diesem Gerät'
        : 'Gerät registriert · Server-Versand noch nicht aktiv';
  }

  Future<void> _setPush(bool on) async {
    setState(() => _pushBusy = true);
    try {
      if (on) {
        final message = await widget.devices.enablePush();
        if (!mounted) return;
        setState(() => _blocked = message == _pushBlocked);
        showDone(context, message);
      } else {
        await widget.devices.disablePush();
        if (mounted) showDone(context, 'Push auf diesem Gerät ausgeschaltet.');
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _pushBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final user = controller.user;
      final lateDeclines =
          controller.supports('lateDeclines') &&
          (user?.isAdmin == true ||
              user?.directorProductionIds.isNotEmpty == true);
      final emailOn =
          controller.emailConfigured &&
          (controller.reminders['emailEnabled'] ?? false);
      return Scaffold(
        appBar: AppBar(title: const Text('Benachrichtigungen & Darstellung')),
        body: ListView(
          padding: pagePadding(context),
          children: [
            const SectionTitle('Benachrichtigungen'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_outlined),
                    title: const Text('Push auf diesem Gerät'),
                    subtitle: Text(_pushStatus),
                    value: _pushAvailable && _pushOn,
                    onChanged: _pushAvailable && !_pushBusy ? _setPush : null,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.mail_outline),
                    title: const Text('Termin-E-Mails'),
                    subtitle: Text(
                      controller.emailConfigured
                          ? 'Neue Termine, Änderungen und Erinnerungen an deine bestätigte Anmeldeadresse.'
                          : 'Der E-Mail-Versand ist noch nicht eingerichtet.',
                    ),
                    value: controller.reminders['emailEnabled'] ?? false,
                    onChanged: controller.emailConfigured
                        ? (value) => runAction(
                            context,
                            () => controller.saveReminders({
                              ...controller.reminders,
                              'emailEnabled': value,
                            }),
                          )
                        : null,
                  ),
                  if (controller.emailConfigured)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextButton.icon(
                        icon: const Icon(Icons.forward_to_inbox_outlined),
                        label: const Text('Test-E-Mail an mich senden'),
                        onPressed: controller.isOffline
                            ? null
                            : () => runAction(
                                context,
                                () => controller.performAction({
                                  'action': 'email.test',
                                }),
                                message: 'Test-E-Mail angefordert.',
                              ),
                      ),
                    ),
                  if (lateDeclines) ...[
                    const Divider(height: 1),
                    SwitchListTile(
                      secondary: const Icon(Icons.event_busy_outlined),
                      title: const Text('Kurzfristige Absagen melden'),
                      subtitle: const Text(
                        'Push, wenn jemand weniger als 24 Stunden vor Beginn absagt',
                      ),
                      value: controller.reminders['lateDeclines'] ?? true,
                      onChanged: (value) => runAction(
                        context,
                        () => controller.saveReminders({
                          ...controller.reminders,
                          'lateDeclines': value,
                        }),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!controller.isDemo && !(_pushAvailable && _pushOn) && !emailOn)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Du bekommst zurzeit weder Push noch E-Mails. Neue Termine und Änderungen siehst du nur, wenn du die App öffnest.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            if (controller.isDemo)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'In der Demo werden deine Einstellungen nur lokal gespeichert. Es werden keine Benachrichtigungen versendet.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SectionTitle('Erinnere mich'),
            Card(
              child: Column(
                children: [
                  for (final item in const [
                    ('dayBefore', 'Am Vortag', 'Einen Tag vor einem Termin'),
                    (
                      'twoHours',
                      'Zwei Stunden vorher',
                      'Noch genug Zeit zum Losfahren',
                    ),
                    (
                      'changes',
                      'Bei Änderungen',
                      'Wenn sich ein Termin ändert',
                    ),
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: DropdownButtonFormField<int?>(
                      key: const ValueKey('custom-reminder'),
                      initialValue: controller.customReminderMinutes,
                      decoration: const InputDecoration(
                        labelText: 'Eigene Vorlaufzeit',
                        helperText:
                            'Zusätzliche Erinnerung zu einem selbst gewählten Zeitpunkt',
                        helperMaxLines: 2,
                        prefixIcon: Icon(Icons.alarm_add_outlined),
                      ),
                      items: [
                        for (final minutes in {
                          null,
                          ...reminderLeadTimes,
                          ?controller.customReminderMinutes,
                        })
                          DropdownMenuItem(
                            value: minutes,
                            child: Text(reminderLeadTimeLabel(minutes)),
                          ),
                      ],
                      onChanged: (v) => runAction(
                        context,
                        () => controller.saveCustomReminder(v),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SectionTitle('Darstellung'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Farbschema', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OneLineSegmentedButton<String>(
                        key: const ValueKey('theme-mode'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: 'system',
                            label: Text('System'),
                            icon: Icon(Icons.brightness_auto_outlined),
                          ),
                          ButtonSegment(
                            value: 'light',
                            label: Text('Hell'),
                            icon: Icon(Icons.light_mode_outlined),
                          ),
                          ButtonSegment(
                            value: 'dark',
                            label: Text('Dunkel'),
                            icon: Icon(Icons.dark_mode_outlined),
                          ),
                        ],
                        selected: {
                          controller.preferences['themeMode'] as String? ??
                              'system',
                        },
                        onSelectionChanged: (value) => runAction(
                          context,
                          () => controller.setPreference(
                            'themeMode',
                            value.single,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '„System“ folgt der Einstellung deines Geräts.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
