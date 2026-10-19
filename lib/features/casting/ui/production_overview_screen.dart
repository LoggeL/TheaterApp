import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../ensemble/ui/member_profile_screen.dart';
import '../../galleries/ui/gallery_screen.dart';
import '../../scripts/ui/line_learning_screen.dart';
import '../../scripts/ui/script_reader_screen.dart';
import '../domain/casting.dart';
import 'casting_screen.dart';

/// Read-only page of one production for everyone in the ensemble: title,
/// premiere, who plays which role, direction and team, with links to the
/// people's profiles, the script and the production's photo albums.
/// Archived productions open as well. Admins can switch to the editor.
class ProductionOverviewScreen extends StatefulWidget {
  const ProductionOverviewScreen({
    super.key,
    required this.controller,
    required this.productionId,
  });
  final AppController controller;
  final String productionId;
  @override
  State<ProductionOverviewScreen> createState() =>
      _ProductionOverviewScreenState();
}

class _ProductionOverviewScreenState extends State<ProductionOverviewScreen> {
  // Albums linked to this production; null in the demo or without access.
  Future<List<JsonMap>>? _galleries;

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    if (!_controller.isDemo && _controller.hasAccess) {
      _galleries = _controller
          .remote('/galleries')
          .then(
            (data) => jsonList(data['galleries'])
                .map(jsonMap)
                .where((g) => g['productionId'] == widget.productionId)
                .toList(),
          );
    }
  }

  JsonMap? get _record => _controller.productionRecords
      .where((p) => p['id'] == widget.productionId)
      .firstOrNull;

  TheaterMember? _member(int? id) =>
      _controller.members.where((m) => m.id == id).firstOrNull;

  String _name(int id) => _member(id)?.name ?? 'Unbekannte Person';

  Widget _avatar(int id) {
    final member = _member(id);
    return MemberAvatar(
      controller: _controller,
      avatarId: member?.avatarId,
      initials: member?.initials.isNotEmpty == true
          ? member!.initials
          : (member?.name.isNotEmpty == true ? member!.name[0] : '?'),
      radius: 20,
    );
  }

  void _openProfile(int id) => openPage(
    context,
    MemberProfileScreen(controller: _controller, personId: id),
  );

  void _openScript() => openPage(
    context,
    ScriptReaderScreen(
      controller: _controller,
      productionId: widget.productionId,
    ),
  );

  void _openLearning() => openPage(
    context,
    LineLearningScreen(
      controller: _controller,
      productionId: widget.productionId,
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final record = _record;
      final admin = _controller.user?.isAdmin == true;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Produktion'),
          actions: [
            if (admin && record != null)
              IconButton(
                key: const ValueKey('production-overview-edit'),
                tooltip: 'Besetzung bearbeiten',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => openPage(
                  context,
                  CastingScreen(
                    controller: _controller,
                    productionId: widget.productionId,
                  ),
                ),
              ),
          ],
        ),
        body: record == null
            ? const Center(
                child: SingleChildScrollView(
                  child: EmptyState(
                    icon: Icons.theater_comedy_outlined,
                    title: 'Produktion nicht verfügbar',
                    message: 'Diese Produktion gibt es nicht mehr.',
                  ),
                ),
              )
            : _content(context, record),
      );
    },
  );

  Widget _content(BuildContext context, JsonMap record) {
    final cast = ProductionCast.fromRecord(record);
    final production = Production.fromJson(record);
    final me = _controller.user?.personId;
    final roles = rolesByImportance(
      cast.roles,
      roleLineCounts(_controller.scripts[cast.id]),
    );
    final hasScript =
        production.revision.isNotEmpty ||
        production.roles.isNotEmpty ||
        _controller.scripts.containsKey(cast.id);
    final nobody =
        cast.roles.isEmpty && cast.directors.isEmpty && cast.team.isEmpty;
    return RefreshIndicator(
      onRefresh: () => refreshWithFeedback(context, _controller),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: pagePadding(context, top: 8),
        children: [
          _header(context, production, cast),
          if (me != null && cast.dutiesOf(me).isNotEmpty)
            _mine(context, cast, me, hasScript),
          if (nobody)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                'Für diese Produktion ist noch niemand eingetragen.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (roles.isNotEmpty) ...[
            const SectionTitle('Besetzung'),
            _group([for (final role in roles) _roleTile(context, cast, role)]),
          ],
          if (cast.directors.isNotEmpty) ...[
            const SectionTitle('Regie'),
            _group([
              for (final id in cast.directors)
                _personTile(
                  context,
                  key: ValueKey('production-overview-director-$id'),
                  personId: id,
                  subtitle: 'Regie',
                ),
            ]),
          ],
          if (cast.team.isNotEmpty) ...[
            const SectionTitle('Team'),
            _group([
              for (final id in cast.team)
                _personTile(
                  context,
                  key: ValueKey('production-overview-team-$id'),
                  personId: id,
                  subtitle: cast.functions[id] ?? 'Team',
                ),
            ]),
          ],
          ..._links(context, hasScript),
        ],
      ),
    );
  }

  Widget _header(
    BuildContext context,
    Production production,
    ProductionCast cast,
  ) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final premiere = production.premiereAt;
    final open = cast.roles.length - cast.castCount;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Eyebrow(production.archived ? 'Archiv' : 'Produktion'),
            const SizedBox(height: 8),
            Text(
              production.title,
              key: const ValueKey('production-overview-title'),
              style: theme.textTheme.headlineSmall,
            ),
            if (production.subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(production.subtitle, style: theme.textTheme.bodyLarge),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (premiere != null)
                  StatePill(
                    'Premiere: ${DateFormat('d. MMMM y', 'de').format(premiere.toLocal())}',
                    key: const ValueKey('production-overview-premiere'),
                    color: scheme.primary,
                    icon: Icons.celebration_outlined,
                  ),
                if (cast.roles.isNotEmpty)
                  StatePill(
                    cast.roles.length == 1
                        ? '1 Rolle'
                        : '${cast.roles.length} Rollen',
                    color: scheme.secondary,
                    icon: Icons.theater_comedy_outlined,
                  ),
                if (open > 0)
                  StatePill(
                    open == 1 ? '1 noch offen' : '$open noch offen',
                    color: scheme.onSurfaceVariant,
                    icon: Icons.person_search_outlined,
                  ),
                if (production.archived)
                  StatePill(
                    'Archiviert',
                    color: scheme.onSurfaceVariant,
                    icon: Icons.inventory_2_outlined,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// What the signed-in person does here, with the way to the script.
  Widget _mine(
    BuildContext context,
    ProductionCast cast,
    int me,
    bool hasScript,
  ) {
    final theme = Theme.of(context);
    final roles = cast.rolesOf(me).map((r) => r.name).toList();
    final other = cast.dutiesOf(me).skip(roles.length).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        key: const ValueKey('production-overview-mine'),
        color: StageTheme.selectedTint(theme.brightness),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Eyebrow('Du bist dabei'),
              const SizedBox(height: 8),
              Text(switch (roles.length) {
                0 => 'Deine Aufgabe: ${other.join(' · ')}',
                1 => 'Deine Rolle: ${roles.single}',
                _ => 'Deine Rollen: ${roles.join(', ')}',
              }, style: theme.textTheme.titleMedium),
              if (roles.isNotEmpty && other.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(other.join(' · '), style: theme.textTheme.bodyMedium),
              ],
              if (roles.isNotEmpty && hasScript) ...[
                const SizedBox(height: 6),
                Text(
                  'Lerne deinen Text mit Karteikarten oder lies im Drehbuch.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('production-overview-learn'),
                      onPressed: _openLearning,
                      icon: const Icon(Icons.record_voice_over_outlined),
                      label: const Text('Text lernen'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('production-overview-open-script'),
                      onPressed: _openScript,
                      icon: const Icon(Icons.menu_book_outlined),
                      label: const Text('Drehbuch öffnen'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _roleTile(BuildContext context, ProductionCast cast, ScriptRole role) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final personId = cast.personFor(role.id);
    final known = personId != null && _member(personId) != null;
    final mine = personId != null && personId == _controller.user?.personId;
    // A person with several roles (e.g. a double role) names the others.
    final also = personId == null
        ? const <String>[]
        : cast
              .rolesOf(personId)
              .where((r) => r.id != role.id)
              .map((r) => r.name)
              .toList();
    return ListTile(
      key: ValueKey('production-overview-role-${role.id}'),
      leading: personId == null
          ? CircleAvatar(
              backgroundColor: scheme.surfaceContainerHighest,
              child: Icon(Icons.person_outline, color: scheme.onSurfaceVariant),
            )
          : _avatar(personId),
      title: Text(
        role.name.isEmpty ? role.id : role.name,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            personId == null
                ? 'Noch nicht besetzt'
                : mine
                ? '${_name(personId)} (du)'
                : _name(personId),
            style: personId == null
                ? TextStyle(color: scheme.onSurfaceVariant)
                : null,
          ),
          if (also.isNotEmpty)
            Text(
              'Spielt auch: ${also.join(', ')}',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      trailing: known ? const Icon(Icons.chevron_right) : null,
      onTap: known ? () => _openProfile(personId) : null,
    );
  }

  Widget _personTile(
    BuildContext context, {
    required Key key,
    required int personId,
    required String subtitle,
  }) {
    final known = _member(personId) != null;
    final mine = personId == _controller.user?.personId;
    return ListTile(
      key: key,
      leading: _avatar(personId),
      title: Text(mine ? '${_name(personId)} (du)' : _name(personId)),
      subtitle: Text(subtitle),
      trailing: known ? const Icon(Icons.chevron_right) : null,
      onTap: known ? () => _openProfile(personId) : null,
    );
  }

  Widget _group(List<Widget> tiles) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (final (i, tile) in tiles.indexed) ...[
          if (i > 0) const Divider(height: 1, indent: 72),
          tile,
        ],
      ],
    ),
  );

  /// The script and photo albums, when there are any.
  List<Widget> _links(BuildContext context, bool hasScript) {
    final script = hasScript
        ? ListTile(
            key: const ValueKey('production-overview-script'),
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('Drehbuch'),
            subtitle: Text(
              _controller.scripts.containsKey(widget.productionId)
                  ? 'Lesen und Text lernen · offline verfügbar'
                  : 'Lesen und Text lernen',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openScript,
          )
        : null;
    return [
      FutureBuilder<List<JsonMap>>(
        future: _galleries,
        builder: (context, state) {
          // Albums are optional here: a failed request just leaves them out.
          final galleries = state.data ?? const <JsonMap>[];
          final tiles = [
            ?script,
            for (final gallery in galleries)
              ListTile(
                key: ValueKey('production-overview-gallery-${gallery['id']}'),
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(textValue(gallery['title'])),
                subtitle: Text(switch (intValue(gallery['count'])) {
                  1 => 'Galerie · 1 Aufnahme',
                  final count => 'Galerie · $count Aufnahmen',
                }),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openPage(
                  context,
                  GalleryScreen(controller: _controller, gallery: gallery),
                ),
              ),
          ];
          if (tiles.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [const SectionTitle('Mehr dazu'), _group(tiles)],
          );
        },
      ),
    ];
  }
}
