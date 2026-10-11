/// How the reader presents a script. The [code] is persisted per production
/// under `reader.<id>.mode` and must not change.
enum ReaderMode {
  read('read', 'Lesen', 'Das ganze Stück, eigene Rollen hervorgehoben'),
  practice(
    'practice',
    'Lernen',
    'Eigene Texte verdeckt, antippen zum Aufdecken',
  ),
  actor('actor', 'Meine Texte', 'Nur deine Einsätze mit etwas Kontext'),
  technical('technical', 'Technik', 'Ganzer Text mit allen Technik-Hinweisen'),
  cues('cues', 'Nur Cues', 'Nur Technik-Hinweise und Regieanweisungen'),
  stage('stage', 'Bühne', 'Große Schrift auf dunklem Grund');

  const ReaderMode(this.code, this.label, this.description);
  final String code, label, description;

  /// Falls back to [read] for unknown or missing codes.
  static ReaderMode fromCode(String? code) =>
      values.where((mode) => mode.code == code).firstOrNull ?? read;

  /// Modes that only make sense with at least one selected role.
  bool get needsRoles => this == practice || this == actor;

  /// Modes that always show the technical categories.
  bool get technicalFocus => this == technical || this == cues;
}
