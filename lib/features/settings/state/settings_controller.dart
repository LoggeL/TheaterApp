part of '../../../core/app_controller.dart';

/// Push kinds everyone can switch off for themselves; stored with the
/// reminder settings and on unless switched off (see server/src/push-kinds.mjs).
const memberPushKeys = [
  'eventAnnouncements',
  'eventRequests',
  'slots',
  'messages',
  'polls',
  'direct',
  'feedbackReplies',
];

/// Push kinds only admins get and can switch off.
const adminPushKeys = ['adminRegistrations', 'adminFeedback'];

/// Reminder settings before the server sent any; push kinds are on.
final Map<String, bool> _defaultReminders = Map.unmodifiable({
  'dayBefore': false,
  'twoHours': true,
  'changes': true,
  'emailEnabled': false,
  'lateDeclines': true,
  for (final key in [...memberPushKeys, ...adminPushKeys]) key: true,
});

/// Local preferences and reminder settings.
extension SettingsController on AppController {
  Future<void> setPreference(String key, Object? value) async {
    if (_account == null) return;
    if (value == null) {
      _preferences.remove(key);
    } else {
      _preferences[key] = value;
    }
    final generation = _generation;
    _notify();
    await _persist(generation, 'preferences', () => _preferences);
  }

  Future<void> saveReminders(Map<String, bool> value) =>
      _saveReminders(value, _customReminderMinutes);
  Future<void> saveCustomReminder(int? minutes) =>
      _saveReminders(_reminders, minutes);
  Future<void> _saveReminders(Map<String, bool> value, int? customMinutes) =>
      _enqueue({
        'action': 'settings.reminders',
        'value': {
          for (final key in [
            'dayBefore',
            'twoHours',
            'changes',
            'emailEnabled',
          ])
            key: value[key] ?? false,
          // Older servers would store the unknown key; newer ones keep it
          // when an older app leaves it out.
          if (supports('lateDeclines'))
            'lateDeclines': value['lateDeclines'] ?? true,
          if (supports('pushSettings'))
            for (final key in [...memberPushKeys, ...adminPushKeys])
              key: value[key] ?? true,
          'customMinutes': customMinutes,
        },
      });
}
