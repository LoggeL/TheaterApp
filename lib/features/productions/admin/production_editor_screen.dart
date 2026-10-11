import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../casting/domain/casting.dart';
import '../../casting/ui/casting_screen.dart';

class ProductionEditorScreen extends StatefulWidget {
  const ProductionEditorScreen({
    super.key,
    required this.controller,
    this.production,
  });
  final AppController controller;
  final JsonMap? production;
  @override
  State<ProductionEditorScreen> createState() => _ProductionEditorScreenState();
}

class _ProductionEditorScreenState extends State<ProductionEditorScreen> {
  late final TextEditingController _title, _subtitle;
  // Casting changes elsewhere raise the version; it is re-read on return.
  late int _version;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _title = TextEditingController(
      text: textValue(widget.production?['title']),
    );
    _subtitle = TextEditingController(
      text: textValue(widget.production?['subtitle']),
    );
    _version = intValue(widget.production?['version'] ?? 1);
  }

  JsonMap? get _current => widget.controller.productionRecords
      .where((p) => p['id'] == widget.production?['id'])
      .firstOrNull;

  Future<void> _openCasting() async {
    final id = textValue(widget.production?['id']);
    final before = intValue(_current?['version'] ?? _version);
    await openPage(
      context,
      CastingScreen(controller: widget.controller, productionId: id),
    );
    final after = intValue(_current?['version'] ?? _version);
    // Only casting changes made meanwhile are adopted; other edits still conflict.
    if (mounted && before == _version) setState(() => _version = after);
  }

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'production.save',
        'id': widget.production?['id'],
        'version': _version,
        'title': _title.text,
        'subtitle': _subtitle.text,
      });
      if (widget.production?['id'] != null) {
        await widget.controller.loadScript(textValue(widget.production!['id']));
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _archive() async {
    final production = widget.production;
    if (production == null) return;
    setState(() => _busy = true);
    try {
      await widget.controller.setProductionArchived(
        textValue(production['id']),
        production['archived'] != true,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Produktion bearbeiten',
    children: (context) => [
      TextField(
        controller: _title,
        decoration: const InputDecoration(labelText: 'Titel'),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _subtitle,
        decoration: const InputDecoration(labelText: 'Untertitel'),
      ),
      const SectionTitle('Besetzung & Team'),
      if (widget.production == null)
        Text(
          'Nach dem Speichern kannst du Rollen besetzen sowie Regie und Team '
          'zuordnen.',
          style: Theme.of(context).textTheme.bodyMedium,
        )
      else
        Builder(
          builder: (context) {
            final cast = ProductionCast.fromRecord(
              _current ?? widget.production!,
            );
            final open = cast.roles.length - cast.castCount;
            return Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                key: const ValueKey('production-editor-casting'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                leading: const Icon(Icons.groups_outlined),
                title: Text(
                  cast.roles.isEmpty
                      ? 'Regie und Team zuordnen'
                      : '${cast.castCount} von ${cast.roles.length} Rollen besetzt',
                ),
                subtitle: Text(
                  '${open > 0 ? '$open offen · ' : ''}Ensemble: '
                  '${cast.ensemble.length} '
                  '${cast.ensemble.length == 1 ? 'Person' : 'Personen'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _openCasting,
              ),
            );
          },
        ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Speichern'),
      ),
      if (widget.production != null) ...[
        const SizedBox(height: 20),
        TextButton.icon(
          onPressed: _busy ? null : _archive,
          icon: Icon(
            widget.production!['archived'] == true
                ? Icons.unarchive_outlined
                : Icons.inventory_2_outlined,
          ),
          label: Text(
            widget.production!['archived'] == true
                ? 'Aus Archiv zurückholen'
                : 'Ins Archiv verschieben',
          ),
        ),
      ],
    ],
  );
}
