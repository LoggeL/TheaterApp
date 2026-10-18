import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/protected_image.dart';
import '../../casting/ui/casting_screen.dart';
import '../../profile/ui/profile_screen.dart';
import '../data/website_profiles.dart';
import '../domain/website_profile.dart';

/// A short "about" page of one person: photo, roles in the ensemble, a
/// self-written text and what they played, from the app and the public
/// website. Shows no contact data, responses or attendance.
class MemberProfileScreen extends StatefulWidget {
  const MemberProfileScreen({
    super.key,
    required this.controller,
    required this.personId,
  });
  final AppController controller;
  final int personId;
  @override
  State<MemberProfileScreen> createState() => _MemberProfileScreenState();
}

class _MemberProfileScreenState extends State<MemberProfileScreen> {
  late Future<List<WebsiteProfile>> _profiles;

  @override
  void initState() {
    super.initState();
    _profiles = WebsiteProfiles.load(widget.controller);
  }

  Future<void> _refresh() async {
    final next = WebsiteProfiles.load(widget.controller, refresh: true);
    setState(() => _profiles = next);
    await next.catchError((Object _) => const <WebsiteProfile>[]);
  }

  bool get _own => widget.controller.user?.personId == widget.personId;

  Future<void> _editOwn() =>
      openPage(context, ProfileScreen(controller: widget.controller));

