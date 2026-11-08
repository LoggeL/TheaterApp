import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'stage_runner_sound.dart';

/// A volume share as the settings show it: "80 %".
String runnerVolumeText(double share) =>
    '${(share.clamp(0.0, 1.0) * 100).round()} %';

/// "Ton" in the game's settings: the volumes of the music and the effects
/// ([RunnerVolumes]), from 0 to 100 % in steps of 5. The music changes as
/// the slider moves; the effects play [previewSfx] to be heard, at most
/// every [previewGap] (and once more at the end of a quick drag). Mute
/// stays the switch in the app bar; muted, the sliders still keep their
/// volume for later.
///
/// The preview ([RunnerVolumes.previewEffect]) gets the sounds ready
/// within the slider's gesture, so a browser lets it sound also before the
/// first run, once they are decoded.
class RunnerVolumeSettings extends StatefulWidget {
  const RunnerVolumeSettings({
    super.key,
    required this.sound,
    required this.volumes,
    this.onAdjust,
  });

  /// Tells whether sound is on.
  final RunnerSound sound;
  final RunnerVolumes volumes;

  /// Called before either volume changes, e.g. to let a paused run be
  /// heard.
  final VoidCallback? onAdjust;

  /// The effect a change of "Effekte" plays: a short pickup.
  @visibleForTesting
  static const previewSfx = RunnerSfx.rose;

  /// The least time between two previews.
  @visibleForTesting
  static const previewGap = Duration(milliseconds: 300);

  @override
  State<RunnerVolumeSettings> createState() => _RunnerVolumeSettingsState();
}

class _RunnerVolumeSettingsState extends State<RunnerVolumeSettings> {
  /// Runs after a preview; a change meanwhile is previewed at its end.
  Timer? _cooling;
  bool _again = false;

  void _preview() {
    if (_cooling != null) {
      _again = true;
      return;
    }
    // Silent at 0 % and while muted: nothing to hear.
    if (widget.volumes.effectsVolume.value > 0 && widget.sound.enabled.value) {
      widget.volumes.previewEffect(RunnerVolumeSettings.previewSfx);
    }
    _cooling = Timer(RunnerVolumeSettings.previewGap, () {
      _cooling = null;
      if (!_again || !mounted) return;
      _again = false;
      _preview();
    });
  }

  @override
  void dispose() {
    _cooling?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Ton', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _VolumeSlider(
          id: 'music',
          label: 'Musik',
          icon: Icons.music_note_outlined,
          share: widget.volumes.musicVolume,
          onChanged: (share) {
            widget.onAdjust?.call();
            widget.volumes.setMusicVolume(share);
          },
        ),
        _VolumeSlider(
          id: 'effects',
          label: 'Effekte',
          icon: Icons.graphic_eq,
          share: widget.volumes.effectsVolume,
          onChanged: (share) {
            widget.onAdjust?.call();
            widget.volumes.setEffectsVolume(share);
            _preview();
          },
        ),
        ValueListenableBuilder(
          valueListenable: widget.sound.enabled,
          builder: (context, on, _) => Text(
            on
                ? 'Deine Lautstärke wird auf diesem Gerät gespeichert.'
                : 'Der Ton ist gerade aus. Die Lautstärke gilt, sobald du ihn wieder einschaltest.',
            key: const ValueKey('runner-volume-note'),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// One volume: its name and percent above, the slider below (so a large
/// font has room). Read out as one slider with its name and percent.
class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    required this.id,
    required this.label,
    required this.icon,
    required this.share,
    required this.onChanged,
  });

  final String id, label;
  final IconData icon;
  final ValueListenable<double> share;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: share,
      builder: (context, value, _) {
        final text = runnerVolumeText(value);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The slider says both itself.
            ExcludeSemantics(
              child: Row(
                children: [
                  Icon(
                    value > 0 ? icon : Icons.volume_off_outlined,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(label)),
                  Text(
                    text,
                    key: ValueKey('runner-volume-$id-text'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            // One node: the name with the slider's value and actions.
            MergeSemantics(
              child: Semantics(
                label: label,
                child: Slider(
                  key: ValueKey('runner-volume-$id'),
                  value: value.clamp(0.0, 1.0),
                  divisions: 20,
                  semanticFormatterCallback: runnerVolumeText,
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
