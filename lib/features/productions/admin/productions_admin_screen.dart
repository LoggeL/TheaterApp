import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/empty_state.dart';
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
      final imported = widget.controller.productionRecords
          .map((p) => textValue(p['id']))
          .toSet();
      final entries = jsonList(source['productions']).map(jsonMap).toList();
      final selected = await showDialog<JsonMap>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Drehbuch importieren'),
          children: [
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Text('In der Skriptquelle ist noch kein Drehbuch.'),
              ),
            for (final p in entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, p),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text(textValue(p['title']))),
                      if (imported.contains(textValue(p['id'])))
                        Text(
                          'Bereits importiert',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      final id = textValue(selected['id']);
      if (imported.contains(id)) {
        final overwrite = await confirmDestructive(
          context,
          title: 'Drehbuch erneut importieren?',
          message:
              'Die Fassung von „${textValue(selected['title'])}“ wird durch '
              'den Stand aus der Skriptquelle ersetzt. Besetzungen bleiben für '
              'Rollen erhalten, die es weiterhin gibt; Regie und Team bleiben '
              'unverändert. Ein gesetzter gemeinsamer Fokus wird zurückgesetzt.',
          confirmLabel: 'Ersetzen',
        );
        if (!overwrite || !mounted) return;
      }
      await widget.controller.remote(
        '/admin/import-script',
        method: 'POST',
        body: {'productionId': id},
      );
      await widget.controller.refresh();
      await widget.controller.loadScript(id);
      if (mounted) showDone(context, 'Drehbuch importiert.');
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final id = await openPage<String>(
      context,
      ProductionEditorScreen(controller: widget.controller),
    );
    if (id == null || !mounted) return;
    // Casting and archive are only available once the production exists.
    final created = widget.controller.productionRecords
        .where((p) => p['id'] == id)
        .firstOrNull;
    if (created == null) return;
    await openPage(
      context,
      ProductionEditorScreen(
        controller: widget.controller,
        production: created,
      ),
    );
  }

  Widget _production(BuildContext context, JsonMap p) {
    final newest =
        p['id'] == widget.controller.activeProductions.firstOrNull?.id;
    final roles = jsonList(p['roles']).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: newest ? Theme.of(context).colorScheme.primaryContainer : null,
        child: ListTile(
          leading: Icon(
            p['archived'] == true
                ? Icons.inventory_2_outlined
                : Icons.auto_stories_outlined,
          ),
          title: Text(textValue(p['title'])),
          subtitle: Text(
            '${newest ? 'Neuestes Stück · ' : ''}'
            '${intValue(p['sceneCount'])} Szenen · '
            '${roles == 0 ? '0 Rollen' : '${ProductionCast.fromRecord(p).castCount} von $roles Rollen besetzt'}',
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
    );
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Produktionen & Besetzung',
    children: (context) {
      final records = widget.controller.productionRecords;
      final active = records.where((p) => p['archived'] != true).toList();
      final archived = records.where((p) => p['archived'] == true).toList();
      return [
        FilledButton.icon(
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.add),
          label: const Text('Produktion anlegen'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _import,
          icon: const Icon(Icons.cloud_download_outlined),
          label: const Text('Drehbuch importieren'),
        ),
        const SizedBox(height: 22),
        if (_busy) const LinearProgressIndicator(),
        if (records.isEmpty)
          const EmptyState(
            icon: Icons.auto_stories_outlined,
            title: 'Noch keine Produktionen',
            message:
                'Lege eine Produktion an oder importiere ein Drehbuch aus der '
                'Skriptquelle.',
          ),
        for (final p in active) _production(context, p),
        if (archived.isNotEmpty)
          ExpansionTile(
            key: const ValueKey('productions-admin-archive'),
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text('Archiv (${archived.length})'),
            children: [for (final p in archived) _production(context, p)],
          ),
      ];
    },
  );
}
