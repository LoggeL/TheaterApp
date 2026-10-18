import 'package:flutter/material.dart';

import '../../../app/theme/stage_theme.dart';
import '../../../shared/widgets/state_pill.dart';
import '../domain/feedback_ticket.dart';
import 'feedback_category_icon.dart';

Widget feedbackCategoryPill(BuildContext context, String category) {
  final theme = Theme.of(context);
  return StatePill(
    feedbackCategoryLabel(category),
    color: switch (category) {
      'bug' => theme.colorScheme.error,
      'idea' => StageTheme.violet,
      _ => theme.colorScheme.outline,
    },
    icon: feedbackCategoryIcon(category),
  );
}

/// The status as the admins read it: what is to be done next.
String feedbackAdminStatusLabel(FeedbackTicket ticket) =>
    switch (ticket.status) {
      FeedbackStatus.open when ticket.isNew => 'Neu',
      FeedbackStatus.open => 'Wartet auf Antwort',
      FeedbackStatus.answered => 'Wartet auf Rückmeldung',
      FeedbackStatus.closed => 'Geschlossen',
    };

/// The status as the author reads it.
String feedbackMemberStatusLabel(FeedbackTicket ticket) =>
    switch (ticket.status) {
      FeedbackStatus.open => 'Offen',
      FeedbackStatus.answered => 'Beantwortet',
      FeedbackStatus.closed => 'Geschlossen',
    };

Widget feedbackStatusPill(FeedbackTicket ticket, {required bool admin}) {
  final label = admin
      ? feedbackAdminStatusLabel(ticket)
      : feedbackMemberStatusLabel(ticket);
  return StatePill(
    label,
    color: switch (ticket.status) {
      FeedbackStatus.open => StageTheme.orange,
      FeedbackStatus.answered => StageTheme.violet,
      FeedbackStatus.closed => StageTheme.green,
    },
    icon: switch (ticket.status) {
      FeedbackStatus.open when admin && ticket.isNew =>
        Icons.fiber_new_outlined,
      FeedbackStatus.open => Icons.hourglass_empty,
      FeedbackStatus.answered => Icons.mark_chat_read_outlined,
      FeedbackStatus.closed => Icons.check_circle_outline,
    },
  );
}