  @override
  Widget build(BuildContext context) {
    final member = widget.controller.members
        .where((m) => m.id == widget.personId)
        .firstOrNull;
    if (member == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profil')),
        body: const EmptyState(
          icon: Icons.person_off_outlined,
          title: 'Person nicht gefunden',
          message: 'Diese Person gehört nicht mehr zum Ensemble.',
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(member.name),
        actions: [
          if (_own)
            IconButton(
              tooltip: 'Profil bearbeiten',
              onPressed: _editOwn,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      body: FutureBuilder<List<WebsiteProfile>>(
        future: _profiles,
        builder: (context, state) {
          final profiles =
              state.data ?? WebsiteProfiles.peek(widget.controller) ?? const [];
          final website = member.websiteHidden
              ? null
              : websiteProfileOf(profiles, member.id);
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: pagePadding(context),
              children: [
                _header(context, member, website),
                ..._about(context, member),
                ..._credits(context, member, website),
                ..._jobs(context, website),
                if (state.hasError && profiles.isEmpty)
                  _note(
                    context,
                    'Die Angaben der Website sind gerade nicht erreichbar. '
                    'Zum erneuten Laden nach unten ziehen.',
                  ),
                if (website != null) _source(context, website),
                if (_own && member.websiteHidden)
                  _note(
                    context,
                    'Du hast die Angaben der Website in deinem Profil '
                    'ausgeblendet.',
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(
    BuildContext context,
    TheaterMember member,
    WebsiteProfile? website,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final photoId = website?.photoId;
    final Widget picture;
    if (member.avatarId == null && photoId != null) {
      // Website portraits are 3:4; show them like on the website.
      picture = ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 168,
          height: 224,
          child: ProtectedImage(
            key: const ValueKey('profile-website-photo'),
            controller: widget.controller,
            path: '/media/$photoId',
            alignment: Alignment.topCenter,
            decodeWidth: 480,
            fallback: _initials(context, member),
          ),
        ),
      );
    } else {
      picture = MemberAvatar(
        controller: widget.controller,
        avatarId: member.avatarId,
        initials: member.initials.isEmpty
            ? _initialsOf(member.name)
            : member.initials,
        radius: 56,
      );
    }
    final current = website?.current;
    final count = mergeProfileCredits(
      personId: member.id,
      productionRecords: widget.controller.productionRecords,
      website: website,
    ).length;
    final roles = widget.controller.roleNames(member.roleIds);
    return Column(
      children: [
        const SizedBox(height: 8),
        Center(child: picture),
        const SizedBox(height: 18),
        Text(
          member.name,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        if (roles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              roles,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        if (!member.active)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Nicht aktiv',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        if (current != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              children: [
                Eyebrow(
                  current.year == null
                      ? 'Diese Saison'
                      : 'Diese Saison · ${current.year}',
                ),
                const SizedBox(height: 4),
                Text(
                  current.role,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  [current.title, ?current.location].join(' · '),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        if (count > 0 || website?.since != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (count > 0)
                  Chip(
                    avatar: const Icon(Icons.theater_comedy_outlined, size: 18),
                    label: Text(
                      count == 1 ? '1 Produktion' : '$count Produktionen',
                    ),
                  ),
                if (website?.since != null)
                  Chip(
                    avatar: const Icon(Icons.event_outlined, size: 18),
                    label: Text('Dabei seit ${website!.since}'),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _initials(BuildContext context, TheaterMember member) => ColoredBox(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Center(
      child: Text(
        member.initials.isEmpty ? _initialsOf(member.name) : member.initials,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      ),
    ),
  );

  List<Widget> _about(BuildContext context, TheaterMember member) {
    final text = member.about.trim();
    if (text.isEmpty && !_own) return const [];
    return [
      const SectionTitle('Über mich'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: text.isNotEmpty
              ? SelectableText(
                  text,
                  style: Theme.of(context).textTheme.bodyLarge,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Noch kein Text. Erzähl dem Ensemble in ein paar Sätzen, '
                      'wer du bist und was du am Theater magst.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _editOwn,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Text schreiben'),
                    ),
                  ],
                ),
        ),
      ),
    ];
  }

  List<Widget> _credits(
    BuildContext context,
    TheaterMember member,
    WebsiteProfile? website,
  ) {
    final credits = mergeProfileCredits(
      personId: member.id,
      productionRecords: widget.controller.productionRecords,
      website: website,
    );
    final known = widget.controller.productions.map((p) => p.id).toSet();
    return [
      const SectionTitle('Rollen und Mitwirkung'),
      if (credits.isEmpty)
        Text(
          'Noch keine Rollen eingetragen.',
          style: Theme.of(context).textTheme.bodyMedium,
        )
      else
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, credit) in credits.indexed) ...[
                if (i > 0) const Divider(height: 1),
                _credit(context, credit, known),
              ],
            ],
          ),
        ),
    ];
  }

  Widget _credit(
    BuildContext context,
    ProfileCredit credit,
    Set<String> known,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final productionId = credit.productionId;
    final opens = productionId != null && known.contains(productionId);
    return ListTile(
      key: ValueKey('profile-credit-${credit.title}'),
      leading: SizedBox(
        width: 48,
        child: Text(
          credit.year?.toString() ?? 'Neu',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(color: scheme.primary),
        ),
      ),
      title: Text(credit.title),
      subtitle: Text(
        [
          credit.duties.join(' · '),
          if (credit.location != null) credit.location!,
        ].join('\n'),
      ),
      isThreeLine: credit.location != null,
      trailing: opens ? const Icon(Icons.chevron_right) : null,
      onTap: opens
          ? () => openPage(
              context,
              CastingScreen(
                controller: widget.controller,
                productionId: productionId,
              ),
            )
          : null,
    );
  }

  List<Widget> _jobs(BuildContext context, WebsiteProfile? website) {
    final jobs = website?.jobs ?? const <WebsiteJob>[];
    if (jobs.isEmpty) return const [];
    return [
      const SectionTitle('Hinter den Kulissen'),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final (i, job) in jobs.indexed) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.handyman_outlined),
                title: Text(job.job),
                subtitle: job.description.isEmpty
                    ? null
                    : Text(job.description),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _source(BuildContext context, WebsiteProfile website) {
    final uri = website.url == null ? null : Uri.tryParse(website.url!);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Foto, Rollen und Aufgaben stammen von der öffentlichen Website '
            'kolpingtheater-ramsen.de.${_own ? ' Du kannst sie unter „Profil bearbeiten“ in der App ausblenden.' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (uri != null)
            TextButton.icon(
              onPressed: () async {
                final opened = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
                if (!opened && context.mounted) {
                  showProblem(
                    context,
                    'Der Link konnte nicht geöffnet werden.',
                  );
                }
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('Profil auf der Website'),
            ),
        ],
      ),
    );
  }

  Widget _note(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

String _initialsOf(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((e) => e.isNotEmpty)
    .take(2)
    .map((e) => e[0])
    .join()
    .toUpperCase();
