import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../shared/feedback.dart';
import '../data/website_profiles.dart';
import '../domain/website_profile.dart';

/// Admin tile in the person editor: which public website profile belongs to
/// this person. The import links clear matches itself; doubtful ones and
/// corrections are set here and kept by later imports.
class WebsiteProfileLink extends StatefulWidget {
  const WebsiteProfileLink({
    super.key,
    required this.controller,
    required this.personId,
  });
  final AppController controller;
  final int personId;
  @override
  State<WebsiteProfileLink> createState() => _WebsiteProfileLinkState();
}

class _WebsiteProfileLinkState extends State<WebsiteProfileLink> {
  late Future<List<WebsiteProfile>> _profiles;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _profiles = WebsiteProfiles.load(widget.controller);
  }

  Future<void> _choose(List<WebsiteProfile> profiles) async {
    final current = profiles
        .where((p) => p.personId == widget.personId)
        .firstOrNull;
    final free = profiles
        .where((p) => p.personId == null || p.personId == widget.personId)
        .toList();
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Website-Profil zuordnen'),
        children: [
          SimpleDialogOption(
            key: const ValueKey('website-link-none'),
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Kein Website-Profil'),
          ),
          for (final profile in free)
            SimpleDialogOption(
              key: ValueKey('website-link-${profile.slug}'),
              onPressed: () => Navigator.pop(context, profile.slug),
              child: Text(
                profile.slug == profile.name
                    ? profile.name
                    : '${profile.name} (${profile.slug})',
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == (current?.slug ?? '')) return;
    setState(() => _busy = true);
    try {
      Map<String, dynamic>? result;
      // A person has at most one website profile: unlink the old one first.
      if (current != null) {
        result = await widget.controller.remote(
          '/ensemble/website-profiles/${Uri.encodeComponent(current.slug)}',
          method: 'PUT',
          body: {'personId': null},
        );
      }
      if (picked.isNotEmpty) {
        result = await widget.controller.remote(
          '/ensemble/website-profiles/${Uri.encodeComponent(picked)}',
          method: 'PUT',
          body: {'personId': widget.personId},
        );
      }
      if (!mounted || result == null) return;
      final next = WebsiteProfiles.store(widget.controller, result);
      setState(() => _profiles = Future.value(next));
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!WebsiteProfiles.available(widget.controller)) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<List<WebsiteProfile>>(
      future: _profiles,
      builder: (context, state) {
        final profiles = state.data ?? const <WebsiteProfile>[];
        if (state.connectionState == ConnectionState.done &&
            !state.hasError &&
            profiles.isEmpty) {
          return const SizedBox.shrink();
        }
        final linked = profiles
            .where((p) => p.personId == widget.personId)
            .firstOrNull;
        return ListTile(
          key: const ValueKey('member-editor-website'),
          leading: const Icon(Icons.public),
          title: const Text('Website-Profil'),
          subtitle: Text(
            state.hasError
                ? 'Gerade nicht erreichbar'
                : !state.hasData
                ? 'Wird geladen …'
                : linked == null
                ? 'Nicht zugeordnet'
                : '${linked.name} · ${linked.personLink == 'manual' ? 'von Hand zugeordnet' : 'automatisch zugeordnet'}'
                      '${linked.hidden ? ' · von der Person ausgeblendet' : ''}',
          ),
          trailing: const Icon(Icons.chevron_right),
          enabled: !_busy && state.hasData,
          onTap: () => _choose(profiles),
        );
      },
    );
  }
}
