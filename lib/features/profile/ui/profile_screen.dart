import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';
import '../../../shared/feedback.dart';
import '../../../shared/layout/content_width.dart';
import '../../../shared/widgets/member_avatar.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late String? _avatar;
  late int _version;
  Uint8List? _selected;
  String? _uploadedAvatar;
  bool _busy = false, _hasDraft = false, _conflict = false;
  String? _error;

  /// "Über mich" and hiding the website data; only on servers that know them.
  late final bool _details = widget.controller.supports('ensembleProfiles');
  final _about = TextEditingController();
  String _savedAbout = '';
  bool _hidden = false, _savedHidden = false;

  @override
  void initState() {
    super.initState();
    final u = widget.controller.user!;
    _avatar = u.avatarId;
    _version = u.profileVersion;
    _loadDetails();
    _about.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _about.dispose();
    super.dispose();
  }

  TheaterMember? get _member {
    final personId = widget.controller.user?.personId;
    return widget.controller.members.where((m) => m.id == personId).firstOrNull;
  }

  void _loadDetails() {
    final member = _member;
    _savedAbout = member?.about ?? '';
    _savedHidden = _hidden = member?.websiteHidden ?? false;
    _about.text = _savedAbout;
  }

  bool get _detailsDirty =>
      _details &&
      (_about.text.trim() != _savedAbout.trim() || _hidden != _savedHidden);

  Future<void> _pick() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
        requestFullMetadata: false,
      );
      if (file == null) return;
      if (await file.length() > 8 * 1024 * 1024) {
        throw const ApiException('Bitte ein Bild bis 8 MB auswählen.');
      }
      final bytes = await file.readAsBytes();
      if (mounted) {
        setState(() {
          _selected = bytes;
          _uploadedAvatar = null;
          _hasDraft = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? e.message
              : 'Das Bild konnte nicht ausgewählt werden.',
        );
      }
    }
  }

  Future<void> _save() async {
    // Nothing changed: leave without a round trip to the server.
    if (!_hasDraft && !_detailsDirty) {
      Navigator.pop(context);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final removed = _selected == null && _avatar == null;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_selected != null && _uploadedAvatar == null) {
        final upload = await widget.controller.remote(
          '/media',
          method: 'POST',
          body: {'kind': 'profile', 'content': base64Encode(_selected!)},
        );
        _uploadedAvatar = textValue(upload['id']);
      }
      final details = _detailsDirty, picture = _hasDraft;
      await widget.controller.saveProfile(
        avatarId: _selected != null ? _uploadedAvatar : _avatar,
        version: _version,
        about: _details ? _about.text.trim() : null,
        websiteHidden: _details ? _hidden : null,
      );
      if (!mounted) return;
      setState(() {
        _hasDraft = false;
        _savedAbout = _about.text.trim();
        _savedHidden = _hidden;
      });
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            details || !picture
                ? 'Profil gespeichert.'
                : removed
                ? 'Profilbild entfernt.'
                : 'Profilbild gespeichert.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _conflict = e is ApiException && e.statusCode == 409;
          _error = _conflict
              ? 'Dein Profil wurde inzwischen geändert. Lade den aktuellen '
                    'Stand, bevor du erneut speicherst. Dein ${_hasDraft ? 'Bildentwurf' : 'Entwurf'} bleibt erhalten.'
              : userMessage(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    setState(() => _busy = true);
    try {
      await widget.controller.refresh();
      if (!mounted) return;
      final user = widget.controller.user;
      if (widget.controller.error != null || user == null) {
        throw ApiException(
          widget.controller.error ?? 'Das Profil konnte nicht geladen werden.',
        );
      }
      setState(() {
        _version = user.profileVersion;
        if (!_hasDraft) _avatar = user.avatarId;
        if (!_detailsDirty) _loadDetails();
        _conflict = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = userMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DiscardGuard(
    dirty: (_hasDraft || _detailsDirty) && !_busy,
    child: _page(context),
  );

  Widget _page(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Mein Profil')),
    body: ListView(
      padding: pagePadding(context),
      children: [
        Center(
          child: SizedBox.square(
            dimension: 112,
            child: _selected != null
                ? ClipOval(child: Image.memory(_selected!, fit: BoxFit.cover))
                : MemberAvatar(
                    controller: widget.controller,
                    avatarId: _avatar,
                    initials: widget.controller.user?.initials ?? '',
                    radius: 56,
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _busy || widget.controller.isDemo ? null : _pick,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Bild auswählen'),
            ),
            if (_selected != null || _avatar != null)
              TextButton(
                onPressed: _busy || widget.controller.isDemo
                    ? null
                    : () => setState(() {
                        _selected = null;
                        _uploadedAvatar = null;
                        _avatar = null;
                        _hasDraft = true;
                      }),
                child: const Text('Entfernen'),
              ),
          ],
        ),
        const SizedBox(height: 26),
        Text(
          widget.controller.user?.name ?? '',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (widget.controller.user?.roleIds.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.controller.roleNames(widget.controller.user!.roleIds),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        if (_details) ..._detailFields(context),
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Name und Rollen pflegt die Theaterleitung.'),
            subtitle: const Text(
              'Wenn hier etwas nicht stimmt, sag der Theaterleitung Bescheid.',
            ),
            subtitleTextStyle: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 24),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_conflict)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _reload,
              icon: const Icon(Icons.refresh),
              label: Text(_busy ? 'Wird geladen …' : 'Aktuellen Stand laden'),
            ),
          ),
        // Never disabled without a draft: saving then simply closes the page.
        FilledButton(
          onPressed: _busy || _conflict ? null : _save,
          child: Text(
            _busy
                ? _conflict
                      ? 'Profil wird geladen …'
                      : 'Wird gespeichert …'
                : 'Speichern',
          ),
        ),
        if (widget.controller.isDemo)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('Profilbilder benötigen ein verbundenes Theaterkonto.'),
          ),
      ],
    ),
  );

  List<Widget> _detailFields(BuildContext context) => [
    const SizedBox(height: 24),
    TextField(
      key: const ValueKey('profile-about'),
      controller: _about,
      enabled: !_busy && !widget.controller.isDemo,
      minLines: 3,
      maxLines: 8,
      maxLength: aboutMaxLength,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(
        labelText: 'Über mich',
        hintText: 'Ein paar Sätze für dein Profil im Ensemble',
        helperText:
            'Sehen alle freigegebenen Mitglieder. Leer lassen, '
            'wenn du keinen Text zeigen möchtest.',
        helperMaxLines: 3,
        alignLabelWithHint: true,
      ),
    ),
    const SizedBox(height: 8),
    SwitchListTile(
      key: const ValueKey('profile-website-visible'),
      contentPadding: EdgeInsets.zero,
      value: !_hidden,
      onChanged: _busy || widget.controller.isDemo
          ? null
          : (value) => setState(() => _hidden = !value),
      title: const Text('Angaben der Website zeigen'),
      subtitle: const Text(
        'Foto, Rollen und Aufgaben von kolpingtheater-ramsen.de auf deinem '
        'Profil in der App. Die Website selbst ändert sich dadurch nicht.',
      ),
    ),
  ];
}

/// Longest "Über mich" text; the server allows the same.
const aboutMaxLength = 600;
