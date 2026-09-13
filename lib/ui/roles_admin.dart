import 'package:flutter/material.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import 'admin.dart';

class RolesAdminScreen extends StatelessWidget {
  const RolesAdminScreen({super.key, required this.controller});
  final AppController controller;
  Future<void> _edit(BuildContext context, [JsonMap? role]) async {
    final name = TextEditingController(text: textValue(role?['name']));
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(role == null ? 'Rolle anlegen' : 'Rolle umbenennen'),
        content: TextField(
          controller: name,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(ctx, v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) Navigator.pop(ctx, name.text);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (value != null) {
      try {
        await controller.performAction({
          'action': 'personRole.save',
          'id': role?['id'],
          'version': role?['version'],
          'name': value,
        });
      } catch (e) {
        if (context.mounted) showProblem(context, e);
      }
    }
    // The route owns its closing animation before the field controller is released.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: controller,
    title: 'Rollen verwalten',
    children: (context) => [
      for (final role in controller.personRoles)
        Card(
          child: ListTile(
            title: Text(textValue(role['name'])),
            subtitle: Text(
              '${controller.members.where((m) => m.roleIds.contains(role['id'])).length} Personen',
            ),
            onTap: () => _edit(context, role),
            trailing: PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'edit') {
                  await _edit(context, role);
                  return;
                }
                try {
                  await controller.performAction({
                    'action': 'personRole.delete',
                    'id': role['id'],
                    'version': role['version'],
                  });
                } catch (e) {
                  if (context.mounted) showProblem(context, e);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Umbenennen')),
                if (!controller.members.any(
                  (m) => m.roleIds.contains(role['id']),
                ))
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Entfernen'),
                  ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('Rolle anlegen'),
      ),
    ],
  );
}
