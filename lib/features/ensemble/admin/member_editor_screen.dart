import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../casting/ui/person_productions.dart';
import 'roles_admin_screen.dart';

class MemberEditorScreen extends StatefulWidget {
  const MemberEditorScreen({super.key, required this.controller, this.member});
  final AppController controller;
  final JsonMap? member;
  @override
  State<MemberEditorScreen> createState() => _MemberEditorScreenState();
}

class _MemberEditorScreenState extends State<MemberEditorScreen> {
  late final TextEditingController _name;
  late bool _active;
  late Set<String> _roles;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: textValue(widget.member?['name']));
    _active = widget.member?['active'] != false;
    _roles = jsonList(
      widget.member?['roleIds'],
    ).map((r) => r.toString()).toSet();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'member.save',
        'id': widget.member?['id'],
        'version': widget.member?['version'] ?? 1,
        'name': _name.text,
        'active': _active,
        'roleIds': _roles.toList(),
      });
      if (mounted) Navigator.pop(context);
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
      final data = await widget.controller.remote('/admin/accounts');
      final accounts = jsonList(data['accounts'])
          .map(jsonMap)
          .where((a) => intValue(a['personId'], -1) == personId)
          .toList();
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
      for (final a in accounts) {
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
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: widget.member == null ? 'Person anlegen' : 'Person bearbeiten',
    children: (context) => [
      TextField(
        controller: _name,
        decoration: const InputDecoration(labelText: 'Name'),
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
        onPressed: () =>
            openPage(context, RolesAdminScreen(controller: widget.controller)),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Rollen anpassen'),
      ),
      const SizedBox(height: 16),
      SwitchListTile(
        value: _active,
        onChanged: (v) => setState(() => _active = v),
        title: const Text('Aktives Mitglied'),
      ),
      const SizedBox(height: 28),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Speichern'),
      ),
      if (widget.member != null)
        PersonProductions(
          controller: widget.controller,
          personId: intValue(widget.member!['id']),
        ),
      if (_deletable) ...[const SizedBox(height: 48), _dangerZone(context)],
    ],
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
  final List<JsonMap> accounts;
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
    final accounts = widget.accounts
        .map((a) => textValue(a['email'], textValue(a['name'])))
        .join(', ');
    const items = [
      'Rückmeldungen, Absagegründe und Abwesenheiten',
      'Anwesenheiten und Teilnahmeübersicht',
      'Besetzungen, Regie und Mitwirkung in Stücken',
      'Einladungen, gebuchte Zeitfenster und Lesebestätigungen',
      'Kommentare im Drehbuch und namentliche Stimmen; anonyme Stimmen zählen ohne Namen weiter',
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
              widget.accounts.isEmpty
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
}
