import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../casting/domain/casting.dart';
import '../../casting/ui/casting_screen.dart';
import '../domain/ensemble_membership.dart';

/// "Ensembles & Verteiler": who belongs to which production's ensemble and
/// why. People added by hand ("weitere Mitwirkende") are added and removed
/// here; cast people and directors are shown with their reason and change
/// under "Besetzung & Team". Both edit the same production record through
/// `production.cast`, so there is no second list to keep in sync.
class EnsemblesAdminScreen extends StatefulWidget {
  const EnsemblesAdminScreen({
    super.key,
    required this.controller,
    this.productionId,
  });
  final AppController controller;

  /// The production shown first; the newest active one when not set.
  final String? productionId;
  @override
  State<EnsemblesAdminScreen> createState() => _EnsemblesAdminScreenState();
}

class _EnsemblesAdminScreenState extends State<EnsemblesAdminScreen> {
  late String? _selected = widget.productionId;
  int _pending = 0;

  AppController get _controller => widget.controller;

  /// Active productions, newest first, plus the chosen one when archived.
  List<JsonMap> get _choices => _controller.productionRecords
      .where((p) => p['archived'] != true || p['id'] == _selected)
      .toList();

  JsonMap? get _record {
    final choices = _choices;
    return choices.where((p) => p['id'] == _selected).firstOrNull ??
        choices.firstOrNull;
  }

  TheaterMember? _member(int id) =>
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

  /// Sends [changes]; the confirmation comes from [done] with the server's
  /// reply, [undo] reverts them from the SnackBar.
  Future<void> _apply(
    String productionId,
    List<JsonMap> changes, {
    required String Function(JsonMap? data) done,
    required String queued,
    List<JsonMap>? undo,
  }) async {
    setState(() => _pending++);
    try {
      final result = await _controller.performActionWithResult({
        'action': 'production.cast',
        'id': productionId,
        'changes': changes,
      });
      if (!mounted) return;
      showDone(
        context,
        outcomeText(result.outcome, done: done(result.data), queued: queued),
        actionLabel: undo == null ? null : 'Rückgängig',
        onAction: undo == null
            ? null
            : () => _apply(
                productionId,
                undo,
                done: (_) => 'Rückgängig gemacht.',
                queued: 'Rückgängig vorgemerkt – wird bei Verbindung gesendet.',
              ),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _pending--);
    }
  }

  Future<void> _add(ProductionCast cast) async {
    final personId = await _pickPerson(cast);
    if (personId == null || !mounted) return;
    final name = _name(personId);
    await _apply(
      cast.id,
      [
        // The server tells the person once if events now apply to them.
        {'kind': 'member', 'personId': personId, 'on': true, 'notify': true},
      ],
      done: (data) {
        final count = intValue(jsonMap(data?['newEvents'])['$personId']);
        final notified = jsonList(
          data?['notified'],
        ).map(intValue).contains(personId);
        if (count == 0) return '$name gehört jetzt zum Ensemble.';
        return '$name gehört jetzt zum Ensemble. '
            '${count == 1 ? '1 kommender Termin gilt' : '$count kommende Termine gelten'} '
            'jetzt auch für $name'
            '${notified ? ' – eine kurze Push-Info ist unterwegs' : ''}.';
      },
      queued: '$name vorgemerkt – wird bei Verbindung gesendet.',
      undo: [
        {'kind': 'member', 'personId': personId, 'on': false},
      ],
    );
  }

  Future<void> _remove(ProductionCast cast, EnsembleMembership m) async {
    final name = _name(m.personId);
    await _apply(
      cast.id,
      [
        {'kind': 'member', 'personId': m.personId, 'on': false},
      ],
      done: (_) => m.viaCasting
          ? '$name ist nicht mehr unter „Weitere Mitwirkende“, bleibt aber '
                'über ${m.castingReasons.join(' und ')} im Ensemble.'
          : '$name gehört nicht mehr zum Ensemble und sieht Termine nur '
                'fürs Ensemble nicht mehr.',
      queued: 'Änderung vorgemerkt – wird bei Verbindung gesendet.',
      // Undo restores the function, but never notifies again.
      undo: [
        {
          'kind': 'member',
          'personId': m.personId,
          'on': true,
          if (m.function != null) 'function': m.function,
        },
      ],
    );
  }

