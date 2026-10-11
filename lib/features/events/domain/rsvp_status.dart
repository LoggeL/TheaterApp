import 'package:flutter/material.dart';

/// A member's response to an event, with one shared vocabulary.
enum RsvpStatus {
  yes('yes', 'Zugesagt', 'Bin dabei', Icons.check_circle_outline),
  late('late', 'Später', 'Komme später', Icons.schedule),
  no('no', 'Abgesagt', 'Kann nicht', Icons.cancel_outlined),
  open('open', 'Offen', 'Offen', Icons.help_outline);

  const RsvpStatus(this.wire, this.label, this.actionLabel, this.icon);

  /// The value the server sends and expects.
  final String wire;

  /// The status as shown in legends, chips and badges.
  final String label;

  /// The label of the button that gives this response.
  final String actionLabel;
  final IconData icon;

  /// Any unknown or missing value counts as open.
  static RsvpStatus fromWire(String? value) => switch (value) {
    'yes' => yes,
    'late' => late,
    'no' => no,
    _ => open,
  };
}
