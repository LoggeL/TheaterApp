part of '../../../core/app_controller.dart';

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
          'customMinutes': customMinutes,
        },
      });
}
