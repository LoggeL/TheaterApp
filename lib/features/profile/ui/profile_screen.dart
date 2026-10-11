import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../data/api_client.dart';
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
  @override
  void initState() {
    super.initState();
    final u = widget.controller.user!;
    _avatar = u.avatarId;
    _version = u.profileVersion;
  }

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
      await widget.controller.saveProfile(
        avatarId: _selected != null ? _uploadedAvatar : _avatar,
        version: _version,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _conflict = e is ApiException && e.statusCode == 409;
          _error = _conflict
              ? 'Dein Profil wurde inzwischen geändert. Lade den aktuellen '
                    'Stand, bevor du erneut speicherst. Dein Bildentwurf bleibt erhalten.'
              : e.toString();
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
        _conflict = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Bild auswählen'),
            ),
            if (_selected != null || _avatar != null)
              TextButton(
                onPressed: _busy
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
        const SizedBox(height: 28),
        const SizedBox(height: 16),
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
        FilledButton(
          onPressed: _busy || _conflict || widget.controller.isDemo
              ? null
              : _save,
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
}
