import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../accounts/data/accounts_api.dart';
import '../../accounts/ui/person_access_section.dart';
import '../../casting/ui/person_productions.dart';
import 'roles_admin_screen.dart';
import 'website_profile_link.dart';

/// Creates or edits a person. When a new person was saved, the route pops
/// with their id (null while the creation still waits for a connection).
class MemberEditorScreen extends StatefulWidget {
  const MemberEditorScreen({
    super.key,
    required this.controller,
    this.member,
    this.initialName,
  });
  final AppController controller;
  final JsonMap? member;

  /// Prefills the name of a new person, e.g. from a registration.
  final String? initialName;
  @override
  State<MemberEditorScreen> createState() => _MemberEditorScreenState();
}

class _MemberEditorScreenState extends State<MemberEditorScreen> {
  late final TextEditingController _name;
  late bool _active;
  late Set<String> _roles;
  late final String _initialName;
  late final bool _initialActive;
  late final Set<String> _initialRoles;
  bool _busy = false, _saved = false, _touched = false;
  @override
  void initState() {
    super.initState();
    _initialName = widget.member == null
        ? (widget.initialName ?? '').trim()
        : textValue(widget.member?['name']);
    _name = TextEditingController(text: _initialName)
      ..addListener(
        () => setState(() => _touched |= _name.text != _initialName),
      );
    _active = _initialActive = widget.member?['active'] != false;
    _initialRoles = jsonList(
      widget.member?['roleIds'],
    ).map((r) => r.toString()).toSet();
    _roles = {..._initialRoles};
  }

  bool get _nameMissing => _name.text.trim().isEmpty;

  bool get _dirty =>
      !_saved &&
      (_name.text.trim() != _initialName.trim() ||
          _active != _initialActive ||
          _roles.length != _initialRoles.length ||
          !_roles.containsAll(_initialRoles));

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameMissing) return;
    final messenger = ScaffoldMessenger.of(context);
    final known = widget.controller.members.map((m) => m.id).toSet();
    setState(() => _busy = true);
    try {
      final outcome = await widget.controller.performAction({
        'action': 'member.save',
        'id': widget.member?['id'],
        'version': widget.member?['version'] ?? 1,
        'name': _name.text,
        'active': _active,
        'roleIds': _roles.toList(),
      });
      if (!mounted) return;
      // A new person has an id once the server took it and the list reloaded.
      final created = widget.member != null
          ? null
          : widget.controller.members
                .where(
                  (m) => !known.contains(m.id) && m.name == _name.text.trim(),
                )
                .map((m) => m.id)
                .singleOrNull;
      setState(() => _saved = true);
      Navigator.pop(context, created);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            outcomeText(
              outcome,
              done: 'Person gespeichert.',
              queued:
                  'Person vorgemerkt – wird übertragen, sobald die Verbindung steht.',
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Everyone but the own person can be deleted.
  bool get _deletable =>
      widget.member != null &&
      intValue(widget.member!['id'], -1) != widget.controller.user?.personId;

  Future<void> _delete() async {
    final member = widget.member!, name = textValue(member['name']).trim();
    final personId = intValue(member['id'], -1);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      // The server only deletes unlinked people: linked logins go first via
      // the account endpoint, which also removes the Firebase identity.
      // Without that list (offline) only deactivating is possible.
      List<JsonMap>? accounts;
      try {
        final roster = await fetchRoster(widget.controller);
        accounts = roster.accounts
            .where((a) => intValue(a['personId'], -1) == personId)
            .toList();
      } catch (_) {
        if (member['active'] == false) rethrow;
      }
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (_) => _DeleteMemberDialog(
          name: name,
          active: member['active'] != false,
          accounts: accounts,
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'deactivate') {
        setState(() => _active = false);
        await _save();
        return;
      }
      for (final a in accounts!) {
        await widget.controller.remote(
          '/admin/accounts/${Uri.encodeComponent(textValue(a['uid']))}',
          method: 'DELETE',
          body: {'version': a['version']},
        );
      }
      await widget.controller.performAction({
        'action': 'member.delete',
        'id': personId,
        'version': member['version'] ?? 1,
      });
      final queued = widget.controller.outbox.any(
        (a) => !a.failed && a.payload['action'] == 'member.delete',
      );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            queued
                ? 'Löschen von $name ist vorgemerkt und wird übertragen, sobald die Verbindung steht.'
                : '$name wurde gelöscht.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _dangerZone(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inactive = widget.member?['active'] == false;
    final style = inactive
        ? FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          )
        : OutlinedButton.styleFrom(
            foregroundColor: scheme.error,
            side: BorderSide(color: scheme.error),
          );
    const icon = Icon(Icons.delete_forever_outlined);
    const label = Text('Person löschen');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.error.withValues(alpha: .6)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Gefahrenbereich',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: scheme.error),
          ),
          const SizedBox(height: 8),
          Text(
            inactive
                ? 'Diese Person ist nicht mehr aktiv. Hat sie das Theater '
                      'dauerhaft verlassen, kannst du sie mit allen ihren Daten '
                      'endgültig löschen.'
                : 'Wer nur pausiert, wird besser deaktiviert. Löschen entfernt '
                      'die Person mit allen ihren Daten endgültig.',
          ),
          const SizedBox(height: 12),
          inactive
              ? FilledButton.icon(
                  style: style,
                  onPressed: _busy ? null : _delete,
                  icon: icon,
                  label: label,
                )
              : OutlinedButton.icon(
                  style: style,
                  onPressed: _busy ? null : _delete,
                  icon: icon,
                  label: label,
                ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => DiscardGuard(
    dirty: _dirty && !_busy,
    child: AdminPage(
      controller: widget.controller,
      title: widget.member == null ? 'Person anlegen' : 'Person bearbeiten',
      children: (context) => [
        TextFormField(
          controller: _name,
          decoration: InputDecoration(
            labelText: 'Name',
            errorText: _nameMissing && _touched
                ? 'Bitte einen Namen eingeben.'
                : null,
          ),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 20),
        const SectionTitle('Rollen'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in widget.controller.personRoles)
              FilterChip(
                label: Text(textValue(r['name'])),
                selected: _roles.contains(r['id']),
                onSelected: _busy
                    ? null
                    : (selected) => setState(() {
                        if (selected) {
                          _roles.add(textValue(r['id']));
                        } else {
                          _roles.remove(r['id']);
                        }
                      }),
              ),
          ],
        ),
        TextButton.icon(
          onPressed: () => openPage(
            context,
            RolesAdminScreen(controller: widget.controller),
          ),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Rollen anpassen'),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          value: _active,
          onChanged: (v) => setState(() => _active = v),
          title: const Text('Aktives Mitglied'),
        ),
        // Everything about the person's app access in one place.
        if (widget.member != null && widget.controller.user?.isAdmin == true)
          PersonAccessSection(
            controller: widget.controller,
            member: widget.member!,
          ),
        if (widget.member != null)
          WebsiteProfileLink(
            controller: widget.controller,
            personId: intValue(widget.member!['id']),
          ),
        if (widget.member != null)
          PersonProductions(
            controller: widget.controller,
            personId: intValue(widget.member!['id']),
          ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: _busy || _nameMissing ? null : _save,
          child: const Text('Speichern'),
        ),
        if (_deletable) ...[const SizedBox(height: 48), _dangerZone(context)],
      ],
    ),
  );
}

