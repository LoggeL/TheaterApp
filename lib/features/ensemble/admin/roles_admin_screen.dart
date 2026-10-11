import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';

class RolesAdminScreen extends StatelessWidget {
  const RolesAdminScreen({super.key, required this.controller});
  final AppController controller;

  int _holders(JsonMap role) =>
      controller.members.where((m) => m.roleIds.contains(role['id'])).length;

  Future<void> _edit(BuildContext context, [JsonMap? role]) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _RoleNameDialog(current: textValue(role?['name'])),
    );
    if (value == null || !context.mounted) return;
    try {
      final outcome = await controller.performAction({
        'action': 'personRole.save',
        'id': role?['id'],
        'version': role?['version'],
        'name': value,
      });
      if (context.mounted) {
        showDone(
          context,
          outcomeText(
            outcome,
            done: role == null ? 'Rolle angelegt.' : 'Rolle umbenannt.',
            queued: 'Rolle vorgemerkt – wird bei Verbindung übertragen.',
          ),
        );
      }
    } catch (e) {
      if (context.mounted) showProblem(context, e);
    }
  }

  Future<void> _delete(BuildContext context, JsonMap role) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Rolle entfernen?',
      message:
          'Die Rolle „${textValue(role['name'])}“ wird gelöscht. '
          'Das lässt sich nicht rückgängig machen.',
      confirmLabel: 'Entfernen',
    );
    if (!confirmed || !context.mounted) return;
    try {
      await controller.performAction({
        'action': 'personRole.delete',
        'id': role['id'],
        'version': role['version'],
      });
      if (context.mounted) showDone(context, 'Rolle entfernt.');
    } catch (e) {
      if (context.mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: controller.user?.isAdmin == true
        ? FloatingActionButton.extended(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.add),
            label: const Text('Rolle anlegen'),
          )
        : null,
    body: AdminPage(
      controller: controller,
      title: 'Rollen verwalten',
      children: (context) => [
        if (controller.personRoles.isEmpty)
          const EmptyState(
            icon: Icons.badge_outlined,
            title: 'Noch keine Rollen',
            message:
                'Rollen wie Technik oder Maske fassen Personen zusammen, '
                'z. B. für Einladungen und Mitteilungen.',
          ),
        for (final role in controller.personRoles)
          Card(
            child: ListTile(
              title: Text(textValue(role['name'])),
              subtitle: Text(switch (_holders(role)) {
                1 => '1 Person',
                final n => '$n Personen',
              }),
              onTap: () => _edit(context, role),
              trailing: PopupMenuButton<String>(
                tooltip: 'Rolle verwalten',
                onSelected: (value) => value == 'edit'
                    ? _edit(context, role)
                    : _delete(context, role),
                itemBuilder: (_) {
                  final holders = _holders(role);
                  return [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('Umbenennen'),
                    ),
                    // The server only deletes roles nobody holds any more.
                    PopupMenuItem(
                      value: 'delete',
                      enabled: holders == 0,
                      child: Text(
                        holders == 0
                            ? 'Entfernen'
                            : holders == 1
                            ? 'Entfernen (noch 1 Person)'
                            : 'Entfernen (noch $holders Personen)',
                      ),
                    ),
                  ];
                },
              ),
            ),
          ),
        // Keeps the last card clear of the floating button.
        const SizedBox(height: 72),
      ],
    ),
  );
}

/// Asks for a role name; owns its text field controller so the closing
/// animation never sees a disposed one. Pops the trimmed name or null.
class _RoleNameDialog extends StatefulWidget {
  const _RoleNameDialog({required this.current});
  final String current;
  @override
  State<_RoleNameDialog> createState() => _RoleNameDialogState();
}

class _RoleNameDialogState extends State<_RoleNameDialog> {
  late final _name = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty;

  void _submit() {
    if (_valid) Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.current.isEmpty ? 'Rolle anlegen' : 'Rolle umbenennen'),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: 60,
      decoration: const InputDecoration(labelText: 'Name'),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: _valid ? _submit : null,
        child: const Text('Speichern'),
      ),
    ],
  );
}
