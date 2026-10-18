import 'package:flutter/foundation.dart';

import '../../../core/models.dart';

/// Longest feedback text (and reply) the server accepts.
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

/// Where a ticket stands.
///
/// * [open]: waiting for the admins (new, or the member wrote last).
/// * [answered]: an admin wrote last, waiting for the member.
/// * [closed]: done; only possible after at least one admin answer.
enum FeedbackStatus { open, answered, closed }

FeedbackStatus _status(Object? value) => switch (value) {
  'answered' => FeedbackStatus.answered,
  // Older servers mark handled feedback as `done`.
  'closed' || 'done' => FeedbackStatus.closed,
  _ => FeedbackStatus.open,
};

/// One message of a ticket's conversation.
class FeedbackMessage {
  const FeedbackMessage({
    required this.id,
    required this.fromAdmin,
    required this.text,
    this.at,
    this.authorName = '',
  });

  final String id, text, authorName;

  /// Written by an admin (otherwise by the ticket's author).
  final bool fromAdmin;
  final DateTime? at;

  factory FeedbackMessage.fromJson(JsonMap json) => FeedbackMessage(
    id: textValue(json['id']),
    fromAdmin: json['from'] == 'admin',
    text: textValue(json['text']),
    at: dateValue(json['at']),
    authorName: textValue(jsonMap(json['author'])['name']).trim(),
  );
}

/// One piece of member feedback as a support ticket with its conversation.
class FeedbackTicket {
  const FeedbackTicket({
    required this.id,
    required this.message,
    required this.category,
    required this.status,
    required this.version,
    required this.messages,
    this.createdAt,
    this.lastActivityAt,
    this.closedAt,
    this.appVersion = '',
    this.platform = '',
    this.authorName = '',
    this.closedByName = '',
    this.closedByAdmin = false,
    this.unread = 0,
  });

  final String id, message, category, appVersion, platform, authorName;
  final FeedbackStatus status;
  final int version;
  final List<FeedbackMessage> messages;
  final DateTime? createdAt, lastActivityAt, closedAt;
  final String closedByName;
  final bool closedByAdmin;

  /// Admin answers the author has not opened yet (member view only).
  final int unread;

  bool get closed => status == FeedbackStatus.closed;

  /// Whether an admin has answered at least once; only then it can close.
  bool get answered => messages.any((m) => m.fromAdmin);
  bool get canClose => answered && !closed;

  /// Not answered by anyone yet.
  bool get isNew => status == FeedbackStatus.open && !answered;

  FeedbackMessage? get lastAdminMessage =>
      messages.lastWhereOrNull((m) => m.fromAdmin);

  factory FeedbackTicket.fromJson(JsonMap json) {
    final createdAt = dateValue(json['createdAt']);
    final message = textValue(json['message']);
    final authorName = textValue(jsonMap(json['author'])['name']).trim();
    final messages = [
      for (final m in jsonList(json['messages']))
        FeedbackMessage.fromJson(jsonMap(m)),
    ];
    final closedBy = jsonMap(json['closedBy']);
    return FeedbackTicket(
      id: textValue(json['id']),
      message: message,
      category: textValue(json['category'], 'other'),
      status: _status(json['status']),
      version: intValue(json['version']),
      // Servers before the tickets send the text without a conversation.
      messages: messages.isNotEmpty
          ? messages
          : [
              FeedbackMessage(
                id: '${textValue(json['id'])}-0',
                fromAdmin: false,
                text: message,
                at: createdAt,
                authorName: authorName,
              ),
            ],
      createdAt: createdAt,
      lastActivityAt: dateValue(json['lastActivityAt']) ?? createdAt,
      closedAt: dateValue(json['closedAt']),
      appVersion: textValue(json['appVersion']),
      platform: textValue(json['platform']),
      authorName: authorName,
      closedByName: textValue(closedBy['name']).trim(),
      closedByAdmin: closedBy['role'] == 'admin',
      unread: intValue(json['unread']),
    );
  }
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
