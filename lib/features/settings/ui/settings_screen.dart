import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../../../core/app_controller.dart';
import '../../../core/device_services.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/widgets/page_header.dart';
import '../domain/reminder_lead_times.dart';

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
        padding: pagePadding(context),
        children: [
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
          const SectionTitle('E-Mail'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
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
                  TextButton.icon(
                    icon: const Icon(Icons.mail_outline),
                    label: const Text('Test-E-Mail an mich senden'),
                    onPressed: () => runAction(
                      context,
                      () => controller.performAction({'action': 'email.test'}),
                      message: 'Test-E-Mail angefordert.',
                    ),
                  ),
              ],
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                  child: DropdownButtonFormField<int?>(
                    key: const ValueKey('custom-reminder'),
                    initialValue: controller.customReminderMinutes,
                    decoration: const InputDecoration(
                      labelText: 'Eigene Vorlaufzeit',
                      helperText:
                          'Zusätzlich zu einem selbst gewählten Zeitpunkt',
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
