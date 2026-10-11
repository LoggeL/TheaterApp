import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../../../app/platform/pwa_install_card.dart';
import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/app_version.dart';
import '../../../core/device_services.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/brand_logo.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/privacy_links.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../../shared/widgets/tile_group.dart';
import '../../absences/ui/absences_screen.dart';
import '../../admin/ui/management_screen.dart';
import '../../auth/ui/account_providers_screen.dart';
import '../../auth/ui/password_screen.dart';
import '../../ensemble/ui/members_screen.dart';
import '../../galleries/ui/gallery_list_screen.dart';
import '../../participation/ui/participation_screen.dart';
import '../../polls/ui/polls_screen.dart';
import '../../profile/ui/profile_screen.dart';
import '../../settings/ui/settings_screen.dart';
import '../../slots/domain/slot_pool.dart';
import '../../slots/ui/slot_pools_screen.dart';
import '../../sync/ui/sync_screen.dart';

class MyAreaScreen extends StatelessWidget {
  const MyAreaScreen({
    super.key,
    required this.controller,
    required this.devices,
  });
  final AppController controller;
  final DeviceServices devices;
  @override
  Widget build(BuildContext context) {
    final user = controller.user;
    final theme = Theme.of(context);
    final waiting = slotPoolsAwaitingChoice(controller);
    final active = controller.members.where((m) => m.active).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
      children: [
        const PageHeader('Mein Bereich.'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () =>
                openPage(context, ProfileScreen(controller: controller)),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary.withValues(alpha: .09),
                    theme.colorScheme.secondary.withValues(alpha: .05),
                  ],
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  MemberAvatar(
                    controller: controller,
                    avatarId: user?.avatarId,
                    initials: user?.initials ?? 'KR',
                    radius: 30,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.name ?? 'Ensemble',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          controller.isDemo
                              ? 'Demokonto · Beispieldaten'
                              : (user?.roleIds.isNotEmpty == true
                                    ? controller.roleNames(user!.roleIds)
                                    : 'Kolpingtheater Ramsen'),
                          style: theme.textTheme.bodySmall,
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
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Profil bearbeiten',
                    onPressed: () => openPage(
                      context,
                      ProfileScreen(controller: controller),
                    ),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        ResponsiveGroups(
          children: [
            TileGroup(
              title: 'Im Theater',
              tiles: [
                GroupTile(
                  icon: Icons.poll_outlined,
                  title: 'Abstimmungen',
                  subtitle: 'Mitreden und abstimmen',
                  onTap: () =>
                      openPage(context, PollsScreen(controller: controller)),
                ),
                if (controller.slotPools.isNotEmpty || user?.isAdmin == true)
                  GroupTile(
                    icon: Icons.edit_calendar_outlined,
                    title: 'Terminfinder',
                    subtitle: waiting == 0
                        ? 'Zeitfenster buchen, z. B. für Fototermine'
                        : waiting == 1
                        ? '1 wartet auf deine Auswahl'
                        : '$waiting warten auf deine Auswahl',
                    subtitleColor: waiting == 0
                        ? null
                        : theme.colorScheme.primary,
                    onTap: () => openPage(
                      context,
                      SlotPoolsScreen(controller: controller),
                    ),
                  ),
                GroupTile(
                  icon: Icons.photo_library_outlined,
                  title: 'Galerien',
                  subtitle: 'Unsere Stücke in Bildern',
                  onTap: () => openPage(
                    context,
                    GalleryListScreen(controller: controller),
                  ),
                ),
              ],
            ),
            TileGroup(
              title: 'Ich & das Ensemble',
              tiles: [
                GroupTile(
                  icon: Icons.beach_access_outlined,
                  title: 'Abwesenheiten',
                  subtitle: controller.absences.length == 1
                      ? '1 Zeitraum gemeldet'
                      : '${controller.absences.length} Zeiträume gemeldet',
                  onTap: () =>
                      openPage(context, AbsencesScreen(controller: controller)),
                ),
                if (!controller.isDemo)
                  GroupTile(
                    icon: Icons.event_available_outlined,
                    title: 'Meine Teilnahme',
                    subtitle: 'Rückmeldungen und Anwesenheit',
                    onTap: () => openPage(
                      context,
                      ParticipationScreen(controller: controller),
                    ),
                  ),
                GroupTile(
                  icon: Icons.groups_outlined,
                  title: 'Unser Ensemble',
                  subtitle: '$active aktive Mitglieder',
                  onTap: () =>
                      openPage(context, MembersScreen(controller: controller)),
                ),
              ],
            ),
            TileGroup(
              title: 'Einstellungen & Konto',
              tiles: [
                GroupTile(
                  icon: Icons.tune,
                  title: 'Darstellung & Erinnerungen',
                  subtitle: 'Design, Push und Benachrichtigungen',
                  onTap: () => openPage(
                    context,
                    SettingsScreen(controller: controller, devices: devices),
                  ),
                ),
                GroupTile(
                  icon: Icons.sync_outlined,
                  title: 'Synchronisierung',
                  subtitle: controller.isDemo
                      ? 'Demo · alles bleibt auf diesem Gerät'
                      : controller.pendingCount + controller.failedCount == 0
                      ? 'Alles übertragen'
                      : '${controller.pendingCount} ausstehend · ${controller.failedCount} zu prüfen',
                  onTap: () =>
                      openPage(context, SyncScreen(controller: controller)),
                ),
                if (!controller.isDemo &&
                    (!controller.usesFirebase ||
                        controller.identity!.linkedProviders.contains(
                          'password',
                        )))
                  GroupTile(
                    icon: Icons.lock_outline,
                    title: 'Passwort ändern',
                    subtitle: 'Deinen Zugang schützen',
                    onTap: () => openPage(
                      context,
                      PasswordScreen(controller: controller),
                    ),
                  ),
                if (controller.usesFirebase)
                  GroupTile(
                    icon: Icons.login_outlined,
                    title: 'Anmeldearten',
                    subtitle: 'Zugänge zu deinem Konto',
                    onTap: () => openPage(
                      context,
                      AccountProvidersScreen(controller: controller),
                    ),
                  ),
                if (user?.isAdmin == true && !controller.isDemo)
                  GroupTile(
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Administration',
                    subtitle: 'Konten, Termine, Ensemble und Besetzung',
                    onTap: () => openPage(
                      context,
                      ManagementScreen(controller: controller),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const PrivacyLinks(showVersion: false),
        const PwaInstallCard(),
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
          '${Brand.name} · $appVersionLabel\n${Brand.subtitle}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => showAboutDialog(
            context: context,
            applicationName: Brand.name,
            applicationVersion: appVersionLabel,
            applicationIcon: const BrandLogo(size: 41),
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
