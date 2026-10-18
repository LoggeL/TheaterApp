import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../../../app/platform/pwa_install.dart';
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
import '../../auth/ui/account_providers_screen.dart';
import '../../auth/ui/password_screen.dart';
import '../../changelog/changelog.dart';
import '../../ensemble/ui/members_screen.dart';
import '../../feedback/feedback.dart';
import '../../galleries/ui/gallery_list_screen.dart';
import '../../games/games.dart';
import '../../participation/ui/participation_screen.dart';
import '../../profile/ui/profile_screen.dart';
import '../../settings/ui/settings_screen.dart';
import '../../sync/ui/sync_screen.dart';
import '../domain/absence_summary.dart';
import 'widgets/logout_button.dart';

class MyAreaScreen extends StatefulWidget {
  const MyAreaScreen({
    super.key,
    required this.controller,
    required this.devices,
    this.installation,
  });
  final AppController controller;
  final DeviceServices devices;

  /// Web installation state; created on demand when omitted.
  final PwaInstallation? installation;
  @override
  State<MyAreaScreen> createState() => _MyAreaScreenState();
}

class _MyAreaScreenState extends State<MyAreaScreen> {
  late final PwaInstallation _installation;

  AppController get controller => widget.controller;

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
    if (_installation.canPrompt) {
      try {
        await _installation.prompt();
      } catch (_) {
        if (mounted) {
          showDone(
            context,
            'Die Installation konnte nicht gestartet werden. Bitte nutze das Browsermenü.',
          );
        }
      }
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _installation.devicePlatform == 'ios'
          ? IosInstallSteps(embedded: _installation.embedded)
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PwaInstallCard(installation: _installation),
              ),
            ),
    );
  }

  Future<void> _privacy() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Datenschutz', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Wie die App mit deinen Daten umgeht und wie du dein Konto löschen lassen kannst.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const PrivacyLinks(showVersion: false),
          ],
        ),
      ),
    ),
  );

  void _about() => showAboutDialog(
    context: context,
    applicationName: Brand.name,
    applicationVersion: appVersionLabel,
    // Seven quick taps on the logo open a small game for the ensemble.
    applicationIcon: Builder(
      builder: (dialog) => SecretTap(
        onUnlocked: () {
          Navigator.pop(dialog);
          openStageRunner(context, controller);
        },
        child: const BrandLogo(size: 41),
      ),
    ),
    children: [
      const Text(
        'Termine, Rückmeldungen, Drehbücher und Mitteilungen des Ensembles an einem Ort. Bei Fragen zur App hilft dir die Theaterleitung weiter.',
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Builder(
          builder: (dialog) => TextButton(
            onPressed: () {
              Navigator.pop(dialog);
              openChangelog(context);
            },
            child: const Text('Was ist neu?'),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final active = controller.members.where((m) => m.active).length;
    final showPassword =
        !controller.isDemo &&
        (!controller.usesFirebase ||
            controller.identity?.linkedProviders.contains('password') == true);
    final account = [
      if (showPassword)
        GroupTile(
          icon: Icons.lock_outline,
          title: 'Passwort ändern',
          subtitle: 'Deinen Zugang schützen',
          onTap: () =>
              openPage(context, PasswordScreen(controller: controller)),
        ),
      if (controller.usesFirebase)
        GroupTile(
          icon: Icons.login_outlined,
          title: 'Anmeldearten',
          subtitle: 'Zugänge zu deinem Konto',
          onTap: () =>
              openPage(context, AccountProvidersScreen(controller: controller)),
        ),
    ];
    return RefreshIndicator(
      onRefresh: () => refreshWithFeedback(context, controller),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
        children: [
          const PageHeader('Mein Bereich.'),
          _ProfileCard(controller: controller),
          const SizedBox(height: 28),
          ListenableBuilder(
            listenable: _installation,
            builder: (context, _) => ResponsiveGroups(
              children: [
                TileGroup(
                  title: 'Für mich',
                  tiles: [
                    GroupTile(
                      icon: Icons.beach_access_outlined,
                      title: 'Abwesenheiten',
                      subtitle: absenceSummary(
                        controller.absences,
                        controller.now,
                      ),
                      onTap: () => openPage(
                        context,
                        AbsencesScreen(controller: controller),
                      ),
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
                  ],
                ),
                TileGroup(
                  title: 'Ensemble',
                  tiles: [
                    GroupTile(
                      icon: Icons.groups_outlined,
                      title: 'Unser Ensemble',
                      subtitle: active == 1
                          ? '1 aktives Mitglied'
                          : '$active aktive Mitglieder',
                      onTap: () => openPage(
                        context,
                        MembersScreen(controller: controller),
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
                  title: 'Einstellungen',
                  tiles: [
                    GroupTile(
                      icon: Icons.tune,
                      title: 'Benachrichtigungen & Darstellung',
                      subtitle: 'Push, E-Mail, Erinnerungen und Farbschema',
                      onTap: () => openPage(
                        context,
                        SettingsScreen(
                          controller: controller,
                          devices: widget.devices,
                        ),
                      ),
                    ),
                  ],
                ),
                if (account.isNotEmpty)
                  TileGroup(title: 'Konto', tiles: account),
                TileGroup(
                  title: 'App',
                  tiles: [
                    GroupTile(
                      icon: Icons.sync_outlined,
                      title: 'Synchronisierung',
                      subtitle: controller.isDemo
                          ? 'Demo · alles bleibt auf diesem Gerät'
                          : controller.isOffline
                          ? 'Offline'
                          : remainingChanges(
                                  controller.pendingCount,
                                  controller.failedCount,
                                ) ??
                                'Alles übertragen',
                      subtitleColor: controller.failedCount > 0
                          ? Theme.of(context).colorScheme.error
                          : null,
                      onTap: () =>
                          openPage(context, SyncScreen(controller: controller)),
                    ),
                    if (_installation.available && !_installation.installed)
                      GroupTile(
                        icon: Icons.install_mobile_outlined,
                        title: 'App installieren',
                        subtitle: 'Direkt über ein Symbol auf deinem Gerät',
                        onTap: _install,
                      ),
                    if (feedbackAvailable(controller))
                      GroupTile(
                        icon: Icons.feedback_outlined,
                        title: 'Feedback geben',
                        subtitle: 'Idee, Fehler oder Anregung zur App',
                        onTap: () => openPage(
                          context,
                          FeedbackFormScreen(controller: controller),
                        ),
                      ),
                    GroupTile(
                      icon: Icons.privacy_tip_outlined,
                      title: 'Datenschutz',
                      subtitle: 'Datenschutzerklärung und Kontolöschung',
                      onTap: _privacy,
                    ),
                    GroupTile(
                      icon: Icons.info_outline,
                      title: 'Über die App',
                      subtitle: '$appVersionLabel · Lizenzen',
                      onTap: _about,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          LogoutButton(controller: controller),
          const SizedBox(height: 25),
          const Center(
            child: VersionLink(
              label: '${Brand.name} · $appVersionLabel\n${Brand.subtitle}',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// The member's card. The whole card is one button that opens the profile.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final user = controller.user;
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: MergeSemantics(
        child: InkWell(
          onTap: () => openPage(context, ProfileScreen(controller: controller)),
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
                                  : Brand.organization),
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
                      const SizedBox(height: 10),
                      Text(
                        'Profil bearbeiten',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