/// Asks for the person's name before deleting; offers deactivation instead.
/// Pops 'delete', 'deactivate' or null.
class _DeleteMemberDialog extends StatefulWidget {
  const _DeleteMemberDialog({
    required this.name,
    required this.active,
    required this.accounts,
  });
  final String name;
  final bool active;

  /// The person's app accounts; null when they could not be loaded, which
  /// leaves only deactivating.
  final List<JsonMap>? accounts;
  @override
  State<_DeleteMemberDialog> createState() => _DeleteMemberDialogState();
}

class _DeleteMemberDialogState extends State<_DeleteMemberDialog> {
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  bool get _confirmed =>
      _confirmation.text.trim().toLowerCase() == widget.name.toLowerCase();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final known = widget.accounts;
    if (known == null) return _offline(context);
    final accounts = known
        .map((a) => textValue(a['email'], textValue(a['name'])))
        .join(', ');
    const items = [
      'Rückmeldungen, Absagegründe und Abwesenheiten',
      'Anwesenheiten und Teilnahmeübersicht',
      'Besetzungen, Regie und Mitwirkung in Stücken',
      'Einladungen, gebuchte Zeitfenster und Lesebestätigungen',
      'Kommentare im Drehbuch und namentliche Stimmen; anonyme Stimmen zählen ohne Namen weiter',
      'Der selbst geschriebene „Über mich“-Text; das Website-Profil bleibt ohne Zuordnung bestehen',
      'Termine, Abstimmungen, Terminfinder und Mitteilungen, die nur an diese Person gingen',
    ];
    return AlertDialog(
      title: Text('${widget.name} endgültig löschen?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Die Person wird mit ihren Daten dauerhaft entfernt. '
              'Das lässt sich nicht rückgängig machen. Gelöscht werden:',
            ),
            const SizedBox(height: 8),
            for (final item in [
              ...items,
              known.isEmpty
                  ? 'Es ist kein App-Konto verknüpft.'
                  : 'Verknüpfte App-Konten samt Anmeldung und Geräten: $accounts',
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $item'),
              ),
            const SizedBox(height: 12),
            Text(
              widget.active
                  ? 'Sanfter: Person nur deaktivieren. Dann bleibt alles '
                        'erhalten, sie erscheint nicht mehr in Auswahllisten und '
                        'ihr App-Zugang ist gesperrt.'
                  : 'Wenn du die Daten noch brauchst, lass die Person einfach '
                        'deaktiviert.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmation,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Zur Bestätigung „${widget.name}“ eingeben',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        if (widget.active)
          TextButton(
            onPressed: () => Navigator.pop(context, 'deactivate'),
            child: const Text('Nur deaktivieren'),
          ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: _confirmed ? () => Navigator.pop(context, 'delete') : null,
          child: const Text('Endgültig löschen'),
        ),
      ],
    );
  }

  /// Without a connection the linked accounts are unknown, so the person
  /// cannot be deleted yet; deactivating works offline.
  Widget _offline(BuildContext context) => AlertDialog(
    title: Text('${widget.name} löschen?'),
    content: const Text(
      'Die verknüpften App-Konten konnten gerade nicht geladen werden. '
      'Endgültig löschen geht erst wieder mit Verbindung. Deaktivieren kannst '
      'du die Person schon jetzt: Dann bleibt alles erhalten, sie erscheint '
      'nicht mehr in Auswahllisten und ihr App-Zugang ist gesperrt.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, 'deactivate'),
        child: const Text('Nur deaktivieren'),
      ),
    ],
  );
}
