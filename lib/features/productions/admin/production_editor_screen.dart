import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../casting/domain/casting.dart';
import '../../casting/ui/casting_screen.dart';
import 'ensembles_admin_screen.dart';

/// Creates or edits a production. After creating one, the route pops with
/// the new production's id (null while it still waits for a connection), so
/// the caller can continue in its editor.
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
  bool _busy = false, _touched = false;

  bool get _titleMissing => _title.text.trim().isEmpty;

  /// Title or subtitle differ from what was saved.
  bool get _dirty =>
      !_busy &&
      (_title.text != textValue(widget.production?['title']) ||
          _subtitle.text != textValue(widget.production?['subtitle']));

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: textValue(widget.production?['title']))
      ..addListener(() => setState(() => _touched = true));
    _subtitle = TextEditingController(
      text: textValue(widget.production?['subtitle']),
    )..addListener(() => setState(() {}));
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

  /// Same record as the casting; a changed version is adopted like there.
  Future<void> _openEnsemble() async {
    final id = textValue(widget.production?['id']);
    final before = intValue(_current?['version'] ?? _version);
    await openPage(
      context,
      EnsemblesAdminScreen(controller: widget.controller, productionId: id),
    );
    final after = intValue(_current?['version'] ?? _version);
    if (mounted && before == _version) setState(() => _version = after);
  }

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_titleMissing) return;
    final known = widget.controller.productionRecords
        .map((p) => p['id'])
        .toSet();
    // The route pops before the confirmation shows.
    final messenger = ScaffoldMessenger.of(context);
    final isNew = widget.production?['id'] == null;
    setState(() => _busy = true);
    try {
      final outcome = await widget.controller.performAction({
        'action': 'production.save',
        'id': widget.production?['id'],
        'version': _version,
        'title': _title.text,
        'subtitle': _subtitle.text,
      });
      void confirm() => messenger.showSnackBar(
        SnackBar(
          content: Text(
            outcomeText(
              outcome,
              done: isNew ? 'Produktion angelegt.' : 'Produktion gespeichert.',
              queued: 'Produktion vorgemerkt – wird bei Verbindung gesendet.',
            ),
          ),
        ),
      );
      if (!isNew) {
        await widget.controller.loadScript(textValue(widget.production!['id']));
        if (mounted) {
          Navigator.pop(context);
          confirm();
        }
        return;
      }
      // The new production has an id once the server took it.
      final created = widget.controller.productionRecords
          .map((p) => p['id'])
          .where((id) => !known.contains(id))
          .map((id) => textValue(id))
          .singleOrNull;
      if (mounted) {
        Navigator.pop(context, created);
        confirm();
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _archive() async {
    final production = widget.production;
    if (production == null) return;
    final id = textValue(production['id']);
    final archive = production['archived'] != true;
    final title = textValue(production['title']);
    if (archive &&
        !await confirmDestructive(
          context,
          title: 'Ins Archiv verschieben?',
          message:
              '„$title“ verschwindet für alle aus dem Reiter Drehbücher und '
              'steht danach im Drehbucharchiv.'
              '${_dirty ? ' Ungespeicherte Änderungen gehen dabei verloren.' : ''}',
          confirmLabel: 'Archivieren',
        )) {
      return;
    }
    if (!mounted) return;
    // The route pops before the confirmation shows.
    final messenger = ScaffoldMessenger.of(context);
    final controller = widget.controller;
    setState(() => _busy = true);
    try {
      final outcome = await controller.setProductionArchived(id, archive);
      if (!mounted) return;
      Navigator.pop(context);
      final done = archive
          ? '„$title“ archiviert.'
          : '„$title“ aus dem Archiv zurückgeholt.';
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            outcomeText(
              outcome,
              done: done,
              queued: '$done Wird bei Verbindung gesendet.',
            ),
          ),
          action: archive
              ? SnackBarAction(
                  label: 'Rückgängig',
                  onPressed: () => controller
                      .setProductionArchived(id, false)
                      .catchError((Object e) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(userMessage(e))),
                        );
                        return ActionOutcome.synced;
                      }),
                )
              : null,
        ),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Limiting the events without an audience needs a server that can do
  /// it; archived productions have no upcoming events to limit.
  bool get _canScopeEvents =>
      widget.production != null &&
      (_current ?? widget.production)!['archived'] != true &&
      widget.controller.supports('productionScopeEvents');

  /// Asks the server how many events would change, confirms with the admin
  /// and then limits them silently (no push, no email) to the ensemble.
  Future<void> _scopeEvents() async {
    final id = textValue(widget.production?['id']);
    final title = textValue((_current ?? widget.production)?['title']);
    final controller = widget.controller;
    if (controller.isOffline) {
      showProblem(context, 'Dafür wird eine Verbindung zum Server benötigt.');
      return;
    }
    setState(() => _busy = true);
    try {
      final preview = await controller.performActionWithResult({
        'action': 'production.scopeEvents',
        'productionId': id,
        'dryRun': true,
      });
      final data = preview.data;
      if (preview.outcome == ActionOutcome.queued || data == null) {
        throw 'Die Termine konnten gerade nicht geprüft werden. Bitte mit '
            'Verbindung erneut versuchen.';
      }
      if (!mounted) return;
      final count = intValue(data['updated']);
      final people = intValue(data['ensembleSize']);
      if (count == 0) {
        showDone(
          context,
          'Alle Termine dieses Stücks haben bereits eine Zielgruppe.',
        );
        return;
      }
      final events = count == 1
          ? '1 Termin ohne Zielgruppe gilt'
          : '$count Termine ohne Zielgruppe gelten';
      final confirmed = await confirmAction(
        context,
        title: 'Termine nur fürs Ensemble?',
        message:
            '$events künftig nur für das Ensemble von „$title“ (aktuell '
            '${people == 1 ? '1 Person' : '$people Personen'}). Wer nicht '
            'dazugehört, sieht diese Termine nicht mehr. Es werden keine '
            'Benachrichtigungen verschickt.'
            '${people == 0 ? '\n\nAchtung: Das Ensemble ist noch leer. Bis die '
                      'Besetzung eingetragen ist, sieht niemand ohne '
                      'Admin-Rechte diese Termine.' : ''}',
        confirmLabel: 'Nur fürs Ensemble',
        scrollable: true,
        destructive: people == 0,
      );
      if (!confirmed || !mounted) return;
      final result = await controller.performActionWithResult({
        'action': 'production.scopeEvents',
        'productionId': id,
      });
      if (!mounted) return;
      final updated = intValue(result.data?['updated'], count);
      showDone(
        context,
        outcomeText(
          result.outcome,
          done: updated == 1
              ? '1 Termin angepasst.'
              : '$updated Termine angepasst.',
          queued: 'Änderung vorgemerkt – wird bei Verbindung gesendet.',
        ),
      );
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      DiscardGuard(dirty: _dirty, child: _page(context));

  Widget _page(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: widget.production == null
        ? 'Produktion anlegen'
        : 'Produktion bearbeiten',
    children: (context) => [
      TextField(
        controller: _title,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: 'Titel',
          errorText: _titleMissing && _touched
              ? 'Bitte einen Titel eingeben.'
              : null,
        ),
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
                      : '${cast.castCount} von ${cast.roles.length} '
                            '${cast.roles.length == 1 ? 'Rolle' : 'Rollen'} besetzt',
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
      if (widget.production != null) ...[
        const SizedBox(height: 10),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            key: const ValueKey('production-editor-ensemble'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            leading: const Icon(Icons.diversity_3_outlined),
            title: const Text('Ensemble & Verteiler'),
            subtitle: const Text(
              'Wer zum Stück gehört und warum; weitere Mitwirkende pflegen',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _openEnsemble,
          ),
        ),
      ],
      if (_canScopeEvents) ...[
        const SectionTitle('Termine'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            key: const ValueKey('production-editor-scope-events'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            leading: const Icon(Icons.group_work_outlined),
            title: const Text('Termine nur fürs Ensemble'),
            subtitle: const Text(
              'Kommende Termine dieses Stücks ohne Zielgruppe gelten danach '
              'nur noch für das Ensemble. Ohne Benachrichtigung.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _scopeEvents,
          ),
        ),
      ],
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy || _titleMissing ? null : _save,
        child: Text(
          widget.production == null ? 'Produktion anlegen' : 'Speichern',
        ),
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
