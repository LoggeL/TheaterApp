import 'package:flutter/material.dart';

import 'script_document.dart';

/// Display data for one cue category: the short [label] on cue cards and in
/// the PDF, the [setting] name in the reading settings.
class CueCategoryInfo {
  const CueCategoryInfo({
    required this.label,
    required this.setting,
    required this.icon,
    required this.color,
  });
  final String label, setting;
  final IconData icon;
  final Color color;
}

/// The one label table for cue categories. The keys are the persisted
/// category codes in `reader.<id>.categories`.
const cueCategories = <String, CueCategoryInfo>{
  'direction': CueCategoryInfo(
    label: 'Regie',
    setting: 'Regieanweisungen',
    icon: Icons.edit_note_rounded,
    color: Color(0xFF8D7A66),
  ),
  'technical': CueCategoryInfo(
    label: 'Technik',
    setting: 'Technik',
    icon: Icons.tune_rounded,
    color: Color(0xFF648895),
  ),
  'lighting': CueCategoryInfo(
    label: 'Licht',
    setting: 'Licht',
    icon: Icons.light_mode_outlined,
    color: Color(0xFFB1832D),
  ),
  'audio': CueCategoryInfo(
    label: 'Ton / Einspieler',
    setting: 'Ton',
    icon: Icons.volume_up_outlined,
    color: Color(0xFF8076AF),
  ),
  'props': CueCategoryInfo(
    label: 'Requisite',
    setting: 'Requisiten',
    icon: Icons.inventory_2_outlined,
    color: Color(0xFF62866D),
  ),
  'microphone': CueCategoryInfo(
    label: 'Mikrofon',
    setting: 'Mikrofonhinweise',
    icon: Icons.mic_none_rounded,
    color: Color(0xFF4D8792),
  ),
  'autoMicrophone': CueCategoryInfo(
    label: 'Mikrofon',
    setting: 'Automatische Mikrofonhinweise',
    icon: Icons.mic_none_rounded,
    color: Color(0xFF4D8792),
  ),
};

const _otherCategory = CueCategoryInfo(
  label: 'Text',
  setting: 'Text',
  icon: Icons.notes_rounded,
  color: Color(0xFF888888),
);

/// The category key of [cue]; generated microphone cues get their own key.
String cueCategory(ScriptCue cue) =>
    cue.kind == 'microphone' && cue.isAutoMic ? 'autoMicrophone' : cue.kind;

CueCategoryInfo cueCategoryInfo(String key) =>
    cueCategories[key] ?? _otherCategory;
