import '../../../core/models.dart';
import '../../casting/domain/casting.dart';

/// Why a person belongs to a production's ensemble.
///
/// Derived from the production record alone (casting, directors and the
/// people added by hand), so the ensemble keeps one source of truth.
class EnsembleMembership {
  const EnsembleMembership({
    required this.personId,
    this.roles = const [],
    this.directs = false,
    this.byHand = false,
    this.function,
  });
  final int personId;

  /// Script roles the person is cast in.
  final List<ScriptRole> roles;

  /// In the production's direction.
  final bool directs;

  /// Added by hand as "weitere Mitwirkende" (the production's team).
  final bool byHand;

  /// Free-text function of a person added by hand, e.g. "Licht".
  final String? function;

  /// Belongs through casting or direction; that only changes under
  /// "Besetzung & Team".
  bool get viaCasting => roles.isNotEmpty || directs;

  /// The casting reasons, e.g. ["Rolle JULIA", "Regie"].
  List<String> get castingReasons => [
    for (final role in roles) 'Rolle ${role.name}',
    if (directs) 'Regie',
  ];

  /// Every reason, e.g. ["Rolle JULIA", "Weitere Mitwirkende (Licht)"].
  List<String> get reasons => [
    ...castingReasons,
    if (byHand)
      function == null
          ? 'Weitere Mitwirkende'
          : 'Weitere Mitwirkende ($function)',
  ];
}

/// Everyone in [cast]'s ensemble with their reasons, in no particular order.
List<EnsembleMembership> ensembleMemberships(ProductionCast cast) => [
  for (final personId in cast.ensemble)
    EnsembleMembership(
      personId: personId,
      roles: cast.rolesOf(personId),
      directs: cast.directors.contains(personId),
      byHand: cast.team.contains(personId),
      function: cast.functions[personId],
    ),
];
