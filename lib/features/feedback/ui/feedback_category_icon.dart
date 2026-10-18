import 'package:flutter/material.dart';

IconData feedbackCategoryIcon(String category) => switch (category) {
  'idea' => Icons.lightbulb_outline,
  'bug' => Icons.bug_report_outlined,
  _ => Icons.chat_bubble_outline,
};