  Future<void> _openCasting(String productionId) => openPage(
    context,
    CastingScreen(controller: _controller, productionId: productionId),
  );

  /// Cast people and directors leave the ensemble only through casting.
  Future<void> _explain(ProductionCast cast, EnsembleMembership m) async {
    final name = _name(m.personId);
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$name gehört über die Besetzung dazu'),
        content: Text(
          'Grund: ${m.castingReasons.join(', ')}.\n\n'
          'Wer eine Rolle spielt oder Regie führt, gehört automatisch zum '
          'Ensemble und lässt sich hier nicht entfernen. Dafür unter '
          '„Besetzung & Team“ die Rolle anders besetzen oder die Regie '
          'ändern.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Schließen'),
          ),
          FilledButton(
            key: const ValueKey('ensemble-open-casting'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Zur Besetzung'),
          ),
        ],
      ),
    );
    if (open == true && mounted) await _openCasting(cast.id);
  }

  /// Active people not yet in [cast]'s ensemble, searchable by name and role.
  Future<int?> _pickPerson(ProductionCast cast) {
    var query = '';
    final ensemble = cast.ensemble;
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final needle = normalizeName(query);
          final people =
              _controller.members
                  .where(
                    (m) =>
                        m.active &&
                        !ensemble.contains(m.id) &&
                        normalizeName(
                          '${m.name} ${_controller.roleNames(m.roleIds)}',
                        ).contains(needle),
                  )
                  .toList()
                ..sort(
                  (a, b) =>
                      normalizeName(a.name).compareTo(normalizeName(b.name)),
                );
          final keyboard = MediaQuery.viewInsetsOf(context).bottom;
          return Padding(
            padding: EdgeInsets.only(bottom: keyboard),
            child: SafeArea(
              child: SizedBox(
                height: (MediaQuery.sizeOf(context).height * .8 - keyboard)
                    .clamp(220.0, double.infinity),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: Text(
                        'Zum Ensemble von „${cast.title}“',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: Text(
                        'Als weitere Mitwirkende, z. B. Technik, Maske oder '
                        'Springer.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: TextField(
                        key: const ValueKey('ensemble-person-search'),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Person suchen',
                        ),
                        onChanged: (v) => setSheetState(() => query = v),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final m in people)
                            ListTile(
                              key: ValueKey('ensemble-pick-${m.id}'),
                              leading: _avatar(m.id),
                              title: Text(m.name),
                              subtitle: m.roleIds.isEmpty
                                  ? null
                                  : Text(_controller.roleNames(m.roleIds)),
                              onTap: () => Navigator.pop(context, m.id),
                            ),
                          if (people.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'Keine passende Person, die noch nicht zum '
                                'Ensemble gehört.',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: _controller,
    title: 'Ensembles & Verteiler',
    children: (context) {
      final record = _record;
      if (record == null) {
        return const [
          Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'Noch keine aktive Produktion. Lege unter „Produktionen & '
              'Besetzung“ eine an.',
            ),
          ),
        ];
      }
      final cast = ProductionCast.fromRecord(record);
      final memberships = ensembleMemberships(cast)
        ..sort(
          (a, b) => normalizeName(
            _name(a.personId),
          ).compareTo(normalizeName(_name(b.personId))),
        );
      final byHand = memberships.where((m) => m.byHand).toList();
      final viaCasting = memberships.where((m) => !m.byHand).toList();
      final choices = _choices;
      return [
        if (_pending > 0) const LinearProgressIndicator(minHeight: 3),
        if (choices.length > 1) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in choices)
                ChoiceChip(
                  key: ValueKey('ensemble-production-${p['id']}'),
                  label: Text(
                    '${textValue(p['title'])} '
                    '(${ProductionCast.fromRecord(p).ensemble.length})',
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: p['id'] == cast.id,
                  onSelected: (_) =>
                      setState(() => _selected = textValue(p['id'])),
                ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        _summary(context, cast),
        SectionTitle('Weitere Mitwirkende (${byHand.length})'),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Von Hand hinzugefügt, ohne Rolle im Drehbuch – z. B. Technik, '
            'Maske, Souffleuse oder wer bei den Proben dabei sein soll.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (byHand.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('Noch niemand von Hand hinzugefügt.'),
          )
        else
          _group([for (final m in byHand) _byHandTile(cast, m)]),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              key: const ValueKey('ensemble-add'),
              onPressed: () => _add(cast),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Person hinzufügen'),
            ),
          ),
        ),
        SectionTitle('Über Rollen & Regie (${viaCasting.length})'),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Gehören über die Rollenbesetzung oder die Regie automatisch '
            'dazu. Ändern lässt sich das unter „Besetzung & Team“.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (viaCasting.isEmpty)
          const Text('Noch keine Rolle besetzt und keine Regie eingetragen.')
        else
          _group([for (final m in viaCasting) _castingTile(cast, m)]),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('ensemble-casting'),
              onPressed: () => _openCasting(cast.id),
              icon: const Icon(Icons.theater_comedy_outlined),
              label: const Text('Besetzung & Team öffnen'),
            ),
          ),
        ),
      ];
    },
  );

  Widget _summary(BuildContext context, ProductionCast cast) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final now = _controller.now;
    final scoped = _controller.events
        .where(
          (e) =>
              e.productionIds.contains(cast.id) &&
              e.slotPoolId == null &&
              (e.endsAt ?? e.startsAt)?.isAfter(now) == true,
        )
        .length;
    final size = cast.ensemble.length;
    return Card(
      key: const ValueKey('ensemble-summary'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Eyebrow('Ensemble'),
            const SizedBox(height: 8),
            Text(cast.title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 10),
            Text(
              'Wer hier steht, sieht die Termine, Mitteilungen und '
              'Abstimmungen, die an das Ensemble dieses Stücks gehen.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                StatePill(
                  size == 1 ? '1 Person' : '$size Personen',
                  color: scheme.secondary,
                  icon: Icons.groups_outlined,
                ),
                StatePill(
                  scoped == 1
                      ? '1 kommender Termin nur fürs Ensemble'
                      : '$scoped kommende Termine nur fürs Ensemble',
                  color: scheme.tertiary,
                  icon: Icons.event_outlined,
                ),
              ],
            ),
          ],
        ),
      ),
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

  String _inactive(int id, String text) =>
      _member(id)?.active == false ? '$text · Nicht aktiv' : text;

  Widget _byHandTile(ProductionCast cast, EnsembleMembership m) => ListTile(
    key: ValueKey('ensemble-member-${m.personId}'),
    contentPadding: const EdgeInsets.only(left: 16, right: 4),
    leading: _avatar(m.personId),
    title: Text(_name(m.personId)),
    subtitle: Text(
      _inactive(
        m.personId,
        [m.function ?? 'Weitere Mitwirkende', ...m.castingReasons].join(' · '),
      ),
    ),
    trailing: IconButton(
      key: ValueKey('ensemble-remove-${m.personId}'),
      tooltip: '${_name(m.personId)} entfernen',
      icon: const Icon(Icons.remove_circle_outline),
      onPressed: () => _remove(cast, m),
    ),
  );

  Widget _castingTile(ProductionCast cast, EnsembleMembership m) => ListTile(
    key: ValueKey('ensemble-member-${m.personId}'),
    contentPadding: const EdgeInsets.only(left: 16, right: 4),
    leading: _avatar(m.personId),
    title: Text(_name(m.personId)),
    subtitle: Text(_inactive(m.personId, m.castingReasons.join(' · '))),
    onTap: () => _explain(cast, m),
    trailing: IconButton(
      key: ValueKey('ensemble-locked-${m.personId}'),
      tooltip: 'Über die Besetzung im Ensemble',
      icon: const Icon(Icons.lock_outline),
      onPressed: () => _explain(cast, m),
    ),
  );
}
