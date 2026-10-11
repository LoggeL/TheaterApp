import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../casting/domain/casting.dart';
import '../../casting/ui/casting_screen.dart';
import 'production_editor_screen.dart';

class ProductionsAdminScreen extends StatefulWidget {
  const ProductionsAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ProductionsAdminScreen> createState() => _ProductionsAdminScreenState();
}

class _ProductionsAdminScreenState extends State<ProductionsAdminScreen> {
  bool _busy = false;
  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final source = await widget.controller.remote('/admin/script-source');
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Drehbuch übernehmen'),
          children: [
            for (final p in jsonList(source['productions']).map(jsonMap))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, textValue(p['id'])),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(textValue(p['title'])),
                ),
              ),
          ],
        ),
      );
      if (selected == null) return;
      await widget.controller.remote(
        '/admin/import-script',
        method: 'POST',
        body: {'productionId': selected},
      );
      await widget.controller.refresh();
      await widget.controller.loadScript(selected);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Drehbuch übernommen.')));
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Produktionen & Besetzung',
    children: (context) => [
      FilledButton.icon(
        onPressed: _busy ? null : _import,
        icon: const Icon(Icons.cloud_download_outlined),
        label: const Text('Aus Skript übernehmen'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => openPage(
          context,
          ProductionEditorScreen(controller: widget.controller),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Produktion anlegen'),
      ),
      const SizedBox(height: 22),
      if (_busy) const LinearProgressIndicator(),
      for (final p in widget.controller.productionRecords)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            color:
                p['id'] == widget.controller.activeProductions.firstOrNull?.id
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: ListTile(
              leading: Icon(
                p['archived'] == true
                    ? Icons.inventory_2_outlined
                    : Icons.auto_stories_outlined,
              ),
              title: Text(textValue(p['title'])),
              subtitle: Text(
                '${p['archived'] == true
                    ? 'Archiv · '
                    : p['id'] == widget.controller.activeProductions.firstOrNull?.id
                    ? 'Neuestes Stück · '
                    : ''}${intValue(p['sceneCount'])} Szenen · ${jsonList(p['roles']).isEmpty ? '0 Rollen' : '${ProductionCast.fromRecord(p).castCount} von ${jsonList(p['roles']).length} Rollen besetzt'}',
              ),
              trailing: IconButton(
                key: ValueKey('production-casting-${p['id']}'),
                tooltip: 'Besetzung & Team',
                icon: const Icon(Icons.groups_outlined),
                onPressed: () => openPage(
                  context,
                  CastingScreen(
                    controller: widget.controller,
                    productionId: textValue(p['id']),
                  ),
                ),
              ),
              onTap: () => openPage(
                context,
                ProductionEditorScreen(
                  controller: widget.controller,
                  production: p,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
