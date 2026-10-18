import 'package:flutter/foundation.dart';

import '../../../core/models.dart';

/// Longest feedback text the server accepts.
const feedbackMaxLength = 4000;

/// Feedback kinds in the order the form offers them.
const feedbackCategories = ['idea', 'bug', 'other'];

String feedbackCategoryLabel(String category) => switch (category) {
  'idea' => 'Idee',
  'bug' => 'Fehler',
  _ => 'Sonstiges',
};

String feedbackPlatformLabel(String platform) => switch (platform) {
  'android' => 'Android',
  'ios' => 'iOS',
  'web' => 'Web',
  _ => platform,
};

/// The platform sent with feedback, determined like the device registration.
String feedbackPlatform() => kIsWeb
    ? 'web'
    : defaultTargetPlatform == TargetPlatform.iOS
    ? 'ios'
    : 'android';

/// One piece of member feedback as the admin list shows it.
class FeedbackEntry {
  const FeedbackEntry({
    required this.id,
    required this.message,
    required this.category,
    required this.done,
    required this.version,
    this.createdAt,
    this.appVersion = '',
    this.platform = '',
    this.authorName = '',
  });

  final String id, message, category, appVersion, platform, authorName;

  /// Whether an admin has marked it as handled (`status: 'done'`).
  final bool done;
  final int version;
  final DateTime? createdAt;

  factory FeedbackEntry.fromJson(JsonMap json) => FeedbackEntry(
    id: textValue(json['id']),
    message: textValue(json['message']),
    category: textValue(json['category'], 'other'),
    done: json['status'] == 'done',
    version: intValue(json['version']),
    createdAt: dateValue(json['createdAt']),
    appVersion: textValue(json['appVersion']),
    platform: textValue(json['platform']),
    authorName: textValue(jsonMap(json['author'])['name']).trim(),
  );
}
