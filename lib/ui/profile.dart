import 'responsive.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../core/app_controller.dart';
import '../core/models.dart';
import '../data/api_client.dart';

class ProtectedImage extends StatefulWidget {
  const ProtectedImage({
    super.key,
    required this.controller,
    required this.path,
    this.fit = BoxFit.cover,
    this.decodeWidth = 480,
    this.fallback,
  });
  final AppController controller;
  final String path;
  final BoxFit fit;
  final int decodeWidth;
  final Widget? fallback;
  @override
  State<ProtectedImage> createState() => _ProtectedImageState();
}

class _ProtectedImageState extends State<ProtectedImage> {
  late Future<MediaData> _image;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _image = widget.controller.mediaBytes(widget.path);
  }

  @override
  void didUpdateWidget(ProtectedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.controller != widget.controller) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MediaData>(
    future: _image,
    builder: (context, state) {
      final placeholder =
          widget.fallback ??
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(child: Icon(Icons.photo_outlined)),
          );
      if (state.hasError) {
        return widget.fallback ??
            InkWell(
              onTap: () => setState(_load),
              child: const Center(
                child: Tooltip(
                  message: 'Bild erneut laden',
                  child: Icon(Icons.refresh),
                ),
              ),
            );
      }
      if (!state.hasData) return placeholder;
      return Image.memory(
        state.data!.bytes,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: widget.decodeWidth,
        gaplessPlayback: false,
        errorBuilder: (_, _, _) => placeholder,
      );
    },
  );
}

class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.controller,
    this.avatarId,
    required this.initials,
    this.radius = 22,
  });
  final AppController controller;
  final String? avatarId;
  final String initials;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
    return SizedBox.square(
      dimension: radius * 2,
      child: ClipOval(
        child: avatarId == null
            ? fallback
            : ProtectedImage(
                controller: controller,
                path: '/media/$avatarId',
                decodeWidth: 256,
                fallback: fallback,
              ),
      ),
    );
  }
}

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
  bool _busy = false;
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
      if (_selected != null) {
        final upload = await widget.controller.remote(
          '/media',
          method: 'POST',
          body: {'kind': 'profile', 'content': base64Encode(_selected!)},
        );
        _avatar = textValue(upload['id']);
        _selected = null;
      }
      await widget.controller.saveProfile(avatarId: _avatar, version: _version);
      if (mounted) Navigator.pop(context);
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
                        _avatar = null;
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
        FilledButton(
          onPressed: _busy || widget.controller.isDemo ? null : _save,
          child: Text(_busy ? 'Wird gespeichert …' : 'Speichern'),
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
