part of '../script_reader_screen.dart';

/// The sheet for the shared live focus (following or directing).
extension _ReaderLive on _ScriptReaderScreenState {
  void _showLive() {
    unawaited(_live.refresh());
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => ListenableBuilder(
        listenable: _live,
        builder: (sheet, _) {
          final focus = _live.focus;
          return ReaderSheetFrame(
            title: 'Ein gemeinsamer Fokus',
            subtitle: widget.controller.isDemo
                ? 'Die Demo zeigt den Fokus auf diesem Gerät. Für mehrere Geräte verbinde dich mit eurem Server.'
                : focus?.source == 'skript'
                ? 'Mit dem Skript-Browser verbunden. Folge der gemeinsamen Textstelle.'
                : 'Folge derselben Textstelle auf Handy, Tablet und in der Web-App.',
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_live.error != null && focus != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _live.error!,
                        style: TextStyle(color: readerAccentText(context)),
                      ),
                    ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Der Regie folgen'),
                    subtitle: Text(
                      focus == null
                          ? _live.error ?? 'Verbindung wird aufgebaut …'
                          : 'Automatisch zur gemeinsamen Textstelle springen',
                    ),
                    value: _live.following,
                    onChanged: focus == null ? null : _live.setFollowing,
                  ),
                  if (_live.canDirect)
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Regie übernehmen'),
                      subtitle: const Text(
                        'Angetippte Textstellen mit allen folgenden Geräten teilen',
                      ),
                      value: _live.directing,
                      onChanged: _live.setDirecting,
                    ),
                  if (_live.canDirect && focus?.cueId != null)
                    TextButton.icon(
                      onPressed: () async {
                        try {
                          await _live.clear();
                        } catch (_) {
                          _notice('Der Fokus konnte nicht aufgehoben werden.');
                        }
                      },
                      icon: const Icon(Icons.location_disabled),
                      label: const Text('Gemeinsamen Fokus aufheben'),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheet),
                      child: const Text('Zurück zum Stück'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
